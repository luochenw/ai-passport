import Foundation
import SwiftUI

final class WalkieTalkieApp: ObservableObject, RemoteApp {
    let name = "对讲机"
    let detail = "局域网实时对讲"
    let defaultIcon = DeviceIcon.find("\u{F0E0}").glyph
    let settingsRoute: RemoteAppSettingsRoute? = .walkieTalkie
    var requestPush: (() -> Void)?
    var notify: ((String) -> Void)?

    @Published var serverAddress: String
    @Published var room: String
    @Published var displayName: String
    @Published var sharedToken: String
    @Published private(set) var snapshot: WalkieSnapshot

    private let client: WalkieClient
    private let stateLock = NSLock()
    private var deviceSnapshot = WalkieSnapshot()
    private var devicePageActive = false

    var installationChanged: ((Bool, String) -> Void)?
    var roomChanged: ((String) -> Void)?

    init(client: WalkieClient) {
        self.client = client
        let config = client.currentConfiguration()
        serverAddress = config.server
        room = config.room
        displayName = config.name
        sharedToken = config.token
        snapshot = client.currentSnapshot()
        deviceSnapshot = snapshot

        client.onSnapshot = { [weak self] value in
            guard let self else { return }
            self.stateLock.lock()
            let previousSpeaker = self.deviceSnapshot.speaker
            let deviceReconnected = !self.deviceSnapshot.deviceConnected && value.deviceConnected
            let shouldNotify = !self.devicePageActive &&
                !value.transmitting && value.speaker != nil &&
                (value.speaker != previousSpeaker || deviceReconnected)
            self.deviceSnapshot = value
            self.stateLock.unlock()
            if shouldNotify, let speaker = value.speaker {
                self.notify?("对讲来话：\(speaker)")
            }
            DispatchQueue.main.async {
                self.snapshot = value
            }
            self.requestPush?()
        }
        client.onInstalledChanged = { [weak self] installed, room in
            self?.installationChanged?(installed, room)
        }
        client.onRoomChanged = { [weak self] room in
            self?.roomChanged?(room)
        }
    }

    func setInstalled(_ installed: Bool) {
        client.setInstalled(installed)
    }

    func setActive(_ active: Bool) {
        stateLock.lock()
        devicePageActive = active
        stateLock.unlock()
        if active {
            requestPush?()
        } else {
            client.endTalk()
        }
    }

    func handleKey(_ button: RemoteButton, _ event: RemoteButtonEvent) -> Bool {
        guard button == .down else { return false }
        if event == .press {
            client.beginTalk()
        } else if event == .release {
            client.endTalk()
        }
        return false
    }

    func render() -> Screen {
        stateLock.lock()
        let state = deviceSnapshot
        stateLock.unlock()

        var screen = Screen()
        screen.title = "对讲机"
        screen.text("房间  \(state.room)")
        screen.text(state.connected ? "服务  已连接" : "服务  未连接")
        screen.text("在线  \(state.members) 人")
        screen.spacer()
        if state.transmitting {
            screen.text("● 我正在讲话")
        } else if let speaker = state.speaker {
            screen.text("● \(speaker) 正在讲话")
        } else {
            screen.text(state.status)
        }
        screen.walkie = true
        screen.footer = state.connected ? "按住下键讲话" : "请在伴侣端检查服务"
        return screen
    }

    func saveAndReconnect() {
        if snapshot.installed {
            installationChanged?(true, room)
        }
        client.configure(server: serverAddress, room: room,
                         name: displayName, token: sharedToken)
    }

    func reconnect() {
        if snapshot.installed {
            installationChanged?(true, room)
        }
        client.reconnect()
    }
}

struct WalkieTalkieView: View {
    @ObservedObject var model: WalkieTalkieApp

    var body: some View {
        Form {
            Section("状态") {
                LabeledContent("服务", value: model.snapshot.connected ? "已连接" : "未连接")
                LabeledContent("Passport", value: model.snapshot.deviceConnected ? "已连接" : "未连接")
                LabeledContent("房间", value: model.snapshot.room)
                LabeledContent("在线", value: "\(model.snapshot.members) 人")
                LabeledContent("频道", value: model.snapshot.speaker.map { "\($0) 正在讲话" } ?? model.snapshot.status)
            }

            Section("本地服务") {
                TextField("WebSocket 地址", text: $model.serverAddress)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                TextField("房间", text: $model.room)
                TextField("昵称", text: $model.displayName)
                SecureField("共享口令（可选）", text: $model.sharedToken)
                HStack {
                    Button("重新连接") { model.reconnect() }
                    Spacer()
                    Button("保存并连接") { model.saveAndReconnect() }
                        .keyboardShortcut(.defaultAction)
                }
            }

            Section {
                Text("对讲机安装到设备首屏后会持续监听。设备无需停留在对讲机页面也能收听；讲话时在设备上按住下键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }
}
