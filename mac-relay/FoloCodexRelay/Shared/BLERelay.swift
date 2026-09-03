import Foundation
import CoreBluetooth
#if os(iOS)
import UIKit
#endif

// 从 main.swift 拆出来。原来 2000 多行混在一个文件里,通用层和 macOS 专有层
// 分不开,没法谈三端复用。

// MARK: - BLE Relay

/// Scans for "FoloPassport", connects, discovers the Codex Relay service's two
/// characteristics (DATA for Mac->device pushes, CMD for device->Mac requests),
/// subscribes to CMD, and relays queued (kind, index, total, text) messages using
/// the chunked write protocol described in the task spec. Reconnects indefinitely;
/// never gives up.
final class BLERelay: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    /// 设备广播名的固定前缀。真实名字后面还带 MAC 后两字节
    /// (`FoloPassport-A3F1`),让多台设备可区分 —— 见固件 ble_hub.c 的
    /// device_name()。**匹配必须用前缀,不能用相等**,否则带后缀的设备
    /// 一台都发现不了。
    static let namePrefix = "FoloPassport"
    /// 老固件(没有后缀)也要能连上,所以前缀本身就是合法名字。
    static let targetName = namePrefix
    // NOTE: on the Swift/CoreBluetooth side we use the UUID strings exactly as given in
    // the spec (standard order) -- the firmware-side BLE_UUID128_INIT byte reversal is a
    // firmware-only concern and does not apply here.
    // Codex service。**只剩 AUDIO 一条还在用**。
    //
    // 这个 service 原本有三个特征值:DATA(电脑 -> 设备,推会话内容)、
    // CMD(设备 -> 电脑,发浏览请求)、AUDIO(设备 -> 电脑,语音流)。
    // 前两条对应的是设备上那套自己浏览会话的界面 —— 架构转向之后,浏览逻辑
    // 整个搬到了 CodexApp,走通用的远程界面通道,那两条就再没有调用方了。
    // 留着一条谁也不写的特征值,只会让下一个读代码的人以为它还在用。
    //
    // AUDIO 不一样:麦克风长在设备上,采样和编码的起点在硬件那一侧,这个
    // 方向没法被远程界面取代。
    static let serviceUUID = CBUUID(string: "7D860E11-CECE-4DC5-85BF-088EBDADC109")
    // Voice-input streaming characteristic (device -> Mac, NOTIFY). String form matches
    // the firmware's BLE_UUID128_INIT byte array (that array is byte-reversed on the
    // NimBLE/firmware side only, per the same convention as the two UUIDs above).
    static let audioCharUUID = CBUUID(string: "0596975F-B995-439C-A41B-3DFA7AA8A81F")

    // App Store service (main/demo_appstore.c) -- a second, fully independent GATT
    // service on the same peripheral. Never advertised at the same time as the Codex
    // service above (the device's VIEW_CODEX/VIEW_APPSTORE state machine guarantees only
    // one of the two BLE stacks runs at once), but discovery is unfiltered (discoverServices(nil)
    // below) so whichever one is actually present just shows up here.
    static let appStoreDataCharUUID = CBUUID(string: "8C2E5A11-6B3D-4F8E-9A1C-2D7E6F4B3A90")
    static let appStoreCmdCharUUID = CBUUID(string: "8C2E5A12-6B3D-4F8E-9A1C-2D7E6F4B3A90")
    /// 设备配置下发(见 main/device_config.c)。收的是 "<key>=<value>\n" 文本行。
    static let deviceConfigCharUUID = CBUUID(string: "9A4C1E21-7F5B-4A3D-8C61-1E9D4B7A2F30")
    /// 设备 -> 这边的状态上报(NOTIFY)。格式跟下发方向一样是 "<key>=<value>\n"。
    /// 配置页上"现在连着哪个 Wi-Fi""扫到了哪些网络"这些事实只有设备知道,
    /// 全靠这条通道。
    static let deviceStatusCharUUID = CBUUID(string: "9A4C1E22-7F5B-4A3D-8C61-1E9D4B7A2F30")
    /// 远程界面(见 main/remote_ui.h)。SCREEN 写屏幕描述,EVENT 收按键。
    static let remoteScreenCharUUID = CBUUID(string: "5D8E3C41-9A72-4B15-8E63-7C4F1A2D9B80")
    static let remoteEventCharUUID  = CBUUID(string: "5D8E3C42-9A72-4B15-8E63-7C4F1A2D9B80")
    /// MANIFEST 写已安装应用清单,设备缓存进 NVS 用来画首屏。
    static let remoteManifestCharUUID = CBUUID(string: "5D8E3C43-9A72-4B15-8E63-7C4F1A2D9B80")
    static let walkieServiceUUID = CBUUID(string: WalkieWire.serviceUUID)
    static let walkieControlCharUUID = CBUUID(string: WalkieWire.controlUUID)
    static let walkieUplinkCharUUID = CBUUID(string: WalkieWire.uplinkUUID)
    static let walkieDownlinkCharUUID = CBUUID(string: WalkieWire.downlinkUUID)
    static let walkieStatusCharUUID = CBUUID(string: WalkieWire.statusUUID)

    // All CoreBluetooth delegate callbacks AND all of this class's mutable state are
    // confined to this single serial queue, so no separate locking is needed.
    private let bleQueue = DispatchQueue(label: "com.folotoy.codexrelay.ble")

    private var central: CBCentralManager!
    /// 扫到过的一台设备。
    ///
    /// id 用 CBPeripheral.identifier,**不用广播名**:名字在 iOS 后台广播里
    /// 可能整个缺失(见 didDiscover 的三级 fallback),拿它当主键会在发现的
    /// 那一刻就崩。名字只负责"让人看出这是哪一台"。
    struct DiscoveredDevice: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
        var lastSeen: Date
        var connected: Bool
        /// 界面此刻**正在看**哪一台。跟 connected 是两回事,也跟"能不能用"
        /// 无关 —— 每台都有自己独立的会话,都在跑;这个标志只说明屏幕上
        /// 显示的是谁的那一份。
        var displayed: Bool
    }

    /// 设备列表变了。界面据此画设备选择器。
    var onDevicesChanged: (([DiscoveredDevice]) -> Void)?

    /// 扫到过的全部设备,按 identifier 索引。
    private var discovered: [UUID: DiscoveredDevice] = [:]
    /// 还没被释放的 CBPeripheral 引用 —— CoreBluetooth 要求调用方自己持有,
    /// 不持有的话对象会被回收,之后 connect(_:) 直接失败。
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    /// 用户选定要连的那一台。nil = 没选过,连扫到的第一台。
    ///
    /// 落 UserDefaults:不存的话每次重启都连"扫到的第一台",而扫描顺序取决于
    /// 谁先广播 —— 用户明明选过设备 B,下次开机可能又跑回 A,而且没有任何
    /// 提示。这是设备标识,不是凭据,可以进 UserDefaults。
    /// 上次界面看的是哪一台。**只用来恢复界面**,不参与连接或路由决策 ——
    /// 每台扫到就连、每台都有自己的会话,"用户选定要连的那一台"这个概念
    /// 已经不存在了。
    ///
    /// 键名沿用旧的 `ble.preferredDevice`:改键名只会让用户升级后丢掉
    /// "上次看的是哪台",换不来任何东西。
    static let lastDisplayedKey = "ble.preferredDevice"
    /// 上次把列表发给界面的时间,用来限流(开了 allowDuplicates 之后回调很密)。
    private var lastDevicesPublish = Date.distantPast

    /// 一条设备连接的全部状态。
    ///
    /// 为什么必须按设备分身:同时连两台时,如果特征值只有一套,后连上的会把
    /// 先连上的整个覆盖 —— `peripheral` 指向一台、`remoteScreenChar` 指向
    /// 另一台,推屏写到错误的目标,**两台都收不到**,而且编译通过、无报错,
    /// 唯一线索是设备屏幕上那句"等待电脑推送内容"。这个 bug 真实发生过。
    ///
    /// 不加锁:CoreBluetooth 把所有外设的回调都投递到同一条 bleQueue
    /// (见下面 bleQueue 的说明),link 的字段只在那条队列上读写。
    final class DeviceLink {
        let id: UUID
        let peripheral: CBPeripheral

        var audioChar: CBCharacteristic?
        var appStoreDataChar: CBCharacteristic?
        var appStoreCmdChar: CBCharacteristic?
        var deviceConfigChar: CBCharacteristic?
        var remoteScreenChar: CBCharacteristic?
        var remoteManifestChar: CBCharacteristic?
        var walkieControlChar: CBCharacteristic?
        var walkieUplinkChar: CBCharacteristic?
        var walkieDownlinkChar: CBCharacteristic?
        var walkieStatusChar: CBCharacteristic?

        var walkieAudioQueue = WalkieRealtimeQueue(limit: 12)
        var walkieUplinkSubscribed = false
        var walkieStatusSubscribed = false

        /// STATUS 通知的拼装缓冲。设备侧尽量在换行处切片,但缓冲装不下一整行
        /// 时会硬切 —— 不能假设"一个通知就是若干条完整的行",必须自己攒到看见
        /// 换行为止,否则 SSID 长一点的那条状态会被拆成两半各自解析失败。
        var statusRxBuffer = ""

        /// 这台此刻是不是停在某个远程应用里(而不是自己的本地菜单)。
        /// 推屏按它分发:在同一个应用里的设备都该看到同一屏 —— 上层
        /// (RemoteAppHost)只有一个前台会话,几台设备是它的几个镜子。
        var inRemoteApp = false

        /// 链路就绪程度。上层要等它"真的能用"了才建会话:配置特征值就绪
        /// 说明这条 GATT 通得了,应用商店 DATA 就绪说明能发内容。少等一个,
        /// 会话建起来之后头几次发送会静默落空。
        var configReady = false
        var appStoreReady = false
        var walkieReady = false
        /// 已经通知过上层"这台可以开会话了"。特征值发现回调按 service 分批
        /// 到达,不去重的话会建好几次。
        var attachAnnounced = false

        /// 最后发给**这一台**的清单。发出去之后不清空 —— 设备重连时要靠它
        /// 补一份首屏,而上层只在清单**变化**时才推,不会为一台重连的设备
        /// 重推一次。
        var lastManifest: String?

        /// 目录条目的发送队列。⚠ 必须按设备各一条:目录是广播给所有设备的
        /// (见 enqueueAppStore),共用一条队列的话先回写回调的那台会吃掉
        /// 别人的分片,另一台的商店页就永远差几行。
        var appStoreMessageQueue: [(kind: UInt8, index: UInt16, total: UInt16, payload: Data)] = []
        var appStoreChunkQueue: [Data] = []
        var appStoreWaitingForWriteCallback = false

        /// 固件批传(write-without-response)被本机发送缓冲挡住时,续传的闭包。
        /// ⚠ 必须每设备一份。共享一份的时候不是"串行",是**互相破坏**:
        /// 后一台把前一台的续传闭包覆盖掉,被覆盖那批只能靠 5 秒超时爬行。
        var pendingBatchResume: (() -> Void)?
        /// 标识 `pendingBatchResume` 当前挂的是**哪一次**等待。每次填入/取出都自增,
        /// 迟到的兜底定时器靠它分辨"我武装的那次"和"现在挂着的新一次"。
        var pendingBatchResumeToken: UInt64 = 0

        init(peripheral: CBPeripheral) {
            self.id = peripheral.identifier
            self.peripheral = peripheral
        }
    }

    /// 当前连着的全部设备,按 identifier 索引。
    private var links: [UUID: DeviceLink] = [:]
    /// 正在被"驱动"的那一台 —— 屏幕、对讲、固件安装都只发给它。
    ///
    /// 同时**连**多台,同一时刻只**驱动**一台:RemoteAppHost 的
    /// `guard self.current === app` 是按单一前台会话写的,让多台同时驱动
    /// 需要把整个应用框架多实例化。连接是链路层的事,驱动是应用层的事,
    /// 这里只解决前者。
    /// 界面此刻正在看哪一台。**只用来画界面**,不参与任何路由决策 ——
    /// 每台设备都有自己独立的会话,发给谁由调用方显式指定。
    ///
    /// 这里曾经有一个 `activeID`(被驱动的那一台)和一整组
    /// `active?.xxx` 兼容代理。那是"一个会话、几面镜子"时代的产物,已经
    /// **全部删除**:留任何一个下来,下一个人顺手用上就又回到单设备,而
    /// 编译器不会提示。现在写入一律走 `links[deviceID]`,由调用方或收到
    /// 回调的那一台自己负责。
    var displayedID: UUID? {
        didSet {
            guard displayedID != oldValue else { return }
            bleQueue.async { [weak self] in self?.publishDevices(force: true) }
        }
    }

    /// 用户在界面上主动点过"断开"的那几台。放在 relay 这一层而不是 link 里:
    /// 断开之后 link 就被删了,标志跟着一起消失,scheduleReconnect 两秒后照样
    /// 把它拉回来 —— 表现为"断开"按钮点了没反应。
    private var userDisconnectedIDs: Set<UUID> = []

    /// Invoked (on bleQueue) whenever the device sends a CMD request. The handler is
    /// expected to hand off any real work to its own queue immediately so it never
    /// blocks bleQueue / CoreBluetooth callback delivery.

    /// Invoked (on bleQueue) for every AUDIO-characteristic notify packet: (flags,
    /// payload) where payload is everything after the flags byte (may be empty on an
    /// END-only packet). Same contract as onCmdRequest -- the handler must hand off to
    /// its own queue immediately.
    var onAudioChunk: ((UUID, UInt8, Data) -> Void)?

    /// Same contract as onCmdRequest, but for the App Store service's CMD characteristic.
    /// Firmware install progress arrives here too (APPSTORE_EVT_PROGRESS, a device-
    /// initiated notification riding the same 3-byte CMD frame, not a real "request") --
    /// see AppStoreModel.handleRequest for why that's the actually-meaningful progress
    /// signal, not anything derived from how fast this process hands writes to
    /// CoreBluetooth.
    var onAppStoreCmdRequest: ((UUID, UInt8, UInt8, UInt8) -> Void)?
    /// 远程界面事件(在 bleQueue 上):(设备, evt, a, b)。
    /// evt 0=按键 1=进出远程页 2=设备就绪。见 main/remote_ui.c。
    var onRemoteEvent: ((UUID, UInt8, UInt8, UInt8) -> Void)?

    /// 设备上报的状态,已经拆成键值对。
    var onDeviceStatus: ((UUID, [(String, String)]) -> Void)?
    /// 连接状态变化。第二个参数是设备名(断开时为 nil)。
    ///
    /// ⚠ 这条只表达**链路**通没通,不再兼职表达"界面焦点变了"。以前
    /// makeActive / selectDevice 也发它,于是每按一次键三个页签的
    /// isConnected 都会全刷一遍。
    var onLinkChange: ((UUID, Bool, String?) -> Void)?
    var onWalkieLinkChange: ((UUID, Bool) -> Void)?
    var onWalkieAudioFrame: ((UUID, Data) -> Void)?
    var onWalkieStatus: ((UUID, _ event: UInt8, _ code: UInt8) -> Void)?

    /// 一台设备的链路真正可用了(特征值齐、可以开始跑它的会话)。
    /// 上层据此为它建一个独立会话。
    var onDeviceAttached: ((UUID) -> Void)?
    /// 一台设备的链路没了。**不要**用 onDevicesChanged 的列表去 diff 出这个
    /// 事件 —— 那个发布是限流的(见 publishDevices),diff 会漏。
    var onDeviceDetached: ((UUID) -> Void)?

    // Outbound message queue waiting to be sent.

    // Chunks (already split, with header bytes) of the message currently in flight.

    // Separate send pipeline for the App Store service -- kept fully independent of the
    // Codex one above (own queue, own in-flight chunk list, own in-flight flag) rather than
    // generalizing the existing pipeline to take a target characteristic, specifically so
    // this addition can't regress the already-verified Codex send path. The one real
    // difference from Codex's pipeline: payload here is raw `Data` (firmware bytes can
    // contain any byte value, including embedded NULs and invalid UTF-8), never a `String`.

    func start() {
        // 恢复上次选的设备,在开扫之前 —— 否则第一轮 didDiscover 会按"没选过"
        // 处理,连上扫到的第一台,然后用户看着它自己跳回去。
        if let saved = UserDefaults.standard.string(forKey: Self.lastDisplayedKey),
           let id = UUID(uuidString: saved) {
            displayedID = id
            log("上次界面看的设备: \(id)")
        }
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.central = CBCentralManager(
                delegate: self,
                queue: self.bleQueue,
                options: [CBCentralManagerOptionRestoreIdentifierKey:
                          "com.folotoy.codexrelay.central"]
            )
            #if os(iOS)
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                self?.bleQueue.async { self?.restartScanForCurrentState() }
            }
            NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                self?.bleQueue.async { self?.restartScanForCurrentState() }
            }
            #endif
            self.scheduleWatchdog()
        }
    }

    /// Thread-safe entry point for the App Store model to hand off a message (catalog
    /// item or a firmware chunk) -- same contract as enqueue() above, separate queue.
    ///
    /// ⚠ 目录条目**广播**给每一台连着的设备。REQ_LIST_APPS 是设备订阅完 CMD
    /// 之后自动发的(main/appstore_transfer.c:571),不是用户点出来的 —— 两台
    /// 同时上线就会同时来要。只发给"当前活跃"那台的话,另一台的商店页会一直
    /// 空着;而目录对每台设备都一样,广播既简单又正确。
    /// 固件字节不走这里(走 sendAppStoreBatch),那条是一对一的。
    func enqueueAppStore(kind: UInt8, index: UInt16, total: UInt16, payload: Data, to device: UUID) {
        bleQueue.async { [weak self] in
            guard let self = self, let link = self.links[device] else { return }
            link.appStoreMessageQueue.append((kind, index, total, payload))
            self.pumpAppStore(link)
        }
    }

    /// Entry point for AppStoreModel to abandon a firmware transfer immediately (device
    /// reported APPSTORE_EVT_INSTALL_ABORTED) instead of grinding through however many
    /// thousands of already-enqueued chunks remain -- the device has already stopped
    /// listening to them.
    func cancelAppStoreTransfer(for device: UUID) {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            guard let link = self.links[device] else { return }
            let dropped = link.appStoreMessageQueue.count + (link.appStoreChunkQueue.isEmpty ? 0 : 1)
            link.appStoreMessageQueue.removeAll()
            link.appStoreChunkQueue.removeAll()
            link.appStoreWaitingForWriteCallback = false
            link.pendingBatchResume = nil
            link.pendingBatchResumeToken &+= 1
            log("应用商店:\(link.peripheral.name ?? "设备")中止安装,丢弃 \(dropped) 条待发消息")
        }
    }

    /// Lets AppStoreModel pre-slice a firmware file into pieces that are each guaranteed
    /// to become exactly one on-wire chunk (never further split by buildAppStoreChunks),
    /// so the index/total it sends is real per-packet progress, not just a logical count
    /// that could silently diverge from actual wire chunks if the negotiated MTU were
    /// smaller than assumed. Synchronous and safe to call from any queue (peripheral's
    /// maximumWriteValueLength is just a stored property read, not a round-trip).
    /// ⚠ Must be the MINIMUM of both write types, not just .withResponse. Catalog items go
    /// out via pumpAppStore() as .withResponse (limit 512, the ATT long-write ceiling)
    /// while firmware chunks go out via drainAppStoreBatch() as .withoutResponse (limit is
    /// the negotiated MTU minus 3 -- typically ~250, i.e. HALF). CoreBluetooth SILENTLY
    /// DISCARDS a .withoutResponse write that exceeds its own limit: no thrown error, no
    /// didWriteValueFor callback, nothing delivered, nothing logged. Sizing chunks off the
    /// .withResponse limit alone made every single firmware chunk oversized, so the entire
    /// install went out into the void -- the device never received one byte, never sent a
    /// progress ack, and the transfer looked exactly like a hang with zero diagnostics.
    ///
    /// ⚠ 必须按**目标设备**算,不能拿"当前这一台"顶替:两台协商出的 MTU 可以
    /// 不同,按别人的 MTU 切片会让每一片都超限,而 CoreBluetooth 对超限的
    /// withoutResponse 写入是**静默丢弃** —— 不抛错、不回调、不打日志,设备
    /// 一个字节都收不到,界面上看起来就是卡死。
    /// 取不到那台就返回 nil,让调用方明确知道发不了,而不是拿一个编出来的
    /// 保守值继续往下走。
    func appStoreMaxPayloadSize(for device: UUID) -> Int? {
        var result: Int?
        bleQueue.sync {
            guard let p = links[device]?.peripheral else { return }
            let maxLen = min(p.maximumWriteValueLength(for: .withResponse),
                             p.maximumWriteValueLength(for: .withoutResponse))
            result = max(maxLen - 6, 1)
        }
        return result
    }

    // MARK: Connection lifecycle

    private func startScanIfNeeded() {
        guard central != nil, central.state == .poweredOn else { return }
        // ⚠ 不再因为"已经连上一台"就停止扫描。
        //
        // 三五台设备的场景下,不持续扫就永远只看得见当前连着的那一台,
        // 用户没有办法切到别的设备上 —— 界面上会是一份永远只有一行的列表。
        // 代价是持续扫描的功耗,对一个桌面常驻程序可以接受。
        log("开始扫描 \(Self.namePrefix)* ...")
        #if os(iOS)
        // Background discovery only wakes for explicitly requested services.
        // Foreground scanning remains unfiltered so the companion can still
        // discover older firmware and upgrade it to the walkie-capable build.
        let services: [CBUUID]? = UIApplication.shared.applicationState == .background
            ? [Self.walkieServiceUUID] : nil
        #else
        let services: [CBUUID]? = nil
        #endif
        // allowDuplicates:不开的话每台设备一次扫描只回调一次,RSSI 不会更新,
        // 也看不出某台是不是已经走开了。iOS 后台不允许开,那边保持默认。
        #if os(iOS)
        let options: [String: Any]? = nil
        #else
        let options: [String: Any]? = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        #endif
        central.scanForPeripherals(withServices: services, options: options)
    }

    private func restartScanForCurrentState() {
        guard central != nil, central.state == .poweredOn else { return }
        central.stopScan()
        startScanIfNeeded()
    }

    /// Safety net: periodically make sure we are scanning if we've never found the
    /// device yet. Cheap and idempotent (scanForPeripherals is a no-op if already
    /// scanning), so this is a harmless belt-and-suspenders check.
    private func scheduleWatchdog() {
        bleQueue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            self.startScanIfNeeded()
            self.scheduleWatchdog()
        }
    }

    private func scheduleReconnect(to target: CBPeripheral) {
        bleQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            guard self.central.state == .poweredOn else { return } // watchdog will catch it later
            // 以前这里有两条"别抢占"的守卫,因为整个 relay 只有一套特征值
            // 字段,同时连两台会互相覆盖。现在每台一条 DeviceLink,重连谁
            // 就是谁,守卫不再需要 —— 也正是它们让第二台永远连不上。
            // 只跳过两种情况:已经连着的,和用户主动断开过的。
            guard self.links[target.identifier] == nil else { return }
            guard !self.userDisconnectedIDs.contains(target.identifier) else {
                log("放弃重连 \(target.identifier):用户主动断开过")
                return
            }
            log("尝试重新连接 \(target.identifier) ...")
            self.connectLocked(target)
        }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("蓝牙状态变化: \(c.state.rawValue) (5=poweredOn)")
        switch c.state {
        case .poweredOn:
            startScanIfNeeded()
        default:
            // Not usable right now (off/unauthorized/unsupported/resetting/unknown).
            // Do NOT exit -- this is a long-lived relay; the watchdog will resume
            // scanning automatically once the state becomes poweredOn again.
            //
            // ⚠ 这里以前只清了三个特征值,留下 peripheral 和另外三个不动,
            // 也不通知任何人。后果有三个,都不报错:
            //   1. onLinkChange 不发 false —— 界面继续显示"已连接",而链路
            //      已经死了(didDisconnectPeripheral 在关蓝牙这条路上未必来);
            //   2. sendRemoteManifest 看到特征值还非 nil,就直接往死链路写,
            //      被无声丢弃、而且不会补发;
            //   3. startScanIfNeeded 看到 peripheral != nil 提前返回,
            //      看门狗也救不回来。
            // 一并清干净,并且如实广播"断了"。
            // 蓝牙整个关掉 = **所有** link 都没了,不只是活跃那一条。特征值
            // 都挂在 link 上,删掉 link 就一并清干净了。
            // 逐台通知,不是发一次全局"断了" —— 每台有自己的会话,谁的没了
            // 就告诉谁。
            let gone = Array(links.keys)
            links.removeAll()
            for id in discovered.keys {
                discovered[id]?.connected = false
                discovered[id]?.displayed = false
            }
            publishDevices(force: true)
            for id in gone {
                onWalkieLinkChange?(id, false)
                onLinkChange?(id, false, nil)
                onDeviceDetached?(id)
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // ⚠ 广播包里的名字优先,p.name 只作兜底 —— 顺序反了会看到**过期**的名字。
        //
        // p.name 是 CoreBluetooth 缓存的 GAP 名,设备改了名之后它还会返回旧值,
        // 直到系统某个时刻自己刷新。而 CBAdvertisementDataLocalNameKey 来自这一次
        // 扫描响应包,永远是当下的。设备名带 MAC 后缀就是靠它区分多台的,取到
        // 旧名字会让几台设备在界面上重新变得一模一样。
        // ⚠ 名字只能从广播里拿,**不能连上之后去读 GAP 0x2A00**:
        // Apple 平台的 CoreBluetooth 不把 0x1800/0x1801 暴露给应用(系统自己
        // 接管),discoverServices(nil) 的结果里根本没有它们。试过,命中 0 次。
        //
        // 广播包优先、p.name 兜底:p.name 是缓存,设备改名后仍返回旧值。
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? p.name ?? ""
        #if os(iOS)
        // Background scans are already filtered by the unique walkie service.
        // iOS may omit the local name from background advertisements, so do
        // not reject the only matching peripheral merely because name is nil.
        let serviceMatched = UIApplication.shared.applicationState == .background
        guard serviceMatched || name.hasPrefix(Self.namePrefix) else { return }
        #else
        guard name.hasPrefix(Self.namePrefix) else { return }
        #endif
        let shown = name.isEmpty ? Self.namePrefix : name
        let isNew = discovered[p.identifier] == nil
        if isNew { log("发现设备: \(shown) rssi=\(RSSI) id=\(p.identifier)") }

        knownPeripherals[p.identifier] = p     // 必须自己持有,否则会被回收
        discovered[p.identifier] = DiscoveredDevice(
            id: p.identifier, name: shown, rssi: RSSI.intValue,
            lastSeen: Date(), connected: links[p.identifier] != nil,
            displayed: displayedID == p.identifier)
        publishDevices(force: isNew)

        // 扫到的每一台都连上 —— 设备侧 CONFIG_BT_NIMBLE_MAX_CONNECTIONS=1 说的
        // 是"一台设备只接受一个 central",不是"一个 central 只能连一台设备"。
        // 已经连着的、以及用户主动断开过的跳过。
        guard links[p.identifier] == nil else { return }
        guard !userDisconnectedIDs.contains(p.identifier) else { return }
        connectLocked(p)
    }

    /// **必须在 bleQueue 上调。**
    private func connectLocked(_ p: CBPeripheral) {
        // link 在发起连接时就建好,didConnect / 特征值发现都往它里面写。
        links[p.identifier] = links[p.identifier] ?? DeviceLink(peripheral: p)
        userDisconnectedIDs.remove(p.identifier)
        p.delegate = self
        central.connect(p, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
        ])
    }

    /// 把列表交给界面。开了 allowDuplicates 之后 didDiscover 每秒会来很多次,
    /// 不限流的话主线程会被刷新淹掉。新设备出现时强制发一次(那是用户在等的
    /// 事件),其余按 1 秒节流。
    private func publishDevices(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastDevicesPublish) > 1.0 else { return }
        lastDevicesPublish = now
        // ⚠ 连接/活跃状态以 links 为准,不用 discovered 里那份 —— 那份是
        // 扫描回调顺手记的,断开、切换活跃都不会更新它。界面上"哪台连着、
        // 哪台在被驱动"必须跟实际链路一致,否则又是在陈述自己不知道的事。
        for id in discovered.keys {
            discovered[id]?.connected = links[id] != nil
            discovered[id]?.displayed = (id == displayedID)
        }
        // 30 秒没再扫到就当它走了 —— 否则列表只增不减,拔掉的设备会一直挂着。
        let live = discovered.values
            .filter { now.timeIntervalSince($0.lastSeen) < 30 || $0.connected }
            .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
        onDevicesChanged?(live)
    }

    /// 把某台设为"被驱动"的那一台:屏幕内容、对讲下行、固件安装都发给它。
    ///
    /// 多台同时连着的时候,焦点跟着**用户的手**走:在哪台上按键、在哪台上
    /// 按住说话,哪台就成为活跃的。不这样的话用户得先切回电脑上点一下设备
    /// 列表才能用另一台,而他手里已经拿着那台了。
    ///
    /// **必须在 bleQueue 上调。**每一个按键和音频帧都会调到它,所以"已经是
    /// 它了"必须第一时间返回,不能每帧都刷一遍界面。
    /// 用户点了设备列表里的某一行 = "界面切过去看这一台"。
    ///
    /// ⚠ 它**不做任何链路或路由决策**:每台设备一连上就有自己独立的会话,
    /// 三台可以同时在跑。这里改的只是"屏幕上显示谁的那一份"。
    ///
    /// 这里曾经有一个 `makeActive`,在设备按键、按住说话、请求商店目录时
    /// 自动抢焦点。多会话之后它是有害的:同事在 B 上按一下键,你正看着的
    /// 窗口会自己跳走。已删除。
    func showDevice(_ id: UUID) {
        displayedID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.lastDisplayedKey)
        bleQueue.async { [weak self] in
            guard let self, self.links[id] == nil,
                  let target = self.knownPeripherals[id] else { return }
            // 还没连上就顺手连一下 —— 用户点它多半是想用它。
            self.userDisconnectedIDs.remove(id)
            self.connectLocked(target)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        // 每台一条 link。以前这里会把"非当前设备"直接断掉 —— 那是单设备
        // 时代的兜底,现在正是要留住它们。
        links[p.identifier] = links[p.identifier] ?? DeviceLink(peripheral: p)
        // 第一台连上时界面还没看着谁,顺手指过去;之后不再自动改 —— 换台
        // 设备上线不该把你正看着的那一页顶掉。
        if displayedID == nil { displayedID = p.identifier }
        log("已连接 \(p.name ?? Self.namePrefix)(共 \(links.count) 台),开始发现服务...")
        discovered[p.identifier]?.connected = true
        publishDevices(force: true)
        p.delegate = self
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("连接失败: \(String(describing: error)),将自动重试")
        scheduleReconnect(to: p)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let byUser = userDisconnectedIDs.contains(p.identifier)
        log(byUser ? "设备已按用户要求断开"
                   : "设备已断开连接: \(String(describing: error)),将自动重连")
        // ⚠ 只拆**这一台**。特征值都挂在它自己的 link 上,删掉 link 就清干净
        // 了;顺手清别人的会让另一台无声失联 —— 还连着,但什么都收不到。
        links.removeValue(forKey: p.identifier)
        // ⚠ 不做"焦点顺位接管"。以前 A 掉线会把界面凭空切到 B,而且是用
        // onLinkChange(true, …) 报出去的 —— 把一次焦点变化说成一次连接建立。
        // 界面正看着这一台的话,让它显示"这台断了",不要偷偷换一台给用户看。
        // 列表里那一行也必须跟着变灰,否则界面会一直说它连着。
        publishDevices(force: true)
        publishWalkieLinkState(for: p.identifier)
        onLinkChange?(p.identifier, false, nil)
        onDeviceDetached?(p.identifier)
        // 用户主动断开的话就停在这里,等他点"重新扫描"。
        if !byUser { scheduleReconnect(to: p) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        // 恢复**全部**外设,不只是第一台 —— 只恢复一台的话,后台被系统
        // 唤醒之后另外几台就再也回不来了(它们还连着,但没有 link,收到的
        // 回调会被逐个丢掉)。
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        for p in restored {
            links[p.identifier] = links[p.identifier] ?? DeviceLink(peripheral: p)
            p.delegate = self
            if p.state == .connected {
                p.discoverServices(nil)
            } else {
                central.connect(p, options: nil)
            }
            log("恢复 BLE 外设状态:\(p.identifier)")
        }
        if displayedID == nil { displayedID = restored.first?.identifier }
    }

    // MARK: 供界面调用的连接控制

    /// 用户点了"断开":只断指定的那一台,别的连着的不动。
    func disconnectDevice(_ id: UUID) {
        bleQueue.async { [weak self] in
            guard let self = self, let link = self.links[id] else { return }
            self.userDisconnectedIDs.insert(id)
            self.central.cancelPeripheralConnection(link.peripheral)
        }
    }

    /// 用户点了"重新扫描":解除断开状态,忘掉当前这台,重新扫。
    func rescanDevice(_ id: UUID) {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            // ⚠ 只解除**这一台**的"用户主动断开"标记。
            //
            // 以前是 removeAll():你在 B 的配置页点了"断开"、B 变灰待着,
            // 然后切到 A 点一下"重新扫描"(本意是找一台新设备)—— B 一秒内
            // 自己连回来了,而你对 B 什么都没做。一台设备页面上的按钮把另一
            // 台的状态悄悄撤销了。
            //
            // 也不再断开已经连着的设备。以前会把所有 link 断掉,理由是"扫描
            // 扫不到已连上的设备" —— 但已连上的设备本来就不需要被扫到,它
            // 已经在 links 里了。那一刀的代价是:想找一台新设备,就把另外两台
            // 正在跑的固件安装和通话一起掐了。
            self.userDisconnectedIDs.remove(id)
            self.startScanIfNeeded()
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("发现服务出错: \(error)")
            return
        }
        for svc in p.services ?? [] {
            log("发现 service: \(svc.uuid)")
            p.discoverCharacteristics(nil, for: svc)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        // ⚠ 特征值必须写进**这一台自己的** link,不能走上面那组 active 代理。
        // 两台的发现回调是交错到达的,写进 active 那一套会让后到的整个覆盖
        // 先到的:peripheral 指向一台、remoteScreenChar 指向另一台,推屏发到
        // 错误的目标,**两台都收不到**。编译通过、不报错,唯一线索是设备屏幕
        // 上那句"等待电脑推送内容"。这个 bug 真实发生过。
        guard let link = links[p.identifier] else { return }
        if let error = error {
            log("发现特征值出错: \(error)")
            return
        }
        for chr in svc.characteristics ?? [] {
            log("发现 characteristic: \(chr.uuid) properties=\(chr.properties)")
            if chr.uuid == Self.audioCharUUID {
                link.audioChar = chr
                log("发现 AUDIO characteristic,订阅 notify...")
                p.setNotifyValue(true, for: chr)
            } else if chr.uuid == Self.appStoreDataCharUUID {
                link.appStoreDataChar = chr
                log("应用商店 DATA characteristic 就绪,可以开始发送消息")
                pumpAppStore(link)
                link.appStoreReady = true
                announceAttachedIfReady(link)
            } else if chr.uuid == Self.appStoreCmdCharUUID {
                link.appStoreCmdChar = chr
                log("发现应用商店 CMD characteristic,订阅 indicate...")
                p.setNotifyValue(true, for: chr)
            } else if chr.uuid == Self.deviceConfigCharUUID {
                link.deviceConfigChar = chr
                log("设备配置 characteristic 就绪")
                // 配置特征值就绪 = **这一条**链路真的能用了。每台各报各的,
                // 不再按"是不是活跃那台"过滤 —— 那个过滤正是第二台的会话
                // 永远不会被启动的根因:B 特征值全就绪,上层收不到任何事件。
                onLinkChange?(p.identifier, true, p.name)
                link.configReady = true
                announceAttachedIfReady(link)
                publishDevices(force: true)
            } else if chr.uuid == Self.deviceStatusCharUUID {
                log("发现设备状态 characteristic,订阅 notify...")
                link.statusRxBuffer = ""
                p.setNotifyValue(true, for: chr)
            } else if chr.uuid == Self.remoteScreenCharUUID {
                link.remoteScreenChar = chr
                log("远程界面 SCREEN characteristic 就绪")
            } else if chr.uuid == Self.remoteManifestCharUUID {
                link.remoteManifestChar = chr
                log("远程界面 MANIFEST characteristic 就绪")
                // 重连的设备要补一份它自己那份清单 —— 上层只在清单**变化**时
                // 才推,不会为一台重连的设备重推一次。
                if let manifest = link.lastManifest {
                    writeManifest(manifest, to: chr, on: p)
                }
            } else if chr.uuid == Self.remoteEventCharUUID {
                log("发现远程界面 EVENT characteristic,订阅 indicate...")
                p.setNotifyValue(true, for: chr)
            } else if chr.uuid == Self.walkieControlCharUUID {
                link.walkieControlChar = chr
                log("发现对讲 CONTROL characteristic")
            } else if chr.uuid == Self.walkieUplinkCharUUID {
                link.walkieUplinkChar = chr
                log("发现对讲 UPLINK characteristic,订阅 notify...")
                p.setNotifyValue(true, for: chr)
            } else if chr.uuid == Self.walkieDownlinkCharUUID {
                link.walkieDownlinkChar = chr
                log("发现对讲 DOWNLINK characteristic")
                drainWalkieAudio(link)
                link.walkieReady = true
            } else if chr.uuid == Self.walkieStatusCharUUID {
                link.walkieStatusChar = chr
                log("发现对讲 STATUS characteristic,订阅 notify...")
                p.setNotifyValue(true, for: chr)
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor chr: CBCharacteristic, error: Error?) {
        guard chr.uuid == Self.audioCharUUID
              || chr.uuid == Self.appStoreCmdCharUUID
              || chr.uuid == Self.remoteEventCharUUID
              || chr.uuid == Self.deviceStatusCharUUID
              || chr.uuid == Self.walkieUplinkCharUUID
              || chr.uuid == Self.walkieStatusCharUUID else { return }
        if let error = error {
            // Not retried specially -- the existing watchdog/reconnect machinery will
            // naturally get us a fresh connection (and a fresh subscribe attempt) later.
            log("订阅 \(chr.uuid) 特征值失败: \(error)")
            return
        }
        log("\(chr.uuid) 特征值订阅状态: isNotifying=\(chr.isNotifying)")
        // 同样写进这一台自己的 link:两台的订阅回调交错到达,写进 active
        // 那一套会让先就绪的把后一台的状态覆盖掉。
        if chr.uuid == Self.walkieUplinkCharUUID {
            links[p.identifier]?.walkieUplinkSubscribed = chr.isNotifying
        } else if chr.uuid == Self.walkieStatusCharUUID {
            links[p.identifier]?.walkieStatusSubscribed = chr.isNotifying
        }
        publishWalkieLinkState(for: p.identifier)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor chr: CBCharacteristic, error: Error?) {
        // 通知来自哪一台是有意义的:状态缓冲按台各存一份,按键/说话还要
        // 决定把焦点交给谁。没有 link 说明这一台刚被拆掉,丢弃即可。
        guard let link = links[p.identifier] else { return }
        if chr.uuid == Self.audioCharUUID {
            if let error = error {
                log("AUDIO 特征值更新出错: \(error)")
                return
            }
            guard let value = chr.value, !value.isEmpty else {
                log("收到空的 AUDIO 分片(连 flags 字节都没有),忽略")
                return
            }
            let flags = value[value.startIndex]
            let payload = value.count > 1 ? value.subdata(in: value.index(after: value.startIndex)..<value.endIndex) : Data()
            onAudioChunk?(p.identifier, flags, payload)
            return
        }
        if chr.uuid == Self.walkieUplinkCharUUID {
            guard error == nil, let frame = chr.value, WalkieWire.validate(frame) else { return }
            onWalkieAudioFrame?(p.identifier, frame)
            return
        }
        if chr.uuid == Self.walkieStatusCharUUID {
            guard error == nil, let data = chr.value, data.count >= 3,
                  data[0] == WalkieWire.protocolVersion else { return }
            onWalkieStatus?(p.identifier, data[1], data[2])
            return
        }
        if chr.uuid == Self.deviceStatusCharUUID {
            if let error = error {
                log("设备状态更新出错: \(error)")
                return
            }
            guard let v = chr.value, let text = String(data: v, encoding: .utf8) else { return }
            // 缓冲按台各存一份:两台的状态通知交错到达,共用一个缓冲会把
            // 两边的半行拼在一起,解析出来的每一条都是错的。
            link.statusRxBuffer += text
            // 只处理已经完整收到的行,残缺的最后一段留在缓冲里等下一个通知。
            var pairs: [(String, String)] = []
            while let nl = link.statusRxBuffer.firstIndex(of: "\n") {
                let line = String(link.statusRxBuffer[link.statusRxBuffer.startIndex..<nl])
                link.statusRxBuffer = String(link.statusRxBuffer[link.statusRxBuffer.index(after: nl)...])
                // 只按**第一个** '=' 切:值里可能还有 '='(比如某些 SSID)。
                guard let eq = line.firstIndex(of: "=") else { continue }
                pairs.append((String(line[line.startIndex..<eq]),
                              String(line[line.index(after: eq)...])))
            }
            // 缓冲失控保护:设备要是发了一大段没有换行的东西,不能让它无限增长。
            if link.statusRxBuffer.utf8.count > 4096 {
                log("设备状态缓冲超长,丢弃")
                link.statusRxBuffer = ""
            }
            // ⚠ 每台的状态都要上报。以前这里按"活跃那台"过滤,而设备只在
            // 状态**变化**时通知一次 —— 过滤掉就永久丢了,那台的配置页会一直
            // 停在旧值。界面只显示正在看的那一台,那是界面的事,不是这里的事。
            if !pairs.isEmpty { onDeviceStatus?(p.identifier, pairs) }
            return
        }
        if chr.uuid == Self.remoteEventCharUUID {
            if let error = error {
                log("远程界面 EVENT 更新出错: \(error)")
                return
            }
            guard let v = chr.value, v.count >= 3 else { return }
            let b = [UInt8](v)
            // 事件码见 main/remote_ui.c:43-46。这里**不再有任何过滤**:每台
            // 设备的事件都原样交给它自己那个会话。以前这里按"活跃那台"过滤,
            // 并且在按键时抢焦点 —— 前者让第二台的事件全被吃掉,后者让同事
            // 在 B 上按一下键,你正看着的窗口自己跳走。
            switch b[0] {
            case 3: link.inRemoteApp = true            // OPEN:进了某个应用
            case 1, 2: link.inRemoteApp = (b[1] == 1)  // ACTIVE / HELLO 自报在不在远程页
            default: break
            }
            onRemoteEvent?(p.identifier, b[0], b[1], b[2])
            return
        }
        if chr.uuid == Self.appStoreCmdCharUUID {
            if let error = error {
                log("应用商店 CMD 特征值更新出错: \(error)")
                return
            }
            guard let value = chr.value else { return }
            let bytes = [UInt8](value)
            guard bytes.count >= 3 else {
                log("收到的应用商店 CMD 请求长度不足,忽略: \(bytes.count) 字节")
                return
            }
            log("收到应用商店 CMD 请求: req=\(bytes[0]) a=\(bytes[1]) b=\(bytes[2])")
            onAppStoreCmdRequest?(p.identifier, bytes[0], bytes[1], bytes[2])
            return
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor chr: CBCharacteristic, error: Error?) {
        // ⚠ 必须**按 UUID 精确分派**,不能写成"是应用商店就 A,否则 B"。
        //
        // 这个回调对**每一个** .withResponse 写入都会触发。只有应用商店 DATA
        // 那一条有分片队列需要推进;配置下发、远程推屏、清单推送也都是
        // .withResponse 的,但它们整段一次写完,没有队列。
        //
        // 早先这里写的是"是应用商店就 A,否则 B",于是后三者的完成回调会被
        // 当成分片完成,把别人的流水线推着往前走 —— 表现为内容偶尔缺一段,
        // 而且只在两条路径恰好撞上时才出现,极难复现。按 UUID 精确分派之后
        // 这类串台在结构上就不可能发生了。
        switch chr.uuid {
        case Self.appStoreDataCharUUID:
            // 推进的是**这一台自己**那条队列。目录是广播的,共用一条的话
            // 先回调的那台会吃掉别人的分片 —— 编译通过,表现是另一台的
            // 商店页永远少几行。
            guard let link = links[p.identifier] else { return }
            link.appStoreWaitingForWriteCallback = false
            if let error = error {
                log("应用商店写入出错: \(error),丢弃当前消息剩余分片")
                link.appStoreChunkQueue.removeAll()
            }
            pumpAppStore(link)

        default:
            // 配置 / 推屏 / 清单:整段一次写完,没有分片队列要推进。
            // 出错值得记一笔(否则界面上会表现为"下发了但设备没反应"),
            // 但绝不能碰上面两条流水线的状态。
            if let error = error {
                log("写入 \(chr.uuid) 出错: \(error)")
            }
        }
    }

    /// CoreBluetooth's local send-buffer had no room the last time
    /// drainAppStoreBatch() tried to write -- resume from exactly where it left off.
    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        // 两条流水线都是每台各一份 —— 谁报的流控就续谁的。
        // 以前这里按"活跃那台"过滤:在 A 上装固件时有人碰一下 B,焦点跟过去,
        // A 的续传就再也等不到流控,只能靠 5 秒超时一批一批爬。
        guard let link = links[p.identifier] else { return }
        drainWalkieAudio(link)
        if let resume = link.pendingBatchResume {
            link.pendingBatchResume = nil
            link.pendingBatchResumeToken &+= 1
            resume()
        }
    }

    // MARK: Send pipeline

    /// Drives the send state machine. Must only be called on bleQueue.
    /// App Store equivalent of pump() -- separate queue/characteristic, same state
    /// machine shape. Must only be called on bleQueue.
    private func pumpAppStore(_ link: DeviceLink) {
        guard let chr = link.appStoreDataChar else { return }
        let p = link.peripheral
        guard !link.appStoreWaitingForWriteCallback else { return }

        if link.appStoreChunkQueue.isEmpty {
            guard !link.appStoreMessageQueue.isEmpty else { return }
            let msg = link.appStoreMessageQueue.removeFirst()
            let maxLen = p.maximumWriteValueLength(for: .withResponse)
            let payloadSize = max(maxLen - 6, 1)
            link.appStoreChunkQueue = Self.buildAppStoreChunks(kind: msg.kind, index: msg.index,
                                                               total: msg.total, payload: msg.payload,
                                                               payloadSize: payloadSize)
            // This queue/pump pair now only ever carries kind=item messages (a handful
            // per REQ_LIST_APPS, never more) -- firmware transfer bypasses it entirely
            // via sendAppStoreBatch(withoutResponse:) below, so logging every message
            // here is cheap and fine.
            log("应用商店:开始发送消息 kind=\(msg.kind) index=\(msg.index) total=\(msg.total) 分片数=\(link.appStoreChunkQueue.count) payloadSize=\(payloadSize) 字节数=\(msg.payload.count)")
        }

        guard !link.appStoreChunkQueue.isEmpty else { return }
        let chunk = link.appStoreChunkQueue.removeFirst()
        link.appStoreWaitingForWriteCallback = true
        p.writeValue(chunk, for: chr, type: .withResponse)
    }

    /// Data-based equivalent of buildChunks() below -- no String/UTF-8 involved, since
    /// firmware bytes (kind=firmware) can contain any byte value including embedded NULs
    /// and sequences that aren't valid UTF-8. Catalog item text (kind=item) is also sent
    /// through this path, pre-encoded to UTF-8 Data by the caller. Chunk boundaries can
    /// fall anywhere -- there's no multi-byte-character concern for raw binary data.
    ///
    /// `index`/`total` mean two DIFFERENT things depending on `kind`, and the START/END
    /// flags must be computed accordingly -- getting this wrong is what caused every
    /// firmware chunk to be independently esp_ota_begin()/esp_ota_end()'d on the device
    /// (main/demo_appstore.c), re-erasing the whole partition and finalizing a ~500-byte
    /// "image" on literally every single chunk:
    /// - kind=item: index/total = "which catalog entry, out of how many" -- each entry is
    ///   its own independent message that the device reassembles separately (its own
    ///   START clears the accumulator, its own END dispatches it). Payload-position-based
    ///   flags (the original logic) are correct here.
    /// - kind=firmware: index/total = "which piece of ONE continuous multi-thousand-chunk
    ///   stream, out of how many total". AppStoreModel.installApp() already pre-slices
    ///   each piece to fit in a single wire packet, so from a payload-position view every
    ///   single piece trivially looks like both the start AND end of "its own message" --
    ///   exactly the bug. START/END must instead reflect position in the OVERALL stream:
    ///   only global chunk 0 is START, only global chunk (total-1) is END.
    static func buildAppStoreChunks(kind: UInt8, index: UInt16, total: UInt16, payload: Data,
                                    payloadSize: Int) -> [Data] {
        let isStreamPiece = (kind == AppStoreKind.firmware)

        if payload.isEmpty {
            let isFirst = !isStreamPiece || index == 0
            let isLast = !isStreamPiece || index == total - 1
            var flags: UInt8 = 0
            if isFirst { flags |= RelayFlags.start }
            if isLast { flags |= RelayFlags.end }
            let data = Data([flags, kind,
                             UInt8(index & 0xFF), UInt8(index >> 8),
                             UInt8(total & 0xFF), UInt8(total >> 8)])
            return [data]
        }

        var chunks: [Data] = []
        var offset = payload.startIndex
        while offset < payload.endIndex {
            let end = payload.index(offset, offsetBy: payloadSize, limitedBy: payload.endIndex) ?? payload.endIndex
            let isFirstFragment = (offset == payload.startIndex)
            let isLastFragment = (end == payload.endIndex)
            var flags: UInt8 = 0
            let isStart = isStreamPiece ? (index == 0 && isFirstFragment) : isFirstFragment
            let isEnd = isStreamPiece ? (index == total - 1 && isLastFragment) : isLastFragment
            if isStart { flags |= RelayFlags.start }
            if isEnd { flags |= RelayFlags.end }
            var data = Data([flags, kind,
                             UInt8(index & 0xFF), UInt8(index >> 8),
                             UInt8(total & 0xFF), UInt8(total >> 8)])
            data.append(payload[offset..<end])
            chunks.append(data)
            offset = end
        }
        return chunks
    }

    // MARK: App Store firmware batch transfer (write without response)

    /// Queued once a caller asks to send a batch while CoreBluetooth's local send buffer
    /// is full; resumed from peripheral(_:isReadyToSendWriteWithoutResponse:).

    /// Sends `chunks` (already fully framed by AppStoreModel via buildAppStoreChunks) as
    /// write-without-response, respecting CoreBluetooth's local flow control
    /// (canSendWriteWithoutResponse) instead of waiting for a per-chunk ATT response --
    /// that per-chunk round trip is what made a firmware install take 10+ minutes despite
    /// a healthy link. Unlike pump()/pumpAppStore(), this does NOT wait for the device to
    /// confirm anything; AppStoreModel handles that at a higher level via the
    /// APPSTORE_EVT_PROGRESS batch-acknowledgment protocol (see its sendNextBatch()),
    /// which is also what makes retrying a batch safe (the device skips chunks it has
    /// already written, so resending is idempotent).
    ///
    /// `completion` fires once every chunk in the batch has been handed to CoreBluetooth
    /// -- that only means "accepted for transmission locally", not "delivered", exactly
    /// like the flow-control contract write-without-response always has.
    func sendAppStoreBatch(withoutResponse chunks: [Data], to device: UUID,
                           completion: @escaping () -> Void) {
        bleQueue.async { [weak self] in
            guard let self, let link = self.links[device] else {
                log("应用商店:目标设备已不在线,放弃这一批(共 \(chunks.count) 片)")
                completion()
                return
            }
            self.drainAppStoreBatch(chunks, from: 0, on: link, completion: completion)
        }
    }

    /// 下发一批配置项。每项一行 "<key>=<value>",一次写完。
    ///
    /// 用 .withResponse:配置是低频小数据,可靠性远比吞吐重要,而且写失败时
    /// didWriteValueFor 会带错误回来 —— 用户在界面上点了"保存"就该知道到底
    /// 存没存上,不能像固件分片那样"发出去就算数"。
    func sendDeviceConfig(_ pairs: [(String, String)], to device: UUID,
                          completion: @escaping (Bool) -> Void) {
        bleQueue.async { [weak self] in
            guard let self = self, let link = self.links[device],
                  let chr = link.deviceConfigChar else {
                log("设备配置:没有可用的连接")
                completion(false)
                return
            }
            let p = link.peripheral
            let text = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
            guard let data = text.data(using: .utf8) else { completion(false); return }
            // 设备端缓冲区 512 字节,超了会被截断 —— 分批发,不要指望对端兜底。
            let maxLen = min(p.maximumWriteValueLength(for: .withResponse), 500)
            var offset = 0
            while offset < data.count {
                let end = min(offset + maxLen, data.count)
                p.writeValue(data.subdata(in: offset..<end), for: chr, type: .withResponse)
                offset = end
            }
            log("设备配置:已下发 \(pairs.count) 项")
            completion(true)
        }
    }

    /// 推一屏内容给设备。设备靠结尾的换行判断收齐,所以拆包发送时不能在
    /// 中间截断 —— 这里整段一次写,超过 MTU 的部分由 CoreBluetooth 自己分片,
    /// 设备侧会攒到看见换行为止。
    /// 推一屏内容给**指定的那一台**。
    ///
    /// 这里曾经按"谁在远程应用里"扇出给多台,那是"一个会话、几面镜子"时代
    /// 的做法。每台设备有自己独立的会话之后,一屏内容只属于一台 —— 扇出去
    /// 就是把 A 的界面画到 B 的屏幕上。
    func sendRemoteScreen(_ text: String, to device: UUID) {
        bleQueue.async { [weak self] in
            guard let self = self, let link = self.links[device],
                  let chr = link.remoteScreenChar else { return }
            let p = link.peripheral
            guard let data = text.data(using: .utf8) else { return }
            // 设备接收缓冲 1KB;超了它会整屏丢弃,与其那样不如这里就截断到
            // 最后一个完整行,至少还能显示前半屏。
            var payload = data
            if payload.count > 1000 {
                let head = payload.prefix(1000)
                if let lastNewline = head.lastIndex(of: 0x0A) {
                    payload = Data(head[...lastNewline])
                } else {
                    payload = Data(head)
                }
                log("远程界面:内容过长已截断到 \(payload.count) 字节")
            }
            let maxLen = min(p.maximumWriteValueLength(for: .withResponse), 500)
            var offset = 0
            while offset < payload.count {
                let end = min(offset + maxLen, payload.count)
                p.writeValue(payload.subdata(in: offset..<end), for: chr, type: .withResponse)
                offset = end
            }
        }
    }

    /// 推已安装应用清单给设备(一行一个名字,结尾必须有换行)。
    ///
    /// 推已安装应用清单给**指定的那一台**。
    ///
    /// 清单内容目前对每台都一样(装了什么是这台电脑的决定,不是每台设备
    /// 各自的),但发送仍然按设备走:每台记住自己收到过什么,重连时才能
    /// 只补它自己那一份,而不是靠一个全局变量猜。
    func sendRemoteManifest(_ text: String, to device: UUID) {
        bleQueue.async { [weak self] in
            guard let self = self, let link = self.links[device] else { return }
            // 发出去也留着:这台重连时靠它补首屏(见特征值发现)。只保留
            // 最新的一份 —— 清单是全量覆盖语义,补发旧版本没有意义。
            link.lastManifest = text
            guard let chr = link.remoteManifestChar else { return }
            self.writeManifest(text, to: chr, on: link.peripheral)
        }
    }

    /// 同一份清单发给每一台。装卸应用改的是这台电脑的决定,对所有设备成立。
    func broadcastRemoteManifest(_ text: String) {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            for link in self.links.values {
                link.lastManifest = text
                guard let chr = link.remoteManifestChar else { continue }
                self.writeManifest(text, to: chr, on: link.peripheral)
            }
        }
    }

    /// ⚠ CONTROL **绝不能**广播,只发给活跃那一台。
    ///
    /// 设备侧 CONTROL_START 的意思是"**你**开始发话"
    /// (`main/walkie_audio.c:261` 置 `s_tx_requested = true`,随后开麦采集),
    /// 不是"有人在讲话、准备放音"。广播出去等于把房间里每一台的麦克风都打开。
    /// 放音那一侧根本不需要 CONTROL:`downlink_access_cb` 收到帧就播
    /// (`main/walkie_audio.c:276`),所以下行音频广播是安全的,控制不是。
    ///
    /// 目标由调用方显式给出:每台设备有自己的 WalkieClient,是它自己那位
    /// "人"在抢麦,控制帧就回给它自己。
    func sendWalkieControl(operation: UInt8, stream: UInt16, to device: UUID) {
        bleQueue.async { [weak self] in
            guard let self, let link = self.links[device],
                  let chr = link.walkieControlChar else {
                return
            }
            let payload = Data([
                WalkieWire.protocolVersion, operation,
                UInt8(stream & 0xff), UInt8(stream >> 8),
            ])
            link.peripheral.writeValue(payload, for: chr, type: .withResponse)
        }
    }

    /// 服务器来的声音发给**这一台**。
    ///
    /// 这里曾经广播给所有设备,还额外把 A 的上行本地环回给 B —— 那是因为
    /// 几台设备共用一个 WalkieClient、在服务器眼里是同一个人,自己听不到
    /// 自己。现在每台各是服务器上独立的一位,A 说的话由服务器转给 B,
    /// 再叠一层本地环回就是双份加回声,而且会绕过服务器的抢麦仲裁 ——
    /// A 没抢到麦,声音照样进 B 的喇叭。两处都已删除。
    func sendWalkieAudio(_ frame: Data, to device: UUID) {
        guard WalkieWire.validate(frame) else { return }
        bleQueue.async { [weak self] in
            guard let self, let link = self.links[device],
                  link.walkieDownlinkChar != nil else { return }
            link.walkieAudioQueue.enqueue(frame)
            self.drainWalkieAudio(link)
        }
    }

    private func drainWalkieAudio(_ link: DeviceLink) {
        guard let chr = link.walkieDownlinkChar else { return }
        let p = link.peripheral
        while !link.walkieAudioQueue.isEmpty && p.canSendWriteWithoutResponse {
            let frame = link.walkieAudioQueue.removeFirst()
            guard frame.count <= p.maximumWriteValueLength(for: .withoutResponse) else {
                log("对讲音频帧超过当前 BLE MTU,已丢弃:\(frame.count) 字节")
                continue
            }
            p.writeValue(frame, for: chr, type: .withoutResponse)
        }
    }

    /// 每台各报各的对讲链路状态 —— 每台设备有自己的 WalkieClient,
    /// "对讲能不能用"是那一台自己的事。
    private func publishWalkieLinkState(for id: UUID) {
        let ready = links[id].map { link in
            link.peripheral.state == .connected &&
            link.walkieControlChar != nil && link.walkieDownlinkChar != nil &&
            link.walkieUplinkSubscribed && link.walkieStatusSubscribed
        } ?? false
        onWalkieLinkChange?(id, ready)
    }

    /// 这条链路够用了就通知上层为它建会话。只报一次。
    private func announceAttachedIfReady(_ link: DeviceLink) {
        guard !link.attachAnnounced, link.configReady, link.appStoreReady else { return }
        link.attachAnnounced = true
        log("设备会话就绪:\(link.peripheral.name ?? link.id.uuidString)")
        onDeviceAttached?(link.id)
    }

    /// Must only be called on bleQueue.
    private func writeManifest(_ text: String, to chr: CBCharacteristic, on p: CBPeripheral) {
        guard var payload = text.data(using: .utf8) else { return }
        // 设备侧缓冲 512 字节,超了它整份丢弃。截到最后一个完整行,至少前
        // 几个应用还能出现在首屏。留 1 字节给下面补回的哨兵换行。
        if payload.count > 499 {
            let head = payload.prefix(499)
            if let lastNewline = head.lastIndex(of: 0x0A) {
                // ⚠ 截断后必须把哨兵补回来:设备等的是空行(连着两个换行)。
                // 截到行尾只留下一个换行,设备会一直等下去,首屏永远不更新。
                payload = Data(head[...lastNewline]) + Data([0x0A])
            } else {
                // 一个换行都没有,发过去设备也凑不齐一份完整清单,不如不发。
                log("远程界面:清单格式异常(没有换行),丢弃")
                return
            }
            log("远程界面:清单过长已截断到 \(payload.count) 字节")
        }
        // 这里分包发是正常的 —— iOS 的 ATT MTU 只有 185,一份满清单必然
        // 拆成几包。设备靠结尾的空行判断收齐,不靠包边界。
        let maxLen = max(p.maximumWriteValueLength(for: .withResponse), 1)
        var offset = 0
        while offset < payload.count {
            let end = min(offset + maxLen, payload.count)
            p.writeValue(payload.subdata(in: offset..<end), for: chr, type: .withResponse)
            offset = end
        }
    }

    /// Must only be called on bleQueue.
    private func drainAppStoreBatch(_ chunks: [Data], from start: Int, on link: DeviceLink,
                                    completion: @escaping () -> Void) {
        let p = link.peripheral
        guard let chr = link.appStoreDataChar else {
            log("应用商店:没有可用的连接,放弃发送这一批(共 \(chunks.count) 片)")
            completion()
            return
        }
        var i = start
        while i < chunks.count {
            guard p.canSendWriteWithoutResponse else {
                // Don't rely solely on peripheralIsReady(toSendWriteWithoutResponse:) to
                // ever fire -- this Mac's Bluetooth stack has been flaky all session
                // (repeated resets, mystery slowness), and that delegate callback has
                // never actually been exercised here before now. If it silently never
                // arrives, the batch (and everything after it, since the retry-timeout
                // is only ever armed inside this call's completion) would hang forever
                // with zero further log output -- exactly what happened on the first
                // real test of this path. A short fallback poll guarantees forward
                // progress either way; whichever of the two fires first consumes
                // pendingBatchResume and the other becomes a no-op.
                let resume: () -> Void = { [weak self, weak link] in
                    guard let link else { return }
                    self?.drainAppStoreBatch(chunks, from: i, on: link, completion: completion)
                }
                link.pendingBatchResume = resume
                link.pendingBatchResumeToken &+= 1
                let myToken = link.pendingBatchResumeToken
                bleQueue.asyncAfter(deadline: .now() + 0.2) { [weak self, weak link] in
                    // ⚠ 必须校验令牌,不能只判断 pendingBatchResume 非空。常见时序是:
                    // 真正的流控回调先一步(比如 50ms)恢复并发完了这一批,上层收到
                    // 回执又发下一批、下一批也挂起等待 —— 此时槽位里放的已经是新
                    // 批次的恢复闭包了。这个迟到的定时器若只看"非空",就会把新批次
                    // 的等待清掉、转而重发上一批已经发完的内容:新批次从此永久停摆
                    // (只发出去了挂起前的那几片),旧内容变成重复分片让设备补报一个
                    // 只前进 1 的确认号,整批只能靠 5 秒超时重发才走完 —— 实测每一批
                    // 都卡满一个超时周期,比不批量还慢。
                    guard self != nil, let link, link.pendingBatchResumeToken == myToken,
                          link.pendingBatchResume != nil else { return }
                    link.pendingBatchResume = nil
                    link.pendingBatchResumeToken &+= 1
                    resume()
                }
                return
            }
            p.writeValue(chunks[i], for: chr, type: .withoutResponse)
            i += 1
        }
        completion()
    }

}
