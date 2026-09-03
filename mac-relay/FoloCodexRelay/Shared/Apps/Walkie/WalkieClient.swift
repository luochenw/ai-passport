import Foundation
import Security

final class WalkieClient {
    typealias SnapshotHandler = (WalkieSnapshot) -> Void
    private static let remoteInstalledKey = "remote.installed"
    private static let appName = "对讲机"
    private typealias SocketOutbound = (
        message: URLSessionWebSocketTask.Message,
        completion: (() -> Void)?
    )

    private let queue = DispatchQueue(label: "com.folotoy.codexrelay.walkie")
    private let defaults: UserDefaults
    /// 这个客户端属于哪一台设备。只用来给 UserDefaults 的键加后缀。
    private let deviceKey: String
    /// 这一台的口令在钥匙串里的账号名。
    private let tokenAccount: String

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var socketOutbox: [SocketOutbound] = []
    private var socketWriteInFlight = false
    private var reconnectWork: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var lastSocketActivity = Date.distantPast
    private var socketProbeInFlight = false
    private var snapshot = WalkieSnapshot()

    private var serverAddress: String
    private var room: String
    private var displayName: String
    /// 服务端在 welcome 里分配给自己的 id。判断「在讲话的是不是我」只能靠它。
    private var myClientId = ""
    private var sharedToken: String
    private var clientID: String
    private var pushToken = ""

    private var talkButtonHeld = false
    private var pendingStream: UInt16?
    private var activeStream: UInt16?
    private var nextStream: UInt16 = UInt16.random(in: 1...UInt16.max)
    private var systemTransmitStarted = false
    private var systemAudioSessionActive = false
    private var receiveTimeout: DispatchWorkItem?
    private var receiveGeneration: UInt64 = 0
    private var remoteStream: UInt16?
    private var deviceAudioQueue = WalkieRealtimeQueue(limit: 250)
    private var deviceAudioPumpScheduled = false

    var onSnapshot: SnapshotHandler?
    var sendDeviceControl: ((_ operation: UInt8, _ stream: UInt16) -> Void)?
    var sendDeviceAudio: ((Data) -> Void)?
    var systemPTTAvailable: (() -> Bool)?
    var requestSystemTransmit: (() -> Void)?
    var stopSystemTransmit: (() -> Void)?
    var onRemoteSpeakerChanged: ((String?) -> Void)?
    var onInstalledChanged: ((Bool, String) -> Void)?
    var onRoomChanged: ((String) -> Void)?

