import Foundation

// =====================================================================
// FoloCodexRelay —— 接线层
//
// 从 main.swift 搬过来的。原来这些是文件顶层的语句,而 Swift 只允许名为
// main.swift 的文件写顶层语句,那个文件又跟 `@main` 互斥 —— 也就是说,
// 只要接线还留在 main.swift 里,这个 app 就没法变成 SwiftUI 的
// `@main App`,也就没法在 iOS 上启动。所以搬进一个显式单例。
//
// 这里是整个工程**唯一**一处 `#if os(macOS)`。这不是巧合,是设计:
// 能共享到哪一层由操作系统能力决定,而这个 app 里只有一件事是 iOS 真的
// 做不到的 —— 起子进程跑 `codex exec` 并读 ~/.codex/sessions。BLE、语音
// 识别、ADPCM、全部应用逻辑、全部界面都是三端通用的。
// =====================================================================

/// 进程级的接线。`shared` 第一次被取用时完成全部构造与启动,只跑一次。
final class AppCore {
    static let shared = AppCore()

    let relay: BLERelay
    let remoteHost: RemoteAppHost
    let remoteAppsModel: RemoteAppsModel
    let appStoreModel: AppStoreModel
    let deviceConfigModel: DeviceConfigModel
    let walkieApp: WalkieTalkieApp
    private let walkieClient: WalkieClient
    private let voicePipeline: VoiceInputPipeline

    #if os(macOS)
    /// Codex 的浏览后端。要 fork/exec 跑 `codex exec`、要读
    /// ~/.codex/sessions —— iOS 内核禁止前者,沙盒里没有后者。
    private let codexBrowser: CodexBrowserModel
    #endif
    #if os(iOS)
    private let systemPushToTalk: SystemPushToTalk
    #endif

