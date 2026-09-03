import Foundation

// =====================================================================
// FoloCodexRelay —— 接线层
//
// 从 main.swift 搬过来的。原来这些是文件顶层的语句,而 Swift 只允许名为
// main.swift 的文件写顶层语句,那个文件又跟 `@main` 互斥 —— 也就是说,
// 只要接线还留在 main.swift 里,这个 app 就没法变成 SwiftUI 的
// `@main App`,也就没法在 iOS 上启动。所以搬进一个显式单例。
//
// ⚠ 这一层**只做分发**。所有跟"某一台设备"有关的状态都在 DeviceSession
// 里,每台一份。留在这里的只有三类:一条 BLE 无线电(CBCentralManager 的
// restore identifier 必须全进程唯一)、设备名册和"界面在看哪一台",以及
// 系统里天生只有一份的资源(iOS 系统 PTT、本地通知调度、吃饭服务的连接)。
// =====================================================================

/// 进程级的接线。`shared` 第一次被取用时完成全部构造与启动,只跑一次。
final class AppCore {
    static let shared = AppCore()

    let relay: BLERelay
    let devicesModel = DevicesModel()
    /// 界面正在看哪一台,以及每台自己的那一套模型。
    let router = SessionRouter()

    /// 吃饭是纯读 + 本地提醒:服务端不按 client 解复用,提醒也是弹给
    /// **一个人**看的,不该因为他手里有三台设备就收三条。全局一份。
    private let mealClient: MealClient
    /// 饭点提醒:UNUserNotificationCenter 是进程唯一的,通知标识符也没有设备
    /// 区分。每台各起一个调度器的话,后一个 update 会把前一个排好的全删掉。
    private let mealNotifications = MealNotificationScheduler()
    private let sharedServices: SharedServices

    #if os(iOS)
    /// 系统级 PTT 是真正的独占资源:PTChannelManager 一个 app 只有一个
    /// activeChannelUUID,AVAudioSession 是进程级的。给第二个会话再 join
    /// 会把第一个挤掉,而且会连带撤销它在服务器上的推送注册 —— 切一次设备
    /// 就把另一台永久弄哑,还没有任何提示。所以它归**一个**会话所有。
    private let systemPushToTalk: SystemPushToTalk
    private var pttOwnerID: UUID?
    #endif

