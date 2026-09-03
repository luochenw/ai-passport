import Foundation
import SwiftUI

// =====================================================================
// 每台设备一个独立会话
//
// 用户的原话:「两个设备就是两个应用,不能共用」。
//
// 在这之前,几台设备共用**一个** RemoteAppHost 前台会话和**一个**
// WalkieClient —— 它们只是同一份状态的几面镜子。后果是具体的:两台在
// 一个房间里互相听不见(在对讲服务器眼里是同一个客户端,而服务器不会把
// 你自己的声音回给你);名单里永远只有一个人;一台上线会把另一台正在用
// 的应用踢回首屏。
//
// 现在每台设备连上就得到一个 DeviceSession —— 它自己的应用实例、它自己
// 的浏览位置、它自己在对讲服务器上的身份。界面同一时刻显示其中一个
// (SessionRouter.selectedID),但**所有会话都在跑**,不是只有被看着的
// 那个。
//
// 判据:描述「这一台设备,或它前面那个人」的,进 DeviceSession;描述
// 「这台电脑的无线电、这台电脑装了什么、这个系统只有一份的资源」的,
// 留在 AppCore。中间地带(固件安装、iOS 系统 PTT)不是二选一,而是
// 「机制每设备一份、策略全局串行」—— 机制不隔离会互相踩坏字节,策略不
// 串行会争抢带宽和系统独占资源。
// =====================================================================

/// 会话之间共享、不该每台一份的东西。
struct SharedServices {
    let relay: BLERelay
    /// 吃饭是纯读 + 本地提醒,服务端也不按 client 解复用 —— 全局一个客户端,
    /// 每台各有自己的 MealApp(浏览到哪一天、装没装,是每台自己的事)。
    let mealClient: MealClient
    /// 饭点提醒的调度器。全局一份 —— 通知弹给的是**一个人**,不是一台设备。
    let mealNotifications: MealNotificationScheduler
}

/// 一台设备的全部主观世界。
final class DeviceSession {
    let deviceID: UUID
    /// 广播名,比如 `FoloPassport-2C44`。用来给这台在对讲房间里起个能区分的
    /// 昵称,以及在界面上说清楚"你正在看哪一台"。
    let deviceName: String

    let remoteHost: RemoteAppHost
    let remoteAppsModel: RemoteAppsModel
    let appStoreModel: AppStoreModel
    let deviceConfigModel: DeviceConfigModel
    let walkieCapability: WalkieCapability
    let mealApp: MealApp

    private let walkieClient: WalkieClient
    private let voicePipeline: VoiceInputPipeline

    #if os(macOS)
    private let codexBrowser: CodexBrowserModel
    #endif

    /// 界面上给这台起的短名:`FoloPassport-2C44` → `2C44`。
    var shortName: String {
        deviceName.hasPrefix(BLERelay.namePrefix + "-")
            ? String(deviceName.dropFirst(BLERelay.namePrefix.count + 1))
            : deviceName
    }

    /// `enableDebugChannel` 只给**第一个**会话开。
    ///
    /// 那条 `/tmp/folo_remote_sim` 通道是自递归轮询、而且没有取消路径 ——
    /// 每台设备各开一条的话,插三台就有三个定时器永远跑着,而且三个都会
    /// 抢同一个文件里的同一条命令,谁抢到不确定。
    init(deviceID: UUID, deviceName: String, shared: SharedServices,
         enableDebugChannel: Bool = false) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        let relay = shared.relay

        // 对讲身份按设备分。⚠ 同一房间里两条连接用同一个 clientId 会被服务端
        // 顶号(services/walkie-server/main.go:296-308),两台会每两秒互踢一次。
        // 昵称默认派生自广播名,否则房间名单里两行一模一样、谁也分不出谁。
        let short = deviceName.hasPrefix(BLERelay.namePrefix + "-")
            ? String(deviceName.dropFirst(BLERelay.namePrefix.count + 1))
            : deviceName
        walkieClient = WalkieClient(deviceKey: deviceID.uuidString,
                                    defaultName: short.isEmpty ? "Passport" : "Passport-" + short)
        walkieCapability = WalkieCapability(client: walkieClient)
        // 提醒调度器全局一份:通知是弹给**一个人**看的,跟他手里有几台
        // Passport 无关;而且通知标识符没有设备区分,每台各起一个调度器的话,
        // 后一个 update 会把前一个排好的饭点通知全删掉。
        mealApp = MealApp(client: shared.mealClient,
                          deviceKey: deviceID.uuidString,
                          notifications: shared.mealNotifications)

