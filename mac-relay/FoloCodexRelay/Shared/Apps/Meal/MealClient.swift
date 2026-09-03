import Foundation

final class MealClient {
    private static let appName = "吃饭"

    private struct Config: Decodable {
        let server: String
    }

    private let queue = DispatchQueue(label: "com.folotoy.codexrelay.meal")
    private let defaults: UserDefaults

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var reconnectWork: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var snapshot = MealSnapshot()
    private var serverAddress: String
    private var clientID: String

    /// ⚠ 多播,不是单槽。
    ///
    /// 每台设备有自己的 MealApp 实例,而 MealClient 是全局一份(它是纯读 +
    /// 本地提醒,服务端也不按 client 解复用)。写成 `var onSnapshot = {…}`
    /// 的话,第二个 MealApp 的 init 会**静默覆盖**第一个:第一台的吃饭页
    /// 从此永不更新、也不再触发提醒,屏幕定格在最后一屏,没有任何报错。
    private var snapshotObservers: [(MealSnapshot) -> Void] = []
    private var reminderObservers: [(MealReminder) -> Void] = []

    func addSnapshotObserver(_ handler: @escaping (MealSnapshot) -> Void) {
        snapshotObservers.append(handler)
    }
    func addReminderObserver(_ handler: @escaping (MealReminder) -> Void) {
        reminderObservers.append(handler)
    }
    private func onSnapshotFanout(_ v: MealSnapshot) { snapshotObservers.forEach { $0(v) } }
    private func onReminderFanout(_ v: MealReminder) { reminderObservers.forEach { $0(v) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let fallbackServer = Self.configuredServer(defaults: defaults)
        serverAddress = defaults.string(forKey: "meal.server") ?? fallbackServer
        if let stored = defaults.string(forKey: "meal.client-id"), !stored.isEmpty {
            clientID = stored
        } else {
            clientID = UUID().uuidString.lowercased()
            defaults.set(clientID, forKey: "meal.client-id")
        }
        // 这里以前从全局裸键 `remote.installed` 读一次"装没装"。那个键现在
        // 是每台一份的(`remote.installed.<设备UUID>`),裸键读到的是"谁也不是"
        // 的一份合并值。不用读了 —— 每台的 RemoteAppHost.register() 会在会话
        // 建立时立刻用那一台自己的清单调 setInstalled(_:for:)。
        snapshot.status = "尚未启用"
    }

    func currentConfiguration() -> String {
        queue.sync { serverAddress }
    }

    /// 测试用:等自己那条串行队列上已排队的活干完。
    /// setInstalled 是 async 的,不等的话断言会跑在它前面。
    func waitForPendingWork() { queue.sync { } }

    func currentSnapshot() -> MealSnapshot {
        queue.sync { snapshot }
    }

    func configure(server: String) {
        queue.async {
            self.serverAddress = server.trimmingCharacters(in: .whitespacesAndNewlines)
            self.defaults.set(self.serverAddress, forKey: "meal.server")
            self.disconnectLocked(reconnect: false)
            if self.snapshot.installed {
                self.connectLocked()
            }
        }
    }

    /// 哪几台设备装了「吃饭」。
    ///
    /// ⚠ 必须是**集合**,不能是一个布尔。这个客户端是全局一份(菜单是同一个
    /// 食堂的、服务端不按 client 解复用、提醒也只该弹给人一次),但"装没装"
    /// 是**每台设备**的事。写成一个布尔的时候:A 装了吃饭正用着,把没装吃饭
    /// 的 B 插上电 —— 会话建立时 register() 会拿 B 自己的清单调
    /// setInstalled(false),连接当场被关掉,A 的屏幕跳成"请先安装应用",
    /// 这台电脑上排好的饭点提醒也被一并清空。用户对 A 什么都没做。
    private var installedDevices: Set<String> = []

    func setInstalled(_ installed: Bool, for deviceKey: String) {
        queue.async {
            let before = !self.installedDevices.isEmpty
            if installed {
                self.installedDevices.insert(deviceKey)
            } else {
                self.installedDevices.remove(deviceKey)
            }
            let after = !self.installedDevices.isEmpty
            guard before != after else {
                // 还有别的设备装着,连接照旧 —— 只是补一次断线重连。
                if after && self.socket == nil { self.connectLocked() }
                return
            }
            self.snapshot.installed = after
            self.snapshot.status = after ? "正在连接…" : "尚未启用"
            self.publish()
            if after {
                self.connectLocked()
            } else {
                // 最后一台也卸了才真的断。
                self.send(MealClientMessage(type: "subscribe", installed: false))
                self.disconnectLocked(reconnect: false)
            }
        }
    }

    func reconnect() {
        queue.async {
            guard self.snapshot.installed else { return }
            self.disconnectLocked(reconnect: false)
            self.connectLocked()
        }
    }

    private func connectLocked() {
        guard snapshot.installed, socket == nil else { return }
        guard let url = Self.mealEndpoint(from: serverAddress) else {
            snapshot.status = "服务地址无效"
            publish()
            return
        }

        generation &+= 1
        let myGeneration = generation
        let session = URLSession(configuration: .default)
        let socket = session.webSocketTask(with: url)
        self.session = session
        self.socket = socket
        snapshot.connected = false
        snapshot.status = "正在连接…"
        publish()
        socket.resume()
        receiveNext(socket, generation: myGeneration)
        schedulePing(socket, generation: myGeneration)
        send(MealClientMessage(type: "join", clientId: clientID, installed: true))
    }

    private func receiveNext(_ task: URLSessionWebSocketTask, generation: UInt64) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            self.queue.async {
                guard generation == self.generation, task === self.socket else { return }
                switch result {
                case .failure(let error):
                    self.connectionFailedLocked(error.localizedDescription)
                case .success(let message):
                    self.handleMessageLocked(message)
                    self.receiveNext(task, generation: generation)
                }
            }
        }
    }

    private func handleMessageLocked(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(MealServerEvent.self, from: data) else {
            return
        }
        switch event.type {
        case "meal_state":
            snapshot.connected = true
            snapshot.weeks = event.weeks ?? []
            snapshot.status = snapshot.weeks.isEmpty ? "等待本周菜单" : "菜单已更新"
            publish()
        case "meal_reminder":
            if let reminder = event.reminder {
                onReminderFanout(reminder)
            }
        case "pong":
            break
        case "error":
            snapshot.status = event.message ?? "服务返回错误"
            publish()
        default:
            break
        }
    }

    private func schedulePing(_ task: URLSessionWebSocketTask, generation: UInt64) {
        queue.asyncAfter(deadline: .now() + 25) { [weak self, weak task] in
            guard let self, let task, task === self.socket,
                  generation == self.generation else { return }
            task.sendPing { [weak self] error in
                self?.queue.async {
                    guard let self, generation == self.generation else { return }
                    if let error {
                        self.connectionFailedLocked(error.localizedDescription)
                    } else {
                        self.schedulePing(task, generation: generation)
                    }
                }
            }
        }
    }

    private func send(_ message: MealClientMessage) {
        guard let socket, let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let error else { return }
            self?.queue.async { self?.connectionFailedLocked(error.localizedDescription) }
        }
    }

    private func connectionFailedLocked(_ message: String) {
        guard socket != nil else { return }
        disconnectLocked(reconnect: snapshot.installed)
        snapshot.connected = false
        snapshot.status = "连接已断开"
        publish()
        log("[meal] \(message)")
    }

    private func disconnectLocked(reconnect: Bool) {
        generation &+= 1
        reconnectWork?.cancel()
        reconnectWork = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        snapshot.connected = false
        if reconnect, snapshot.installed {
            let work = DispatchWorkItem { [weak self] in
                self?.queue.async { self?.connectLocked() }
            }
            reconnectWork = work
            queue.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func publish() {
        let value = snapshot
        DispatchQueue.main.async { [weak self] in
            self?.onSnapshotFanout(value)
        }
    }

    static func mealEndpoint(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed) else { return nil }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        components.path = "/v1/meals/ws"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// 配置文件名。跟应用 id 一致。
    static let configID = "meal"

    private static func configuredServer(defaults: UserDefaults) -> String {
        if let config = AppConfigStore.load(Config.self, for: configID),
           let url = mealEndpoint(from: config.server) {
            return url.absoluteString
        }
        if let url = Bundle.main.url(forResource: "meal", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let config = try? JSONDecoder().decode(Config.self, from: data),
           let endpoint = mealEndpoint(from: config.server) {
            return endpoint.absoluteString
        }
        let walkieServer = defaults.string(forKey: "walkie.server") ?? ""
        if let endpoint = mealEndpoint(from: walkieServer) {
            return endpoint.absoluteString
        }
        #if os(macOS)
        return "ws://127.0.0.1:8787/v1/meals/ws"
        #else
        return ""
        #endif
    }
}