    private init() {
        log("========================================")
        log("FoloCodexRelay 启动中 (每台设备一个独立会话)...")

        relay = BLERelay()
        mealClient = MealClient()
        sharedServices = SharedServices(relay: relay, mealClient: mealClient,
                                        mealNotifications: mealNotifications)

        #if os(iOS)
        // 房间名由持有它的那个会话接管;这里先用默认值把频道立起来。
        systemPushToTalk = SystemPushToTalk(room: "local")
        #endif

        // ---- 设备上下线:建 / 拆会话 ----
        //
        // ⚠ 用这两条专门的事件,不要去 diff onDevicesChanged 的列表:
        // 那个发布是限流的(publishDevices 有 1 秒节流),diff 会漏。
        relay.onDeviceAttached = { [weak self] id in
            DispatchQueue.main.async { self?.attach(id) }
        }
        relay.onDeviceDetached = { [weak self] id in
            DispatchQueue.main.async { self?.detach(id) }
        }

        // ---- 事件分发:每一条都已经带着设备标识 ----
        //
        // 以前这些回调没有设备参数,上层无从知道是哪台发来的,只能靠 relay
        // 里一个"活跃设备"过滤 —— 而那个过滤正是第二台设备的事件全被吃掉
        // 的原因。
        relay.onRemoteEvent = { [weak self] id, evt, a, b in
            DispatchQueue.main.async { self?.session(id)?.handleRemoteEvent(evt, a, b) }
        }
        relay.onAudioChunk = { [weak self] id, flags, payload in
            DispatchQueue.main.async {
                self?.session(id)?.handleAudioChunk(flags: flags, payload: payload)
            }
        }
        relay.onWalkieAudioFrame = { [weak self] id, frame in
            DispatchQueue.main.async { self?.session(id)?.handleWalkieAudio(frame) }
        }
        relay.onWalkieStatus = { [weak self] id, event, code in
            DispatchQueue.main.async { self?.session(id)?.handleWalkieStatus(event, code: code) }
        }
        relay.onWalkieLinkChange = { [weak self] id, connected in
            DispatchQueue.main.async { self?.session(id)?.setWalkieLinked(connected) }
        }
        relay.onAppStoreCmdRequest = { [weak self] id, req, a, b in
            DispatchQueue.main.async { self?.session(id)?.handleAppStoreRequest(req: req, a: a, b: b) }
        }
        relay.onDeviceStatus = { [weak self] id, pairs in
            DispatchQueue.main.async { self?.session(id)?.handleDeviceStatus(pairs) }
        }
        relay.onLinkChange = { [weak self] id, connected, _ in
            DispatchQueue.main.async {
                guard let session = self?.router.sessions[id] else { return }
                if connected { session.reattach() } else { session.detach() }
            }
        }

        // ---- 设备名册 ----
        devicesModel.onSelect = { [weak self] id in
            guard let self else { return }
            self.router.selectedID = id
            self.relay.showDevice(id)
        }
        relay.onDevicesChanged = { [devicesModel] list in
            DispatchQueue.main.async { devicesModel.devices = list }
        }

        // 启动时拉一遍应用清单。
        //
        // 拉的是**数据**,不是代码 —— iOS 禁止下载并执行代码,而应用的屏幕
        // 和按键绑定本来就可以是数据(见 Framework/Manifest/)。
        //
        // 尽力而为:拉不到、校验不过、解析不了都退回缓存或内置版本。一次
        // 断网不该让所有应用消失。也**不阻塞启动** —— BLE 该扫就扫,清单
        // 落地之后下一台设备连上就用新的。
        AppRegistry.refresh()

        relay.start()

        log("FoloCodexRelay 已启动:等待 \(BLERelay.namePrefix)* 连接(可同时连多台,每台一个独立会话)")
    }

    /// **主线程调用。**
    private func session(_ id: UUID) -> DeviceSession? {
        router.sessions[id]
    }

    private func attach(_ id: UUID) {
        if let existing = router.sessions[id] {
            // 掉线重连:会话留着,浏览位置和身份都还在,不用从首屏重来。
            existing.reattach()
            return
        }
        let name = devicesModel.devices.first { $0.id == id }?.name ?? BLERelay.namePrefix
        // 调试通道(/tmp/folo_remote_sim)只给第一个会话 —— 它是自递归轮询
        // 且没有取消路径,每台各开一条会攒出一堆定时器抢同一个文件。
        let session = DeviceSession(deviceID: id, deviceName: name, shared: sharedServices,
                                    enableDebugChannel: router.sessions.isEmpty)
        router.put(session)
        if relay.displayedID == nil { relay.displayedID = id }
        log("[session] 为 \(name) 建立独立会话(共 \(router.sessions.count) 个)")

        #if os(iOS)
        // 系统 PTT 归第一个建立的会话。跟着界面选中跑的话,每切一次设备就
        // leave/join 一次频道:系统横幅闪、锁屏发话按钮短暂消失、推送 token
        // 被注销再注册 —— 而 PTT 的全部价值就在锁屏后台唤醒的稳定性上,
        // 不能跟着"用户在看哪一页"跑。
        if pttOwnerID == nil {
            pttOwnerID = id
            session.bindSystemPushToTalk(systemPushToTalk)
            log("[ptt] 系统级对讲归 \(name);其它设备在 app 退到后台后收不到来话")
        }
        #endif
    }

    private func detach(_ id: UUID) {
        let name = router.sessions[id]?.deviceName ?? "设备"
        router.sessions[id]?.detach()
        // 会话对象**不删** —— BLE 掉线在这个项目里是常态(有自动重连和
        // 看门狗),删掉的话每次重连都从首屏重来,而且对讲身份也会重置。
        log("[session] \(name) 链路断开,会话保留等待重连")
    }
}