    /// `deviceKey` 把身份按设备隔开。
    ///
    /// ⚠ 这不是可选的优化,是**不隔开就完全跑不起来**:服务端在同一房间里
    /// 按 clientId 顶号(`services/walkie-server/main.go:296-308`,旧连接被
    /// 关掉并附言 "replaced by restored connection"),而客户端两秒后重连又把
    /// 对方踢掉 —— 两台设备会每两秒互踢一次,谁按住说话都会在几秒内掉线。
    ///
    /// 服务器/房间/口令**不**按设备分:口令是房间口令(`main.go:286` 只在
    /// join 时比一次,所有客户端用同一个),按设备拆的话用户每选一台设备
    /// 就得重填一次。昵称按设备分,否则房间名单里两行一模一样。
    init(deviceKey: String, defaultName: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.deviceKey = deviceKey
        #if os(macOS)
        let defaultServer = "ws://127.0.0.1:8787/v1/ws"
        #else
        let defaultServer = ""
        #endif
        serverAddress = defaults.string(forKey: "walkie.server." + deviceKey)
            ?? defaults.string(forKey: "walkie.server") ?? defaultServer
        room = defaults.string(forKey: "walkie.room." + deviceKey)
            ?? defaults.string(forKey: "walkie.room") ?? "local"
        // ⚠ 服务器地址 / 房间 / 口令 / 昵称**每台一份**。
        //
        // 它们描述的是"这一台设备接到哪儿、在哪个房间、叫什么" —— 是设备的
        // 属性,不是这台电脑的。共用一份的话,把 A 换到另一个房间,B 会跟着
        // 一起搬走,而用户以为自己只动了 A。
        //
        // 新设备从"上次保存的那份"播种(下面 configure 里会同步写回全局键),
        // 所以插上第三台不用把服务器地址和口令重敲一遍。
        let tokenAccount = Self.legacyTokenAccount + "." + deviceKey
        self.tokenAccount = tokenAccount
        displayName = defaults.string(forKey: "walkie.name." + deviceKey) ?? defaultName
        var token = Self.loadToken(account: tokenAccount)
        if token.isEmpty {
            token = Self.loadToken(account: Self.legacyTokenAccount)
            if !token.isEmpty { Self.storeToken(token, account: tokenAccount) }
        }
        sharedToken = token
        let clientIDKey = "walkie.client-id." + deviceKey
        if let stored = defaults.string(forKey: clientIDKey), !stored.isEmpty {
            clientID = stored
        } else {
            clientID = UUID().uuidString.lowercased()
            defaults.set(clientID, forKey: clientIDKey)
        }
        // 迁移:把历史版本留在 UserDefaults 里的明文口令搬进钥匙串再删掉。
        // 不做的话,那份明文会一直躺在 plist 里,修了也白修。
        if let legacy = defaults.string(forKey: "walkie.token"), !legacy.isEmpty {
            if sharedToken.isEmpty { sharedToken = legacy; Self.storeToken(legacy, account: tokenAccount) }
            defaults.removeObject(forKey: "walkie.token")
            log("[walkie] 已把旧的明文口令迁进钥匙串并从 UserDefaults 删除")
        }
        snapshot.room = room
        snapshot.installed = (defaults.stringArray(forKey: Self.remoteInstalledKey) ?? [])
            .contains(Self.appName)
        snapshot.status = snapshot.installed ? "正在连接…" : "尚未启用"
    }

    /// 这台设备在对讲服务器上的身份。同一房间里必须唯一 —— 服务端按它顶号。
    func currentClientID() -> String { queue.sync { clientID } }

    func currentConfiguration() -> (server: String, room: String, name: String, token: String) {
        queue.sync { (serverAddress, room, displayName, sharedToken) }
    }

    func currentSnapshot() -> WalkieSnapshot {
        queue.sync { snapshot }
    }

    // MARK: 共享口令的存放
    //
    // 走钥匙串,**不进 UserDefaults**。UserDefaults 背后就是
    // ~/Library/Preferences/<bundle id>.plist,任何以这个用户身份跑的进程
    // 一条 `defaults read` 就能把口令原文打印出来;Time Machine 和 iPhone
    // 未加密的本地备份里也是明文。同一个仓库对 Wi-Fi 密码的处理写在
    // DeviceConfig.swift 里:只放内存、不写 UserDefaults、不进日志。
    //
    // 拿到这个口令的人可以用任意客户端加入同一个房间 —— 既能听到设备那头
    // 推上来的实时音频,也能抢话权从设备喇叭里放声音,而设备屏幕上只会显示
    // 「某某 正在讲话」,看不出是外人。
    //
    // 钥匙串不可用时**退回只放内存**(下次启动要重填),绝不落 UserDefaults。
    /// 服务端的英文错误码直接上设备屏是没用的 —— 屏幕上蹦出一个
    /// "unauthorized",用户不知道该去改哪一项设置。
    private static func friendlyError(_ raw: String?) -> String {
        switch (raw ?? "").lowercased() {
        case "unauthorized":     return "共享口令不对"
        case "room required":    return "房间名不能为空"
        case "name required":    return "昵称不能为空"
        case let m where m.isEmpty: return "服务返回错误"
        default:                 return raw ?? "服务返回错误"
        }
    }

    private static let tokenService = "com.folotoy.codexrelay.walkie"
    /// 单设备时代的账号。每台设备自己的账号是 `shared-token.<设备key>`;
    /// 第一次用某台设备时从这里播种,老用户不用重新输一遍口令。
    private static let legacyTokenAccount = "shared-token"

    private static func storeToken(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        // ThisDeviceOnly:不进 iCloud 钥匙串、也不会被备份带到别的设备上。
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let rc = SecItemAdd(add as CFDictionary, nil)
        // ⚠ 只记状态码,绝不记值。
        if rc != errSecSuccess { log("[walkie] 口令写入钥匙串失败 status=\(rc)") }
    }

