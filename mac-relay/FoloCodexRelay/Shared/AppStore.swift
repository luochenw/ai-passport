import Foundation
import SwiftUI

// =====================================================================
// Firmware updater: load the one bundled current firmware image and push it to
// the device over the App Store BLE service (main/demo_appstore.c). The device
// writes it into `appslot`, validates it, and reboots into the new image.
// =====================================================================

struct AppCatalogEntry: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let binURL: URL

    var sizeBytes: Int {
        (try? FileManager.default.attributesOfItem(atPath: binURL.path)[.size] as? Int) ?? 0
    }
}

// Not @MainActor -- this codebase uses plain GCD (DispatchQueue) throughout, not Swift
// Concurrency, and handleRequest() is invoked directly from BLERelay's bleQueue (a
// synchronous, non-async closure) exactly like CodexBrowserModel.handleRequest(). All
// @Published mutations are explicitly hopped to the main queue below instead of relying
// on actor isolation, matching that same style.
final class AppStoreModel: ObservableObject {
    @Published var catalog: [AppCatalogEntry] = []
    @Published var statusText: String = "等待设备连接..."

    /// 设备连没连上。由入口接 BLERelay.onLinkChange 填。
    ///
    /// 这一页以前对连接状态**完全无感知**,两个方向都错:
    ///   · 连上了也一直显示初值"等待设备连接..."(statusText 只在下载/校验/
    ///     中止/刷新目录四处被改写),于是「应用」页写"已装 3/8"的同一秒,
    ///     切过来这页还写"等待设备连接";
    ///   · 没连上时「安装」按钮照样能点 —— 会真的下载并校验整个固件,然后用
    ///     无连接时的兜底分片大小(BLERelay.appStoreMaxPayloadSize 在
    ///     peripheral 为 nil 时返回 17)去切片,用户看到进度条卡在 0、分片
    ///     总数荒谬,几十秒后弹出"安装中止:设备长时间无响应" —— 而真实
    ///     原因是压根没连设备。
    @Published var isConnected = false {
        didSet {
            guard isConnected != oldValue, !isInstalling else { return }
            statusText = isConnected ? "设备已连接" : "等待设备连接..."
        }
    }
    @Published var isInstalling = false
    @Published var installTarget: String = ""
    @Published var installProgress: (sent: Int, total: Int) = (0, 0)
    @Published var lastError: String?

    /// (kind, index, total, payload) -- forwarded straight into BLERelay.enqueueAppStore.
    /// Used for catalog items only now; firmware chunks go through sendBatch below.
    private let sender: (UInt8, UInt16, UInt16, Data) -> Void
    private let maxPayloadSize: () -> Int
    /// Forwarded straight into BLERelay.cancelAppStoreTransfer -- called the moment the
    /// device reports APPSTORE_EVT_INSTALL_ABORTED, so this process stops wasting minutes
    /// pushing chunks a device that has already given up on this install attempt.
    private let cancelTransfer: () -> Void
    /// Forwarded straight into BLERelay.sendAppStoreBatch(withoutResponse:completion:).
    private let sendBatch: (_ chunks: [Data], _ completion: @escaping () -> Void) -> Void
    private let workQueue = DispatchQueue(label: "com.folotoy.codexrelay.appstore")

    /// One chunk is ~500 bytes; a batch is sent entirely as write-without-response (no
    /// per-chunk round trip), then this process waits for one APPSTORE_EVT_PROGRESS
    /// confirming the whole batch before sending the next one. 64 chunks (~32KB) keeps
    /// each round trip's "how much do we lose if this batch needs a retry" small while
    /// still amortizing the wait-for-ack overhead over a meaningful amount of data.
    private static let batchSize = 64
    /// How long to wait for a batch's progress ack before assuming it (or the ack itself)
    /// got lost and resending. Generous on purpose -- resending is idempotent (the device
    /// skips chunks it already wrote) but not free, so this shouldn't be trigger-happy on
    /// a link that's just being a little slow.
    private static let batchTimeout: TimeInterval = 5.0

