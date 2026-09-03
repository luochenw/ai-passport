import Foundation

#if os(iOS)
import AVFoundation
import PushToTalk
import UIKit

final class SystemPushToTalk: NSObject, PTChannelManagerDelegate, PTChannelRestorationDelegate {
    private let channelUUID = UUID(uuidString: "8CC419BC-14D3-462B-88AD-F78E6FDA03F6")!
    private var manager: PTChannelManager?
    private var enabled = false
    private var joinRequested = false
    private var ready = false
    private var room = "local"
    private let lock = NSLock()
    private var foregroundObserver: NSObjectProtocol?

    var onPushToken: ((Data) -> Void)?
    var onIncomingSpeaker: ((String) -> Void)?
    var onBeginTransmitting: ((_ systemInitiated: Bool) -> Void)?
    var onEndTransmitting: (() -> Void)?
    var onAudioSessionChanged: ((Bool) -> Void)?
    var onTransmitFailure: ((String) -> Void)?

    init(room: String) {
        self.room = room.isEmpty ? "local" : room
        super.init()
    }

    func start(restoringEnabled: Bool) {
        #if targetEnvironment(simulator)
        log("[ptt] 模拟器不提供 Push to Talk 运行时,使用前台模式")
        #else
        lock.lock()
        enabled = restoringEnabled
        lock.unlock()
        configureAudioSession()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.prepareForForegroundUse(join: false)
        }
        PTChannelManager.channelManager(delegate: self, restorationDelegate: self) {
            [weak self] manager, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    log("[ptt] 初始化失败,退回前台模式: \(error)")
                    return
                }
                guard let manager else {
                    log("[ptt] 初始化未返回频道管理器,退回前台模式")
                    return
                }
                self.lock.lock()
                self.manager = manager
                let restored = manager.activeChannelUUID == self.channelUUID
                self.ready = restored
                if restored {
                    self.enabled = true
                }
                let enabled = self.enabled
                let joinRequested = self.joinRequested
                self.lock.unlock()
                if enabled {
                    self.prepareForForegroundUse(join: joinRequested)
                }
            }
        }
        #endif
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    func setEnabled(_ enabled: Bool, room: String) {
        DispatchQueue.main.async {
            self.lock.lock()
            self.enabled = enabled
            self.joinRequested = enabled
            self.room = room.isEmpty ? "local" : room
            let manager = self.manager
            self.lock.unlock()

            guard let manager else { return }
            if enabled {
                self.prepareForForegroundUse(join: true)
            } else if manager.activeChannelUUID == self.channelUUID {
                self.onPushToken?(Data())
                manager.leaveChannel(channelUUID: self.channelUUID)
            }
        }
    }

    func updateRoom(_ room: String) {
        DispatchQueue.main.async {
            self.lock.lock()
            self.room = room.isEmpty ? "local" : room
            let manager = self.manager
            let enabled = self.enabled
            let name = self.room
            self.lock.unlock()
            guard enabled, let manager else { return }
            let descriptor = PTChannelDescriptor(name: name, image: nil)
            if manager.activeChannelUUID == self.channelUUID {
                manager.setChannelDescriptor(descriptor, channelUUID: self.channelUUID,
                                             completionHandler: nil)
            } else if UIApplication.shared.applicationState == .active {
                self.lock.lock()
                self.joinRequested = true
                self.lock.unlock()
                self.prepareForForegroundUse(join: true)
            }
        }
    }

    func beginTransmitting() {
        DispatchQueue.main.async {
            guard let manager = self.manager,
                  manager.activeChannelUUID == self.channelUUID else {
                self.onTransmitFailure?("系统对讲频道尚未就绪")
                return
            }
            manager.requestBeginTransmitting(channelUUID: self.channelUUID)
        }
    }

    func stopTransmitting() {
        DispatchQueue.main.async {
            guard let manager = self.manager,
                  manager.activeChannelUUID == self.channelUUID else { return }
            manager.stopTransmitting(channelUUID: self.channelUUID)
        }
    }

    func setRemoteSpeaker(_ name: String?) {
        DispatchQueue.main.async {
            guard let manager = self.manager,
                  manager.activeChannelUUID == self.channelUUID else { return }
            let participant = name.map { PTParticipant(name: $0, image: nil) }
            manager.setActiveRemoteParticipant(participant, channelUUID: self.channelUUID,
                                               completionHandler: nil)
        }
    }

    private func joinIfNeeded() {
        guard let manager else { return }
        if manager.activeChannelUUID == channelUUID {
            manager.setChannelDescriptor(PTChannelDescriptor(name: room, image: nil),
                                         channelUUID: channelUUID, completionHandler: nil)
            return
        }
        manager.requestJoinChannel(channelUUID: channelUUID,
                                   descriptor: PTChannelDescriptor(name: room, image: nil))
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
        } catch {
            log("[ptt] 配置系统音频会话失败:\(error)")
        }
    }

    private func prepareForForegroundUse(join: Bool) {
        guard UIApplication.shared.applicationState == .active else { return }
        lock.lock()
        let enabled = self.enabled
        let shouldJoin = join || joinRequested
        lock.unlock()
        guard enabled else { return }

        configureAudioSession()
        AVAudioApplication.requestRecordPermission { granted in
            if !granted {
                log("[ptt] 麦克风权限未授权,系统对讲发送不可用")
            }
        }
        if shouldJoin {
            joinIfNeeded()
        }
    }

    func channelManager(_ channelManager: PTChannelManager,
                        didJoinChannel channelUUID: UUID,
                        reason: PTChannelJoinReason) {
        lock.lock()
        ready = true
        joinRequested = false
        lock.unlock()
        log("[ptt] 已加入系统频道: \(reason.rawValue)")
        channelManager.setTransmissionMode(.halfDuplex, channelUUID: channelUUID,
                                           completionHandler: nil)
        channelManager.setAccessoryButtonEventsEnabled(false, channelUUID: channelUUID,
                                                       completionHandler: nil)
    }

    func channelManager(_ channelManager: PTChannelManager,
                        didLeaveChannel channelUUID: UUID,
                        reason: PTChannelLeaveReason) {
        lock.lock()
        ready = false
        enabled = false
        joinRequested = false
        lock.unlock()
        onAudioSessionChanged?(false)
        log("[ptt] 已离开系统频道: \(reason.rawValue)")
        onPushToken?(Data())
    }

    func channelManager(_ channelManager: PTChannelManager,
                        channelUUID: UUID,
                        didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        onBeginTransmitting?(source != .developerRequest)
    }

    func channelManager(_ channelManager: PTChannelManager,
                        channelUUID: UUID,
                        didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        onEndTransmitting?()
    }

    func channelManager(_ channelManager: PTChannelManager,
                        receivedEphemeralPushToken pushToken: Data) {
        onPushToken?(pushToken)
    }

    func incomingPushResult(channelManager: PTChannelManager,
                            channelUUID: UUID,
                            pushPayload: [String: Any]) -> PTPushResult {
        lock.lock()
        let enabled = self.enabled
        lock.unlock()
        guard enabled else { return .leaveChannel }
        guard let speaker = pushPayload["activeSpeaker"] as? String, !speaker.isEmpty else {
            return .leaveChannel
        }
        onIncomingSpeaker?(speaker)
        return .activeRemoteParticipant(PTParticipant(name: speaker, image: nil))
    }

    func channelManager(_ channelManager: PTChannelManager,
                        didActivate audioSession: AVAudioSession) {
        log("[ptt] 系统音频会话已激活")
        onAudioSessionChanged?(true)
    }

    func channelManager(_ channelManager: PTChannelManager,
                        didDeactivate audioSession: AVAudioSession) {
        log("[ptt] 系统音频会话已停用")
        onAudioSessionChanged?(false)
    }

    func channelManager(_ channelManager: PTChannelManager,
                        failedToBeginTransmittingInChannel channelUUID: UUID,
                        error: Error) {
        onTransmitFailure?("系统拒绝开始讲话:\(error.localizedDescription)")
    }

    func channelManager(_ channelManager: PTChannelManager,
                        failedToJoinChannel channelUUID: UUID,
                        error: Error) {
        lock.lock()
        ready = false
        joinRequested = false
        lock.unlock()
        onTransmitFailure?("系统对讲频道加入失败:\(error.localizedDescription)")
    }

    func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        lock.lock()
        let name = room
        lock.unlock()
        return PTChannelDescriptor(name: name, image: nil)
    }
}
#endif