    private static func loadToken(account: String) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    func configure(server: String, room: String, name: String, token: String) {
        queue.async {
            self.serverAddress = server.trimmingCharacters(in: .whitespacesAndNewlines)
            self.room = room.trimmingCharacters(in: .whitespacesAndNewlines)
            self.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.sharedToken = token
            // 每台自己那份 —— 改 A 不会动 B。
            self.defaults.set(self.serverAddress, forKey: "walkie.server." + self.deviceKey)
            self.defaults.set(self.room, forKey: "walkie.room." + self.deviceKey)
            self.defaults.set(self.displayName, forKey: "walkie.name." + self.deviceKey)
            Self.storeToken(self.sharedToken, account: self.tokenAccount)
            // 同时更新"新设备的默认值"。昵称不写:昵称必须每台不同,拿它当
            // 默认值会让下一台一上来就跟这台重名。
            self.defaults.set(self.serverAddress, forKey: "walkie.server")
            self.defaults.set(self.room, forKey: "walkie.room")
            Self.storeToken(self.sharedToken, account: Self.legacyTokenAccount)
            self.snapshot.room = self.room
            self.publish()
            self.onRoomChanged?(self.room)
            if self.snapshot.installed {
                self.disconnectLocked(reconnect: false)
                self.connectLocked()
            }
        }
    }