    /// State for the one install that can be in flight at a time (the device's own UI
    /// only ever has one REQ_INSTALL_APP outstanding). `wireChunks` are fully framed
    /// (buildAppStoreChunks already applied) so a retry just resends a slice of this
    /// array -- no re-framing, no re-reading the file.
    private struct InstallSession {
        let entry: AppCatalogEntry
        let wireChunks: [Data]
        var confirmedCount: Int
        /// Bumped every time a new batch is sent OR a fresh ack arrives, so a timeout
        /// scheduled for an older attempt can recognize it's stale and no-op instead of
        /// firing a redundant retry on top of one already in flight.
        var generation: Int
        /// Consecutive batch timeouts with zero progress acked in between. Reset to 0 by
        /// ANY progress ack (even a duplicate re-ack of an already-confirmed count -- that
        /// still proves the device is alive and reachable on this GATT service). Exists
        /// because a real disconnect (device navigated away from the App Store page, which
        /// tears down and restarts its whole BLE service -- main.c's view state machine
        /// guarantees VIEW_CODEX/VIEW_APPSTORE never run at the same time) leaves
        /// appStoreDataChar permanently nil on the Mac side with no signal that the
        /// characteristic is never coming back. Without a cap, sendNextBatch/
        /// scheduleBatchTimeout retried forever, once every batchTimeout, spamming "没有可用的
        ///连接" into the log indefinitely even after the device moved on to something
        /// unrelated (observed directly: retries for an app-store batch kept firing while
        /// the device was already several minutes into browsing Codex sessions).
        var consecutiveTimeouts: Int = 0
        /// End index (exclusive) of the batch currently in flight. The window only advances
        /// when an ack reaches THIS -- not on every ack that happens to arrive.
        ///
        /// The device emits a progress report from two places: once per
        /// APPSTORE_PROGRESS_BATCH chunks actually written, AND immediately on every
        /// duplicate chunk it skips. Treating each one as "batch done, send the next batch"
        /// made the window restart from a count that was already stale by the time it
        /// arrived, so each new batch re-sent a mostly-overlapping range, whose leading
        /// chunks were duplicates, which triggered more instant re-acks, which restarted
        /// the window again -- a thrash loop where acks crawled forward 3 chunks at a time
        /// and nearly all bandwidth went to re-sending already-written data.
        var inflightEnd: Int
    }
    private var session: InstallSession?
    /// Give up and surface a clear error after this many consecutive timeouts with no
    /// progress at all -- 6 * batchTimeout(5s) = 30s of total silence from the device.
    private static let maxConsecutiveTimeouts = 6

    init(sender: @escaping (UInt8, UInt16, UInt16, Data) -> Void,
         maxPayloadSize: @escaping () -> Int,
         cancelTransfer: @escaping () -> Void,
         sendBatch: @escaping (_ chunks: [Data], _ completion: @escaping () -> Void) -> Void) {
        self.sender = sender
        self.maxPayloadSize = maxPayloadSize
        self.cancelTransfer = cancelTransfer
        self.sendBatch = sendBatch
        loadCatalog()
        pollDebugTrigger()
    }

    /// Debug-only: lets a human (or Claude, driving this Mac's shell) kick off an install
    /// without touching the physical device -- `touch /tmp/appstore_debug_install` (or
    /// `echo 0 > ...` to pick a catalog index) triggers exactly the same installApp() path
    /// REQ_INSTALL_APP would. Polling a plain file instead of a socket/port because it
    /// needs zero client-side tooling to drive from a shell. Purely a local dev convenience
    /// -- nothing device-side depends on this file existing, and it does nothing when it's
    /// absent (the normal case).
    private static let debugInstallTriggerPath = "/tmp/appstore_debug_install"