        // 语音重组缓冲每台一份。共用的话,B 的 START 会把 A 已经录了几秒的
        // 话直接丢掉,日志里只有一行"丢弃"。
        // (SFSpeechRecognizer 的授权是进程级的,重复请求不会重复弹窗。)
        voicePipeline = VoiceInputPipeline()

        #if os(macOS)
        var codexSink: ((UInt8, UInt16, UInt16, String) -> Void)?
        let browser = CodexBrowserModel(sender: { kind, index, total, text in
            codexSink?(kind, index, total, text)
        })
        codexBrowser = browser
        voicePipeline.sessionContextProvider = { completion in
            browser.currentSessionContext(completion: completion)
        }
        // 发送失败要回给**发起的那一台** —— 以前它广播给所有设备,别人会
        // 莫名其妙看到一条自己没发过的语音失败。
        voicePipeline.onSendFailure = { reason in
            browser.reportVoiceError(reason)
        }
        let pipeline = voicePipeline
        voicePipeline.onTranscript = { text, threadId, model in
            HeadlessCodexSender.send(threadId: threadId, model: model, text: text,
                                     onFailure: pipeline.onSendFailure)
        }
        #endif

        appStoreModel = AppStoreModel(
            sender: { [relay] kind, index, total, payload in
                relay.enqueueAppStore(kind: kind, index: index, total: total,
                                      payload: payload, to: deviceID)
            },
            // ⚠ 按**这一台**的 MTU 算。两台协商出的 MTU 可以不同,按别人的
            // 切片会让每一片都超限,而 CoreBluetooth 对超限的 withoutResponse
            // 写入是静默丢弃 —— 表现为进度条卡死,没有任何报错。
            maxPayloadSize: { [relay] in
                relay.appStoreMaxPayloadSize(for: deviceID) ?? max(23 - 6, 1)
            },
            cancelTransfer: { [relay] in relay.cancelAppStoreTransfer(for: deviceID) },
            sendBatch: { [relay] chunks, completion in
                relay.sendAppStoreBatch(withoutResponse: chunks, to: deviceID,
                                        completion: completion)
            },
            enableDebugChannel: enableDebugChannel
        )

        remoteHost = RemoteAppHost(
            send: { [relay] text in relay.sendRemoteScreen(text, to: deviceID) },
            sendManifest: { [relay] text in relay.sendRemoteManifest(text, to: deviceID) },
            // 通知走 cmd.notify —— 现成的非持久化命令通道。发给这一台,不广播:
            // 通知的内容属于这台设备上正在跑的那个应用。
            sendNotify: { [relay] text in
                relay.sendDeviceConfig([("cmd.notify", text)], to: deviceID) { ok in
                    if !ok { log("[notify] 下发失败") }
                }
            },
            // 已安装清单每台一份:设备用**自己缓存的那份**清单算 OPEN 下标,
            // 发出去的和算下标用的必须是同一份。
            deviceKey: deviceID.uuidString,
            enableDebugChannel: enableDebugChannel
        )
        // ⚠ 观察者必须在 register() **之前**装好。register() 的函数体跑在
        // host 的串行队列上并会发布一次列表,晚装的话那几次发布全部丢给 nil,
        // 而列表只在 register / 装卸时发布,错过就再没有第二次机会 ——
        // 「应用」标签页会永远显示"还没有可用的应用"。
        remoteAppsModel = RemoteAppsModel(host: remoteHost)

        deviceConfigModel = DeviceConfigModel(
            sender: { [relay] pairs, completion in
                relay.sendDeviceConfig(pairs, to: deviceID, completion: completion)
            },
            bleDisconnect: { [relay] in relay.disconnectDevice(deviceID) },
            bleRescan: { [relay] in relay.rescanDevice(deviceID) },
            // ⚠ 音量、亮度、状态栏是**这一台设备**的设置,不是这台电脑的。
            // 共用一份的话在 A 上调亮度,B 的滑块下次启动也跟着变,而 B 的
            // 屏幕其实没动过 —— 用户在两台之间来回改,永远调不对。
            deviceKey: deviceID.uuidString,
            enableDebugChannel: enableDebugChannel
        )