    private init() {
        log("========================================")
        log("FoloCodexRelay 启动中 (协议 v2: 工作区/会话/分页浏览器)...")

        relay = BLERelay()
        walkieClient = WalkieClient()
        walkieApp = WalkieTalkieApp(client: walkieClient)
        #if os(iOS)
        systemPushToTalk = SystemPushToTalk(room: walkieApp.room)
        #endif

        // CodexBrowserModel 的输出**不再**走旧的 Codex GATT 通道。
        //
        // 那条通道对应的设备端界面(demo_codex.c 的阅读/列表页)在架构转向
        // 之后已经没有任何入口能进去了 —— 继续往那边推,是把数据发给一个
        // 不会显示它的地方。现在改由 CodexApp 接住,渲染成远程界面。旧
        // service 只保留 AUDIO 那一条:语音是设备 → 这边的流,那个方向依然
        // 活着而且不可替代。
        var codexAppSink: ((UInt8, UInt16, UInt16, String) -> Void)?

        voicePipeline = VoiceInputPipeline()

        #if os(macOS)
        let browser = CodexBrowserModel(sender: { kind, index, total, text in
            codexAppSink?(kind, index, total, text)
        })
        codexBrowser = browser
        voicePipeline.sessionContextProvider = { completion in
            browser.currentSessionContext(completion: completion)
        }
        voicePipeline.onSendFailure = { reason in
            browser.reportVoiceError(reason)
        }
        // 转写好的文字往哪儿送 —— macOS 独有的那一步。VoiceInputPipeline
        // 本身不认识 HeadlessCodexSender(它要 fork/exec),由入口注入。
        let pipeline = voicePipeline
        voicePipeline.onTranscript = { text, threadId, model in
            HeadlessCodexSender.send(threadId: threadId, model: model, text: text,
                                     onFailure: pipeline.onSendFailure)
        }
        #endif

        relay.onAudioChunk = { [voicePipeline] flags, payload in
            voicePipeline.handleChunk(flags: flags, payload: payload)
        }
        relay.onWalkieAudioFrame = { [walkieClient] frame in
            walkieClient.handleDeviceAudio(frame)
        }
        relay.onWalkieStatus = { [walkieClient] event, code in
            walkieClient.handleDeviceStatus(event, code: code)
        }
        relay.onWalkieLinkChange = { [walkieClient] connected in
            walkieClient.setDeviceConnected(connected)
        }
        walkieClient.sendDeviceControl = { [relay] operation, stream in
            relay.sendWalkieControl(operation: operation, stream: stream)
        }
        walkieClient.sendDeviceAudio = { [relay] frame in
            relay.sendWalkieAudio(frame)
        }

        #if os(iOS)
        walkieClient.systemPTTAvailable = { [systemPushToTalk] in systemPushToTalk.isReady }
        walkieClient.requestSystemTransmit = { [systemPushToTalk] in
            systemPushToTalk.beginTransmitting()
        }
        walkieClient.stopSystemTransmit = { [systemPushToTalk] in
            systemPushToTalk.stopTransmitting()
        }
        walkieClient.onRemoteSpeakerChanged = { [systemPushToTalk] speaker in
            systemPushToTalk.setRemoteSpeaker(speaker)
        }
        systemPushToTalk.onPushToken = { [walkieClient] token in
            walkieClient.setPushToken(token)
        }
        systemPushToTalk.onIncomingSpeaker = { [walkieClient] speaker in
            walkieClient.wakeForIncoming(speaker: speaker)
        }
        systemPushToTalk.onBeginTransmitting = { [walkieClient] systemInitiated in
            walkieClient.systemDidBeginTransmitting(systemInitiated: systemInitiated)
        }
        systemPushToTalk.onEndTransmitting = { [walkieClient] in
            walkieClient.systemDidEndTransmitting()
        }
        systemPushToTalk.onAudioSessionChanged = { [walkieClient] active in
            walkieClient.systemAudioSessionChanged(active: active)
        }
        systemPushToTalk.onTransmitFailure = { [walkieClient] message in
            walkieClient.systemTransmitFailed(message)
        }
        walkieApp.installationChanged = { [systemPushToTalk] installed, room in
            systemPushToTalk.setEnabled(installed, room: room)
        }
        walkieApp.roomChanged = { [systemPushToTalk] room in
            systemPushToTalk.updateRoom(room)
        }
        systemPushToTalk.start(restoringEnabled: walkieClient.currentSnapshot().installed)
        #endif

        appStoreModel = AppStoreModel(
            sender: { [relay] kind, index, total, payload in
                relay.enqueueAppStore(kind: kind, index: index, total: total, payload: payload)
            },
            maxPayloadSize: { [relay] in
                relay.appStoreMaxPayloadSize()
            },
            cancelTransfer: { [relay] in
                relay.cancelAppStoreTransfer()
            },
            sendBatch: { [relay] chunks, completion in
                relay.sendAppStoreBatch(withoutResponse: chunks, completion: completion)
            }
        )
        relay.onAppStoreCmdRequest = { [appStoreModel] req, a, b in
            appStoreModel.handleRequest(req: req, a: a, b: b)
        }

        // 远程应用:设备是显示终端,这里是全部应用逻辑。加一个应用 =
        // register 一行,设备侧不用改任何东西、也不用重刷固件。
        remoteHost = RemoteAppHost(
            send: { [relay] text in relay.sendRemoteScreen(text) },
            sendManifest: { [relay] text in relay.sendRemoteManifest(text) },
            // 通知走 cmd.notify —— 现成的非持久化命令通道(device_config.c:139
            // 把 cmd.* 前缀转给 main.c 的 on_config_cmd,不落盘、也不要求
            // NVS 打开)。不为通知新开特征值,也不动屏幕协议:屏幕协议表达的是
            // "前台应用长什么样",而通知恰恰要在别的应用占着前台时也能到达。
            sendNotify: { [relay] text in
                relay.sendDeviceConfig([("cmd.notify", text)]) { ok in
                    if !ok { log("[notify] 下发失败") }
                }
            }
        )
        // ⚠ 观察者必须在 register() **之前**装好。register() 的函数体跑在
        // host 的串行队列上并会发布一次列表,晚装的话那几次发布全部丢给
        // nil —— 而列表只在 register / 装卸时发布,错过就再没有第二次机会,
        // 「应用」标签页会永远显示"还没有可用的应用"。setListObserver 内部
        // 也会补发一次当前状态。
        remoteAppsModel = RemoteAppsModel(host: remoteHost)

        remoteHost.register(walkieApp)

        // Codex:macOS 上接真后端,别的平台注入 nil。
        //
        // 注入 nil 不等于"这个应用消失了" —— 它照常出现在列表和设备首屏,
        // 点进去会看到一屏说明。这是刻意的:用户在 Mac 上见过 Codex,到
        // iPhone 上它凭空消失只会被当成 bug,而点进去一片空白更糟。
        #if os(macOS)
        let codexApp = CodexApp(browser: codexBrowser)
        #else
        let codexApp = CodexApp(
            browser: nil,
            unavailableReason: "Codex 需要在 Mac 上运行:它要启动 codex 命令行进程并读取本机的会话记录,iOS 两者都做不到。"
        )
        #endif
        codexAppSink = { [weak codexApp] kind, index, total, text in
            codexApp?.handleOutput(kind: kind, index: index, total: total, text: text)
        }
        remoteHost.register(codexApp)

        relay.onRemoteEvent = { [remoteHost] evt, a, b in
            switch evt {
            case 0: remoteHost.handleKey(a, b)          // 按键
            case 1: remoteHost.setDeviceActive(a == 1)  // 进/出远程界面
            case 2: remoteHost.deviceReady(active: a == 1, appIndex: b)
            case 3: remoteHost.openApp(a)               // 首屏选中第 a 项(0xFE = 应用商店)
            default: break
            }
        }

        deviceConfigModel = DeviceConfigModel(
            sender: { [relay] pairs, completion in relay.sendDeviceConfig(pairs, completion: completion) },
            bleDisconnect: { [relay] in relay.disconnectDevice() },
            bleRescan: { [relay] in relay.rescanDevice() }
        )
        // 连接状态和设备上报的状态都从 BLE 队列过来,而 @Published 只能在
        // 主线程改 —— SwiftUI 在别的线程收到变更会直接报运行时警告,严重时
        // 刷出错乱的界面。
        // ⚠ 三个页签都要接同一个连接状态,漏一个就会出现"同一秒里三页说三种话"。
        // 之前只有「配置」页接了,「应用」页照常显示"已安装"、「固件」页
        // 一直显示"等待设备连接" —— 而它们说的是同一件事。
        relay.onLinkChange = { [deviceConfigModel, remoteAppsModel, appStoreModel, remoteHost] connected, name in
            DispatchQueue.main.async {
                deviceConfigModel.applyLinkChange(connected: connected, name: name)
                // 「应用」页:没连上时不该显示任何设备状态,因为那份"已安装"
                // 只是本机的记录,问不到设备就无法证实。
                remoteAppsModel.isConnected = connected
                // 「固件」页:没连上时不该让人点安装。
                appStoreModel.isConnected = connected
                // 通知在没连设备时直接丢弃(不排队),host 需要知道当前连没连。
                remoteHost.setDeviceLinked(connected)
            }
        }
        relay.onDeviceStatus = { [deviceConfigModel] pairs in
            DispatchQueue.main.async {
                deviceConfigModel.applyDeviceStatus(pairs)
            }
        }

        relay.start()
        #if os(macOS)
        codexBrowser.start()
        voicePipeline.start()
        #endif

        log("FoloCodexRelay 已启动: 等待 \(BLERelay.targetName) 连接及 CMD 请求 (workspace/session/page 浏览协议 v2 + 语音输入 + 应用商店)")
    }
}