    private func pollDebugTrigger() {
        // ⚠ 只在 macOS 上跑。这是个开发期调试钩子:在终端里往 /tmp 写个文件
        // 来驱动它。iOS 沙盒里既写不进那个路径、也没有终端能写,轮询永远
        // 命中不了,只剩每秒一次的空唤醒 —— 手机上那是白耗电。
        #if os(macOS)
        if FileManager.default.fileExists(atPath: Self.debugInstallTriggerPath) {
            let raw = (try? String(contentsOfFile: Self.debugInstallTriggerPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let index = Int(raw ?? "") ?? 0
            try? FileManager.default.removeItem(atPath: Self.debugInstallTriggerPath)
            log("[appstore] 调试触发文件命中,直接发起安装 index=\(index)(跳过设备端按键)")
            workQueue.async { [weak self] in self?.installApp(at: index) }
        }
        workQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pollDebugTrigger()
        }
        #endif
    }

    /// Reads the first valid entry from the bundled AppCatalog/catalog.json. The
    /// firmware panel deliberately exposes one current image only; extra catalog
    /// entries are ignored so stale development variants cannot leak into the UI.
    private func loadCatalog() {
        guard let catalogDir = Self.resolveCatalogDir() else {
            log("[appstore] 找不到 AppCatalog 目录,最新固件不可用")
            return
        }
        let catalogFile = catalogDir.appendingPathComponent("catalog.json")
        guard let data = try? Data(contentsOf: catalogFile) else {
            log("[appstore] 读不到 \(catalogFile.path),最新固件不可用")
            return
        }
        struct Entry: Decodable { let name: String; let description: String; let bin: String }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            log("[appstore] catalog.json 解析失败,最新固件不可用")
            return
        }
        let latest = entries.lazy.compactMap { e -> AppCatalogEntry? in
            let binURL = catalogDir.appendingPathComponent(e.bin)
            guard FileManager.default.fileExists(atPath: binURL.path) else {
                log("[appstore] 目录条目 \"\(e.name)\" 指向的文件不存在: \(binURL.path),跳过")
                return nil
            }
            return AppCatalogEntry(name: e.name, description: e.description, binURL: binURL)
        }.first
        catalog = latest.map { [$0] } ?? []
        log("[appstore] 最新固件\(latest == nil ? "不可用" : "已加载")")
    }