        // 应用实例每会话各 new 一份。RemoteApp 的 requestPush / notify 都是
        // 单槽赋值,一份实例结构上就服务不了两个 host —— 共用的话第二个
        // host 的注入会静默覆盖第一个,第一台的那个应用从此推不出任何东西。
        // 看板是第一个**清单应用**:名字、图标、五页长什么样、按键怎么绑
        // 都在 AppManifests/dashboard.json 里,这边只提供它描述不了的那部分
        // (带证书校验的 HTTPS 请求 + 轮询)。清单读不到就跳过 —— 注册一个
        // 画不出东西的空壳,比首屏少一个图标更难查。
        if let manifest = ManifestStore.load(DashboardCapability.id) {
            remoteHost.register(ManifestApp(manifest: manifest,
                                            capability: DashboardCapability()))
        }
        if let manifest = ManifestStore.load(WalkieCapability.id) {
            let app = ManifestApp(manifest: manifest, capability: walkieCapability)
            // 后台来话的通知走 cmd.notify,跟屏幕是两条路 —— 能力自己发不了,
            // 得由解释器把 host 注入的那个通道转给它。
            walkieCapability.notify = { [weak app] text in app?.notify?(text) }
            remoteHost.register(app)
        }
        remoteHost.register(mealApp)

        #if os(macOS)
        let codexApp = CodexApp(browser: codexBrowser)
        #else
        let codexApp = CodexApp(
            browser: nil,
            unavailableReason: "Codex 需要在 Mac 上运行:它要启动 codex 命令行进程并读取本机的会话记录,iOS 两者都做不到。"
        )
        #endif
        #if os(macOS)
        codexSink = { [weak codexApp] kind, index, total, text in
            codexApp?.handleOutput(kind: kind, index: index, total: total, text: text)
        }
        #endif
        remoteHost.register(codexApp)

        walkieClient.sendDeviceControl = { [relay] operation, stream in
            relay.sendWalkieControl(operation: operation, stream: stream, to: deviceID)
        }
        walkieClient.sendDeviceAudio = { [relay] frame in
            relay.sendWalkieAudio(frame, to: deviceID)
        }

        deviceConfigModel.applyLinkChange(connected: true, name: deviceName)
        remoteAppsModel.isConnected = true
        appStoreModel.isConnected = true
        remoteHost.setDeviceLinked(true)