    func setInstalled(_ installed: Bool) {
        queue.async {
            let changed = self.snapshot.installed != installed
            self.snapshot.installed = installed
            if !changed {
                if installed && self.socket == nil {
                    self.connectLocked()
                }
                return
            }
            self.snapshot.status = installed ? "正在连接…" : "尚未启用"
            self.publish()
            self.onInstalledChanged?(installed, self.room)
            if installed {
                self.connectLocked()
            } else {
                if self.snapshot.connected {
                    self.sendJSON(WalkieControlMessage(type: "push_token", pushToken: "")) {
                        self.disconnectLocked(reconnect: false)
                    }
                } else {
                    self.disconnectLocked(reconnect: false)
                }
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

    func setPushToken(_ data: Data) {
        let value = data.map { String(format: "%02x", $0) }.joined()
        queue.async {
            self.pushToken = value
            if self.snapshot.connected {
                self.sendJSON(WalkieControlMessage(type: "push_token", pushToken: value))
            }
        }
    }

    func setDeviceConnected(_ connected: Bool) {
        queue.async {
            self.snapshot.deviceConnected = connected
            if !connected {
                if let stream = self.activeStream ?? self.pendingStream {
                    self.sendJSON(WalkieControlMessage(type: "ptt_release", stream: stream))
                }
                self.talkButtonHeld = false
                self.systemTransmitStarted = false
                self.pendingStream = nil
                self.activeStream = nil
                self.snapshot.transmitting = false
                if self.systemPTTAvailable?() == true {
                    DispatchQueue.main.async { self.stopSystemTransmit?() }
                }
                if self.snapshot.connected {
                    self.snapshot.status = "Passport 未连接"
                }
            } else {
                self.pumpDeviceAudioLocked()
            }
            self.publish()
        }
    }

    func wakeForIncoming(speaker: String) {
        queue.async {
            self.snapshot.speaker = speaker
            self.snapshot.status = "\(speaker) 正在讲话"
            self.publish()
            self.armReceiveTimeoutLocked(stream: 0, after: 10)
            guard self.snapshot.installed else { return }
            guard let socket = self.socket else {
                self.connectLocked()
                return
            }

            // iOS may suspend the process while URLSession still exposes a
            // stale task. A PTT push is the point where the network path must
            // be live, so probe it immediately and reconnect on failure.
            let myGeneration = self.generation
            let probeStarted = Date()
            socket.sendPing { [weak self, weak socket] error in
                guard let self, let socket else { return }
                self.queue.async {
                    guard myGeneration == self.generation, socket === self.socket else { return }
                    if error != nil {
                        self.reconnectForIncomingLocked()
                    } else {
                        self.lastSocketActivity = Date()
                    }
                }
            }
            self.queue.asyncAfter(deadline: .now() + 1) {
                guard myGeneration == self.generation, socket === self.socket,
                      self.lastSocketActivity < probeStarted else { return }
                self.reconnectForIncomingLocked()
            }
        }
    }

    func beginTalk() {
        queue.async {
            self.talkButtonHeld = true
            guard self.snapshot.installed else {
                self.snapshot.status = "请先安装并启用对讲机"
                self.publish()
                return
            }
            guard self.snapshot.connected else {
                self.snapshot.status = "对讲服务未连接"
                self.publish()
                self.connectLocked()
                return
            }
            guard self.snapshot.deviceConnected else {
                self.snapshot.status = "Passport 未连接"
                self.publish()
                return
            }
            self.requestTransmitLocked()
        }
    }

    func endTalk() {
        queue.async {
            self.talkButtonHeld = false
            self.systemTransmitStarted = false
            if self.systemPTTAvailable?() == true {
                DispatchQueue.main.async { self.stopSystemTransmit?() }
            }
            self.stopDeviceTransmitLocked()
        }
    }

    func systemDidBeginTransmitting(systemInitiated: Bool = false) {
        queue.async {
            if systemInitiated {
                self.talkButtonHeld = true
            }
            self.systemTransmitStarted = true
            guard self.talkButtonHeld, self.snapshot.installed else {
                self.systemTransmitStarted = false
                DispatchQueue.main.async { self.stopSystemTransmit?() }
                return
            }
            guard self.snapshot.deviceConnected else {
                self.talkButtonHeld = false
                self.systemTransmitStarted = false
                self.snapshot.status = "Passport 未连接"
                self.publish()
                DispatchQueue.main.async { self.stopSystemTransmit?() }
                return
            }
            guard self.snapshot.connected else {
                self.snapshot.status = "正在恢复对讲连接…"
                self.publish()
                self.connectLocked()
                return
            }
            if self.systemAudioSessionActive {
                self.requestFloorWhenConnectionReadyLocked()
            } else {
                self.snapshot.status = "正在准备系统音频…"
                self.publish()
            }
        }
    }

    func systemAudioSessionChanged(active: Bool) {
        queue.async {
            self.systemAudioSessionActive = active
            if active {
                if self.systemTransmitStarted && self.talkButtonHeld &&
                    self.snapshot.connected && self.snapshot.deviceConnected {
                    self.requestFloorWhenConnectionReadyLocked()
                }
                self.pumpDeviceAudioLocked()
            }
        }
    }

    private func requestTransmitLocked() {
        guard snapshot.speaker == nil, pendingStream == nil, activeStream == nil else { return }
        if systemPTTAvailable?() == true {
            DispatchQueue.main.async { self.requestSystemTransmit?() }
        } else {
            requestFloorLocked()
        }
    }

    private func requestFloorLocked() {
        guard pendingStream == nil, activeStream == nil else { return }
        nextStream &+= 1
        if nextStream == 0 { nextStream = 1 }
        pendingStream = nextStream
        snapshot.status = "正在申请频道…"
        publish()
        sendJSON(WalkieControlMessage(type: "ptt_request", stream: nextStream))
    }

    private func requestFloorWhenConnectionReadyLocked() {
        guard systemTransmitStarted, talkButtonHeld, snapshot.deviceConnected else { return }
        guard snapshot.connected, let socket else {
            snapshot.status = "正在恢复对讲连接…"
            publish()
            if self.socket == nil {
                connectLocked()
            }
            return
        }
        guard Date().timeIntervalSince(lastSocketActivity) > 15 else {
            requestFloorLocked()
            return
        }
        guard !socketProbeInFlight else { return }

        socketProbeInFlight = true
        snapshot.status = "正在确认对讲连接…"
        publish()
        let myGeneration = generation
        socket.sendPing { [weak self, weak socket] error in
            guard let self, let socket else { return }
            self.queue.async {
                guard myGeneration == self.generation, socket === self.socket else { return }
                self.socketProbeInFlight = false
                if error != nil {
                    self.reconnectForTransmitLocked()
                } else {
                    self.lastSocketActivity = Date()
                    self.requestFloorLocked()
                }
            }
        }
        queue.asyncAfter(deadline: .now() + 1) { [weak self, weak socket] in
            guard let self, let socket, myGeneration == self.generation,
                  socket === self.socket, self.socketProbeInFlight else { return }
            self.socketProbeInFlight = false
            self.reconnectForTransmitLocked()
        }
    }

    private func reconnectForTransmitLocked() {
        disconnectLocked(reconnect: false, preserveTransmitIntent: true)
        connectLocked()
    }

    private func reconnectForIncomingLocked() {
        disconnectLocked(reconnect: false, preserveReceiveIntent: true)
        connectLocked()
    }

    func systemDidEndTransmitting() {
        queue.async {
            self.talkButtonHeld = false
            self.systemTransmitStarted = false
            self.stopDeviceTransmitLocked()
        }
    }

    func systemTransmitFailed(_ message: String) {
        queue.async {
            if let stream = self.activeStream ?? self.pendingStream {
                self.sendJSON(WalkieControlMessage(type: "ptt_release", stream: stream))
            }
            self.talkButtonHeld = false
            self.systemTransmitStarted = false
            self.pendingStream = nil
            self.activeStream = nil
            self.snapshot.transmitting = false
            self.snapshot.status = message
            self.publish()
        }
    }

    func handleDeviceAudio(_ frame: Data) {
        queue.async {
            guard WalkieWire.validate(frame),
                  let stream = WalkieWire.streamID(in: frame),
                  stream == self.activeStream,
                  self.snapshot.connected else { return }
            if WalkieWire.hasEnd(frame) {
                self.sendBinary(frame) { [weak self] in
                    self?.finishTransmitLocked(stream: stream)
                }
            } else {
                self.sendBinary(frame)
            }
        }
    }

    func handleDeviceStatus(_ event: UInt8, code: UInt8) {
        queue.async {
            switch event {
            case WalkieWire.statusTxStarted:
                self.snapshot.transmitting = true
                self.snapshot.speaker = self.displayName
                self.snapshot.status = "正在讲话"
            case WalkieWire.statusTxStopped:
                if let stream = self.activeStream {
                    self.queue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        guard let self, self.activeStream == stream else { return }
                        self.finishTransmitLocked(stream: stream)
                    }
                }
            case WalkieWire.statusError:
                let stream = self.activeStream ?? self.pendingStream
                if let stream {
                    self.sendJSON(WalkieControlMessage(type: "ptt_release", stream: stream))
                }
                self.systemTransmitStarted = false
                self.pendingStream = nil
                self.activeStream = nil
                self.snapshot.transmitting = false
                self.snapshot.speaker = nil
                self.snapshot.status = "设备音频不可用(\(code))"
                if self.systemPTTAvailable?() == true {
                    DispatchQueue.main.async { self.stopSystemTransmit?() }
                }
            default:
                break
            }
            self.publish()
        }
    }

    private func connectLocked() {
        guard snapshot.installed, socket == nil else { return }
        guard let url = normalizedURL(serverAddress) else {
            snapshot.status = "服务器地址无效"
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
        sendJSON(WalkieControlMessage(
            type: "join",
            room: room.isEmpty ? "local" : room,
            name: displayName.isEmpty ? "Passport" : displayName,
            clientId: clientID,
            token: sharedToken,
            pushToken: pushToken.isEmpty ? nil : pushToken
        ))
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
                    self.lastSocketActivity = Date()
                    self.handleMessageLocked(message)
                    self.receiveNext(task, generation: generation)
                }
            }
        }
    }