    /// 目录一律从 app bundle 的资源目录里读。
    ///
    /// 之前这里有两条路,两条现在都是错的:
    ///  1. `#filePath` 上溯两级 —— 这个文件搬进 Shared/ 之后就多了一层,
    ///     现在指向 FoloCodexRelay/AppCatalog(不存在)。而且 `#filePath`
    ///     会把**构建机的绝对路径**(/Users/<用户名>/...)编进发布产物里,
    ///     本来就不该出现在要分发的二进制中。
    ///  2. `CommandLine.arguments[0]` 上溯两级 + Contents/Resources ——
    ///     那是 macOS 的 .app 布局,iOS 的 bundle 是扁的,没有 Contents/。
    ///
    /// `Bundle.main.resourceURL` 两端都对:macOS 上是 Contents/Resources,
    /// iOS 上就是 .app 根目录 —— 正好分别对应 build.sh 和 build-ios.sh
    /// 拷贝 AppCatalog 的位置。
    private static func resolveCatalogDir() -> URL? {
        guard let dir = Bundle.main.resourceURL?
            .appendingPathComponent("AppCatalog", isDirectory: true) else { return nil }
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// Entry point for BLERelay.onAppStoreCmdRequest.
    func handleRequest(req: UInt8, a: UInt8, b: UInt8) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            switch req {
            case AppStoreCmdReq.listApps:
                self.sendCatalog()
            case AppStoreCmdReq.installApp:
                self.installApp(at: Int(a))
            case AppStoreCmdReq.installAborted:
                log("[appstore] 设备报告安装已中止,清空还没发出去的分片队列")
                self.cancelTransfer()
                self.session = nil
                DispatchQueue.main.async {
                    self.isInstalling = false
                    self.lastError = "设备已中止安装(详情见设备屏幕)"
                }
            case AppStoreCmdReq.progress:
                let count = Int(a) | (Int(b) << 8)
                self.handleProgressAck(confirmedCount: count)
            default:
                log("[appstore] 收到未知 CMD 请求 req=\(req),忽略")
            }
        }
    }

    private func sendCatalog() {
        log("[appstore] 收到请求: REQ_LIST_APPS,共 \(catalog.count) 个应用")
        let total = UInt16(min(catalog.count, 65535))
        for (i, entry) in catalog.enumerated() {
            let line = "\(entry.name) - \(entry.description)"
            let payload = Data(line.utf8)
            sender(AppStoreKind.item, UInt16(i), total, payload)
        }
    }

    /// 设备端按下"确定更新"(REQ_INSTALL_APP)和伴侣端点"更新固件"最终都走到这里。
    private func installApp(at index: Int) {
        guard index >= 0 && index < catalog.count else {
            log("[appstore] 安装下标越界,忽略: \(index)")
            return
        }
        let entry = catalog[index]
        log("[appstore] 请求安装 index=\(index) (\(entry.name))")
        beginInstall(entry: entry, binURL: entry.binURL)
    }

    /// 真正开始把一个已经在本地、已经验证过的 .bin 推给设备。
    private func beginInstall(entry: AppCatalogEntry, binURL: URL) {
        guard let fileData = try? Data(contentsOf: binURL) else {
            log("[appstore] 读取固件文件失败: \(binURL.path)")
            DispatchQueue.main.async {
                self.isInstalling = false
                self.lastError = "读取固件文件失败"
            }
            return
        }

        let chunkSize = maxPayloadSize()
        let rawSlices = stride(from: 0, to: fileData.count, by: chunkSize).map { off -> Data in
            let end = min(off + chunkSize, fileData.count)
            return fileData.subdata(in: off..<end)
        }
        let total = UInt16(min(rawSlices.count, 65535))
        // 每一片只成帧一次:重发时直接重用这个数组的切片,不用重新成帧,也
        // 不用再碰文件。
        let wireChunks = rawSlices.enumerated().map { i, slice in
            BLERelay.buildAppStoreChunks(kind: AppStoreKind.firmware, index: UInt16(i), total: total,
                                         payload: slice, payloadSize: chunkSize)[0]
        }
        log("[appstore] 开始发送固件 \(entry.name),共 \(fileData.count) 字节,\(wireChunks.count) 个分片,批量大小 \(Self.batchSize)")

        session = InstallSession(entry: entry, wireChunks: wireChunks, confirmedCount: 0,
                                 generation: 0, inflightEnd: 0)
        DispatchQueue.main.async {
            self.isInstalling = true
            self.installTarget = entry.name
            self.installProgress = (0, wireChunks.count)
            self.lastError = nil
        }
        sendNextBatch()
    }

    var latestFirmware: AppCatalogEntry? { catalog.first }

    /// 伴侣端唯一的更新入口。设备端请求仍使用索引 0，与同一份固件对应。
    func updateLatestFirmware() {
        workQueue.async { [weak self] in self?.installApp(at: 0) }
    }

    /// Sends the next unconfirmed batch (or the tail end of the current one after a
    /// timeout) via write-without-response, then arms a timeout that retries if no
    /// progress ack arrives. Safe to call repeatedly for the same range -- the device
    /// skips chunks it has already written (see demo_appstore.c's duplicate check), so a
    /// resend of an already-confirmed prefix is a no-op there, not data corruption.
    private func sendNextBatch() {
        guard var s = session else { return }
        guard s.confirmedCount < s.wireChunks.count else { return }   // 全部确认完了,等设备重启
        let end = min(s.confirmedCount + Self.batchSize, s.wireChunks.count)
        var batch = Array(s.wireChunks[s.confirmedCount..<end])
        // 在这一批的最后一片上打 BATCH_END 标志:设备只在写完带这个标志的分片
        // 时上报一次进度,所以每批恰好一次确认,且确认号必然正好等于 `end`,跟
        // 窗口边界严格对齐。批次边界是发送时才确定的(取决于当时确认到哪),所以
        // 只能在这里打,不能在预先成帧的 wireChunks 里打;wireChunks 本身保持
        // 干净不被改写,重发时重新打一次即可。
        if !batch.isEmpty {
            batch[batch.count - 1][batch[batch.count - 1].startIndex] |= AppStoreFlag.batchEnd
        }
        s.generation += 1
        s.inflightEnd = end
        let myGeneration = s.generation
        session = s
        log("[appstore] 发送批次 \(s.confirmedCount)..<\(end) / \(s.wireChunks.count)(第 \(myGeneration) 次尝试)")
        // 超时保护必须在发送**之前**挂上,不能挂在 sendBatch 的 completion 里:
        // completion 依赖发送路径正常走完(BLE 流控放行、连接还在、回调真的
        // 触发……),而那正是最容易出问题的一环。挂在 completion 里等于"只有
        // 发送成功了才有失败保护",发送本身卡住时整条链路会静默死掉、连一条
        // 超时日志都没有——前面已经踩过两次(流控回调不触发、分片超长被
        // CoreBluetooth 静默丢弃),两次都是这个结构放大成了完全无从诊断的
        // 假死。现在无论发送路径发生什么,超时一定会到。
        scheduleBatchTimeout(generation: myGeneration, expectedCount: end)
        sendBatch(batch) { }
    }

    /// If `generation` is still current when this fires, no ack arrived in time for the
    /// batch that ended at `expectedCount` -- resend starting from whatever's actually
    /// still unconfirmed (sendNextBatch() always reads confirmedCount fresh, so if a late
    /// ack advanced it in the meantime, the resend is smaller or a no-op).
    private func scheduleBatchTimeout(generation: Int, expectedCount: Int) {
        workQueue.asyncAfter(deadline: .now() + Self.batchTimeout) { [weak self] in
            guard let self = self, var s = self.session, s.generation == generation else { return }
            s.consecutiveTimeouts += 1
            if s.consecutiveTimeouts >= Self.maxConsecutiveTimeouts {
                log("[appstore] 连续 \(s.consecutiveTimeouts) 次批次确认超时(约 \(Int(Double(s.consecutiveTimeouts) * Self.batchTimeout)) 秒无响应),放弃这次安装 -- 设备可能已经离开应用商店页面或断开连接")
                self.session = nil
                DispatchQueue.main.async {
                    self.isInstalling = false
                    self.lastError = "安装中止:设备长时间无响应(已离开应用商店页面或断开连接?)"
                }
                return
            }
            self.session = s
            log("[appstore] 批次确认超时(期望到 \(expectedCount),目前确认到 \(s.confirmedCount),连续超时 \(s.consecutiveTimeouts) 次),重发")
            self.sendNextBatch()
        }
    }

    /// Entry point for handleRequest's AppStoreCmdReq.progress case -- the device's
    /// authoritative "I've actually written N chunks" count. Only ever moves forward
    /// (max()), so it's safe regardless of whether this arrives before or after a
    /// timeout-triggered retry for the same range fires.
    private func handleProgressAck(confirmedCount: Int) {
        guard var s = session else {
            // 收到进度但本进程没有对应的会话——大概率是这个 relay app 在安装
            // 中途重启过(不是同一次 BLE 连接的重连,是整个进程重启,session
            // 状态没了)。设备那边还在等,但这里已经没有文件数据/分片数组可以
            // 继续发了,只能先记录下来,等用户在设备上重新发起一次安装。
            log("[appstore] 收到进度上报(已确认 \(confirmedCount) 片),但当前没有进行中的安装会话,忽略")
            return
        }
        s.confirmedCount = max(s.confirmedCount, confirmedCount)
        s.consecutiveTimeouts = 0   // 收到任何进度上报都证明设备还活着、还在这个 service 上
        session = s
        DispatchQueue.main.async { self.installProgress = (s.confirmedCount, s.wireChunks.count) }

        if s.confirmedCount >= s.wireChunks.count {
            log("[appstore] 设备确认已全部写完,等待它自行重启切换")
            session = nil
            DispatchQueue.main.async { self.isInstalling = false }
            return
        }
        // 只有确认号真的追上当前在途批次的末尾,才推进窗口发下一批。中途到达的
        // 部分进度(设备每写满一个批量周期就报一次,以及每跳过一个重复分片就
        // 立刻补报一次)只更新进度显示,不重启窗口——否则会拿一个到达时就已经
        // 过期的确认号去重发一个大幅重叠的区间,其开头那些分片又是重复的、又
        // 触发即时补报,如此循环,带宽几乎全耗在重发上(实测确认号每次只前进
        // 3 片)。这里不推进时也不动 generation,让已经挂上的那个超时继续有效,
        // 保证真丢包时仍然会重发。
        guard s.confirmedCount >= s.inflightEnd else { return }
        log("[appstore] 收到进度确认: \(s.confirmedCount)/\(s.wireChunks.count)")
        sendNextBatch()
    }
}

// MARK: - UI

struct AppStoreView: View {
    @ObservedObject var model: AppStoreModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("固件").font(.title2).bold()
                Spacer()
                Label(model.statusText,
                      systemImage: model.isConnected ? "checkmark.circle" : "bolt.horizontal.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if let firmware = model.latestFirmware {
                HStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(firmware.name).font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(firmware.sizeBytes),
                                                       countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.updateLatestFirmware()
                    } label: {
                        Label("更新固件", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.isInstalling || !model.isConnected)
                }
            } else {
                Text("最新固件不可用")
                    .foregroundStyle(.secondary)
            }

            if model.isInstalling {
                VStack(alignment: .leading, spacing: 8) {
                    Text("正在更新")
                    ProgressView(value: Double(model.installProgress.sent),
                                 total: Double(max(model.installProgress.total, 1)))
                    Text("\(model.installProgress.sent)/\(model.installProgress.total) 分片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer()
        }
        .padding(20)
        // 只有 macOS 需要:窗口是用户可拉的,给个不至于挤成一团的下限。
        // iPhone 上窗口就是屏幕,写死 460 会让内容横向溢出(iPhone
        // 竖屏逻辑宽度只有 390pt)。
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }
}