        #if os(macOS)
        codexBrowser.start()
        voicePipeline.start()
        #endif
    }

    // MARK: 来自 relay 的事件(全部已经按设备分发好了)

    func handleRemoteEvent(_ evt: UInt8, _ a: UInt8, _ b: UInt8) {
        switch evt {
        case 0: remoteHost.handleKey(a, b)          // 按键
        case 1: remoteHost.setDeviceActive(a == 1)  // 进/出远程界面
        case 2: remoteHost.deviceReady(active: a == 1, appIndex: b)
        case 3: remoteHost.openApp(a)               // 首屏选中第 a 项(0xFE = 应用商店)
        default: break
        }
    }

    func handleAudioChunk(flags: UInt8, payload: Data) {
        voicePipeline.handleChunk(flags: flags, payload: payload)
    }

    func handleWalkieAudio(_ frame: Data) { walkieClient.handleDeviceAudio(frame) }
    func handleWalkieStatus(_ event: UInt8, code: UInt8) {
        walkieClient.handleDeviceStatus(event, code: code)
    }
    func setWalkieLinked(_ connected: Bool) { walkieClient.setDeviceConnected(connected) }

    func handleAppStoreRequest(req: UInt8, a: UInt8, b: UInt8) {
        appStoreModel.handleRequest(req: req, a: a, b: b)
    }

    func handleDeviceStatus(_ pairs: [(String, String)]) {
        DispatchQueue.main.async { self.deviceConfigModel.applyDeviceStatus(pairs) }
    }

    /// 链路断了。会话对象**留着**(浏览位置、身份都还在,重连不用从首屏
    /// 重来),但连接立刻断开 —— BLE 掉线在这个项目里是常态,每次重连都
    /// 回首屏很烦;而常驻的 WebSocket 和轮询定时器不该跟着攒。
    func detach() {
        DispatchQueue.main.async {
            self.deviceConfigModel.applyLinkChange(connected: false, name: nil)
            self.remoteAppsModel.isConnected = false
            self.appStoreModel.isConnected = false
        }
        remoteHost.setDeviceLinked(false)
        walkieClient.setDeviceConnected(false)
    }

    #if os(iOS)
    /// 把系统级 PTT 交给这个会话。**只有一个会话能持有它**(见 AppCore)。
    ///
    /// 没拿到的会话不做任何降级动作 —— `systemPTTAvailable` 不注入,
    /// WalkieClient 自己会走前台路径。它们必须**主动撤销**推送注册:
    /// 服务器只排除说话人自己的 clientId(main.go:402-406),不撤的话你
    /// 用另一台设备说话会把自己的手机唤醒,正在讲的半句被系统掐掉。
    func bindSystemPushToTalk(_ ptt: SystemPushToTalk) {
        walkieClient.systemPTTAvailable = { [weak ptt] in ptt?.isReady ?? false }
        walkieClient.requestSystemTransmit = { [weak ptt] in ptt?.beginTransmitting() }
        walkieClient.stopSystemTransmit = { [weak ptt] in ptt?.stopTransmitting() }
        walkieClient.onRemoteSpeakerChanged = { [weak ptt] speaker in
            ptt?.setRemoteSpeaker(speaker)
        }
        ptt.onPushToken = { [walkieClient] token in walkieClient.setPushToken(token) }
        ptt.onIncomingSpeaker = { [walkieClient] speaker in
            walkieClient.wakeForIncoming(speaker: speaker)
        }
        ptt.onBeginTransmitting = { [walkieClient] systemInitiated in
            walkieClient.systemDidBeginTransmitting(systemInitiated: systemInitiated)
        }
        ptt.onEndTransmitting = { [walkieClient] in walkieClient.systemDidEndTransmitting() }
        ptt.onAudioSessionChanged = { [walkieClient] active in
            walkieClient.systemAudioSessionChanged(active: active)
        }
        ptt.onTransmitFailure = { [walkieClient] message in
            walkieClient.systemTransmitFailed(message)
        }
        walkieCapability.installationChanged = { [weak ptt] installed, room in
            ptt?.setEnabled(installed, room: room)
        }
        walkieCapability.roomChanged = { [weak ptt] room in ptt?.updateRoom(room) }
        ptt.start(restoringEnabled: walkieClient.currentSnapshot().installed)
    }

    /// 没拿到系统 PTT 的会话:撤销自己的推送注册。
    func revokeSystemPushToken() {
        walkieClient.setPushToken(Data())
    }
    #endif

    /// 链路又回来了。
    func reattach() {
        DispatchQueue.main.async {
            self.deviceConfigModel.applyLinkChange(connected: true, name: self.deviceName)
            self.remoteAppsModel.isConnected = true
            self.appStoreModel.isConnected = true
        }
        remoteHost.setDeviceLinked(true)
    }
}

/// 界面正在看哪一台。
///
/// ⚠ 它必须是 `ObservableObject` 上的 `@Published`,不能留在 BLERelay 里:
/// `RootView` 拿到的 `AppCore` 不是 ObservableObject,点设备条界面根本不会
/// 重画。而且 macOS 以后要做成每台一个窗口的话,一个全局值必然互相打架。
final class SessionRouter: ObservableObject {
    @Published var selectedID: UUID?
    @Published private(set) var sessions: [UUID: DeviceSession] = [:]

    var selected: DeviceSession? { selectedID.flatMap { sessions[$0] } }

    /// 按名字排序,界面上顺序稳定 —— 用字典的遍历顺序会让设备条每次刷新
    /// 都换一个排法。
    var ordered: [DeviceSession] {
        sessions.values.sorted { $0.deviceName < $1.deviceName }
    }

    func put(_ session: DeviceSession) {
        sessions[session.deviceID] = session
        if selectedID == nil || sessions[selectedID!] == nil {
            selectedID = session.deviceID
        }
    }

    func remove(_ id: UUID) {
        sessions.removeValue(forKey: id)
        if selectedID == id { selectedID = ordered.first?.deviceID }
    }
}