    private func schedulePing(_ task: URLSessionWebSocketTask, generation: UInt64) {
        queue.asyncAfter(deadline: .now() + 20) { [weak self, weak task] in
            guard let self, let task, generation == self.generation,
                  task === self.socket else { return }
            task.sendPing { [weak self] error in
                self?.queue.async {
                    guard let self, generation == self.generation else { return }
                    if let error {
                        self.connectionFailedLocked(error.localizedDescription)
                    } else {
                        self.lastSocketActivity = Date()
                        self.schedulePing(task, generation: generation)
                    }
                }
            }
        }
    }

    private func handleMessageLocked(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let event = try? JSONDecoder().decode(WalkieServerEvent.self, from: data) else {
                return
            }
            handleServerEventLocked(event)
        case .data(let frame):
            guard WalkieWire.validate(frame),
                  let stream = WalkieWire.streamID(in: frame),
                  // 按 clientId 判断,不是显示名 —— 见 speakingIsSelf。
                  !speakingIsSelf else { return }
            if frame[1] & WalkieWire.flagStart != 0 || remoteStream != stream {
                deviceAudioQueue.removeAll()
            }
            remoteStream = stream
            deviceAudioQueue.enqueue(frame)
            armReceiveTimeoutLocked(stream: stream, after: 2)
            pumpDeviceAudioLocked()
        @unknown default:
            break
        }
    }

    /// 当前在讲话的是不是我自己。
    ///
    /// **不要用显示名比。** 显示名可以重复,而默认值就是 "Passport" ——
    /// 两台没改过昵称的设备进同一个房间,按名字比会把对方的声音当成自己的
    /// 回声整帧丢掉,用户看着屏幕说有人在讲话、却一个字也听不到。
    ///
    /// 老服务端不回 clientId,那时只能退回按名字比:不比改之前更差,
    /// 但也修不了重名。
    private var speakingIsSelf: Bool {
        if let sid = snapshot.speakerId, !sid.isEmpty, !myClientId.isEmpty {
            return sid == myClientId
        }
        return snapshot.speaker == displayName
    }

    private func handleServerEventLocked(_ event: WalkieServerEvent) {
        switch event.type {
        case "welcome":
            myClientId = event.clientId ?? ""
            snapshot.connected = true
            snapshot.members = event.members ?? 1
            snapshot.status = "频道空闲"
            if !pushToken.isEmpty {
                sendJSON(WalkieControlMessage(type: "push_token", pushToken: pushToken))
            }
            if talkButtonHeld {
                if systemPTTAvailable?() == true && systemTransmitStarted {
                    if systemAudioSessionActive {
                        requestFloorWhenConnectionReadyLocked()
                    }
                } else {
                    requestTransmitLocked()
                }
            }
        case "members":
            snapshot.members = event.members ?? snapshot.members
        case "speaker":
            snapshot.speaker = event.speaker
            snapshot.speakerId = event.clientId
            remoteStream = event.stream
            snapshot.status = "\(event.speaker ?? "有人") 正在讲话"
            armReceiveTimeoutLocked(stream: event.stream ?? 0, after: 10)
            if !speakingIsSelf {
                DispatchQueue.main.async {
                    self.onRemoteSpeakerChanged?(event.speaker)
                }
            }
        case "floor_granted":
            guard talkButtonHeld, let stream = event.stream,
                  stream == pendingStream else {
                if let stream = event.stream {
                    sendJSON(WalkieControlMessage(type: "ptt_release", stream: stream))
                }
                return
            }
            pendingStream = nil
            activeStream = stream
            snapshot.transmitting = true
            snapshot.speaker = displayName
            snapshot.speakerId = myClientId
            snapshot.status = "正在讲话"
            sendDeviceControl?(WalkieWire.controlStart, stream)
        case "floor_denied":
            talkButtonHeld = false
            systemTransmitStarted = false
            pendingStream = nil
            snapshot.status = "频道忙:\(event.speaker ?? "有人正在讲话")"
            if systemPTTAvailable?() == true {
                DispatchQueue.main.async { self.stopSystemTransmit?() }
            }
        case "idle":
            if speakingIsSelf {
                sendDeviceControl?(WalkieWire.controlStop, 0)
                pendingStream = nil
                activeStream = nil
                talkButtonHeld = false
                systemTransmitStarted = false
                snapshot.transmitting = false
                snapshot.speaker = nil
                snapshot.speakerId = nil
                snapshot.status = snapshot.connected ? "频道空闲" : "连接已断开"
                if systemPTTAvailable?() == true {
                    DispatchQueue.main.async { self.stopSystemTransmit?() }
                }
            } else if deviceAudioQueue.isEmpty && !deviceAudioPumpScheduled {
                finishReceivingLocked(stream: remoteStream)
            }
        case "error":
            // 服务端 join 失败只回一条 error、**不关连接**,而 WebSocket 握手
            // 本身是成功的(socket 非 nil、心跳照跑),所以 connectLocked() 的
            // `socket == nil` 前置条件会永远拦住重连 —— 口令填错一次就永久
            // 卡死,重启设备也没用。这里主动断开,让既有的重连逻辑接手。
            snapshot.status = Self.friendlyError(event.message)
            snapshot.connected = false
            disconnectLocked(reconnect: true)
        default:
            break
        }
        publish()
    }

    private func stopDeviceTransmitLocked() {
        guard let stream = activeStream ?? pendingStream else { return }
        if activeStream != nil {
            sendDeviceControl?(WalkieWire.controlStop, stream)
        }
        // The device normally emits an END frame after draining its current
        // 20 ms capture. This fallback prevents a disconnected BLE link from
        // keeping the server floor occupied until its watchdog fires.
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.activeStream == stream || self.pendingStream == stream else { return }
            self.finishTransmitLocked(stream: stream)
        }
    }

    private func armReceiveTimeoutLocked(stream: UInt16, after delay: TimeInterval) {
        receiveTimeout?.cancel()
        receiveGeneration &+= 1
        let myGeneration = receiveGeneration
        let work = DispatchWorkItem { [weak self] in
            self?.queue.async {
                guard let self, myGeneration == self.receiveGeneration else { return }
                self.deviceAudioQueue.removeAll()
                self.finishReceivingLocked(stream: stream)
            }
        }
        receiveTimeout = work
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func pumpDeviceAudioLocked() {
        guard snapshot.deviceConnected, !deviceAudioPumpScheduled,
              !deviceAudioQueue.isEmpty,
              systemPTTAvailable?() != true || systemAudioSessionActive else { return }
        let frame = deviceAudioQueue.removeFirst()
        let stream = WalkieWire.streamID(in: frame)
        let isEnd = WalkieWire.hasEnd(frame)
        sendDeviceAudio?(frame)
        deviceAudioPumpScheduled = true
        queue.asyncAfter(deadline: .now() + 0.020) { [weak self] in
            guard let self else { return }
            self.deviceAudioPumpScheduled = false
            if isEnd {
                self.finishReceivingLocked(stream: stream)
            }
            self.pumpDeviceAudioLocked()
        }
    }

    private func finishReceivingLocked(stream: UInt16?) {
        if let stream, let remoteStream, stream != remoteStream { return }
        receiveGeneration &+= 1
        receiveTimeout?.cancel()
        receiveTimeout = nil
        let wasRemote = snapshot.speaker != nil && snapshot.speaker != displayName
        if wasRemote {
            snapshot.speaker = nil
            snapshot.status = snapshot.connected ? "频道空闲" : "连接已断开"
            DispatchQueue.main.async { self.onRemoteSpeakerChanged?(nil) }
            publish()
        }
        remoteStream = nil
    }

    private func finishTransmitLocked(stream: UInt16) {
        sendJSON(WalkieControlMessage(type: "ptt_release", stream: stream))
        pendingStream = nil
        activeStream = nil
        snapshot.transmitting = false
        if snapshot.speaker == displayName {
            snapshot.speaker = nil
        }
        snapshot.status = snapshot.connected ? "频道空闲" : "连接已断开"
        publish()
    }

    private func sendJSON(_ value: WalkieControlMessage, completion: (() -> Void)? = nil) {
        guard socket != nil, let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return }
        enqueueSocket(.string(text), completion: completion)
    }

    private func sendBinary(_ data: Data, completion: (() -> Void)? = nil) {
        enqueueSocket(.data(data), completion: completion)
    }

    private func enqueueSocket(_ message: URLSessionWebSocketTask.Message,
                               completion: (() -> Void)? = nil) {
        guard socket != nil else { return }
        if case .data = message, socketOutbox.count >= 24 {
            // Index 0 is retained until URLSession finishes its callback.
            // Removing it while a write is in flight would make the callback
            // remove the next message instead.
            let firstPending = socketWriteInFlight ? 1 : 0
            let pending = socketOutbox.indices.dropFirst(firstPending)
            let stale = pending.first(where: {
                guard case .data(let frame) = socketOutbox[$0].message else { return false }
                return !WalkieWire.hasStart(frame) && !WalkieWire.hasEnd(frame)
            }) ?? pending.first(where: {
                guard case .data(let frame) = socketOutbox[$0].message else { return false }
                return !WalkieWire.hasEnd(frame)
            })
            if let stale {
                socketOutbox.remove(at: stale)
            }
        }
        socketOutbox.append((message, completion))
        pumpSocket()
    }

    private func pumpSocket() {
        guard !socketWriteInFlight, let socket, !socketOutbox.isEmpty else { return }
        let item = socketOutbox[0]
        let myGeneration = generation
        socketWriteInFlight = true
        socket.send(item.message) { [weak self, weak socket] error in
            guard let self, let socket else { return }
            self.queue.async {
                guard myGeneration == self.generation, socket === self.socket else { return }
                self.socketWriteInFlight = false
                if !self.socketOutbox.isEmpty {
                    self.socketOutbox.removeFirst()
                }
                if let error {
                    self.connectionFailedLocked(error.localizedDescription)
                    return
                }
                self.lastSocketActivity = Date()
                item.completion?()
                self.pumpSocket()
            }
        }
    }

    private func connectionFailedLocked(_ message: String) {
        guard socket != nil else { return }
        let incomingWake = snapshot.installed &&
            snapshot.speaker != nil && snapshot.speaker != displayName
        let activeSystemTransmit = snapshot.installed &&
            talkButtonHeld && systemTransmitStarted
        disconnectLocked(reconnect: !(incomingWake || activeSystemTransmit),
                         preserveTransmitIntent: activeSystemTransmit,
                         preserveReceiveIntent: incomingWake)
        if incomingWake || activeSystemTransmit {
            connectLocked()
        } else {
            snapshot.status = "连接中断:\(message)"
            publish()
        }
    }

    private func disconnectLocked(reconnect: Bool,
                                  preserveTransmitIntent: Bool = false,
                                  preserveReceiveIntent: Bool = false) {
        let shouldStopSystemTransmit = !preserveTransmitIntent &&
            (talkButtonHeld || systemTransmitStarted ||
             pendingStream != nil || activeStream != nil)
        let held = talkButtonHeld
        let systemStarted = systemTransmitStarted
        let remoteSpeaker = preserveReceiveIntent ? snapshot.speaker : nil
        generation &+= 1
        reconnectWork?.cancel()
        reconnectWork = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        socketOutbox.removeAll()
        socketWriteInFlight = false
        lastSocketActivity = .distantPast
        socketProbeInFlight = false
        receiveGeneration &+= 1
        receiveTimeout?.cancel()
        receiveTimeout = nil
        remoteStream = nil
        deviceAudioQueue.removeAll()
        deviceAudioPumpScheduled = false
        talkButtonHeld = preserveTransmitIntent ? held : false
        systemTransmitStarted = preserveTransmitIntent ? systemStarted : false
        snapshot.connected = false
        snapshot.members = 0
        snapshot.speaker = remoteSpeaker
        snapshot.transmitting = false
        pendingStream = nil
        activeStream = nil
        sendDeviceControl?(WalkieWire.controlStop, 0)
        DispatchQueue.main.async {
            if shouldStopSystemTransmit {
                self.stopSystemTransmit?()
            }
            if !preserveReceiveIntent {
                self.onRemoteSpeakerChanged?(nil)
            }
        }
        if preserveReceiveIntent {
            armReceiveTimeoutLocked(stream: 0, after: 10)
        }

        if reconnect && snapshot.installed {
            let work = DispatchWorkItem { [weak self] in
                self?.queue.async { self?.connectLocked() }
            }
            reconnectWork = work
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    private func publish() {
        let value = snapshot
        onSnapshot?(value)
    }

    private func normalizedURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.contains("://") { text = "ws://" + text }
        guard var components = URLComponents(string: text) else { return nil }
        if components.scheme == "http" { components.scheme = "ws" }
        if components.scheme == "https" { components.scheme = "wss" }
        guard components.scheme == "ws" || components.scheme == "wss" else { return nil }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1/ws"
        }
        return components.url
    }
}
