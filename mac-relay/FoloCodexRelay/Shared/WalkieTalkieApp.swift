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
        // 设备屏上一行只有 26 个半角,写不下"含自己"的解释 —— 但设备是
        // 用户拿在手里的那一台,他知道自己有几台;真正会误解的是电脑上那
        // 一行,解释放在那里(见 WalkieSettingsView)。
        screen.text("在线  \(state.members) 人")
        screen.spacer()
        if state.transmitting {
            screen.text("• 我正在讲话")
        } else if let speaker = state.speaker {
            screen.text("• \(speaker) 正在讲话")
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

/// 一行状态:左边标签,右边一个圆点 + 文字。
///
/// 原来这几行是纯文字("已连接"/"未连接"),要逐行读才知道哪儿不对。
/// 颜色圆点让"有没有问题"在扫一眼的时候就出来了。
private struct StatusRow: View {
    let label: String
    let text: String
    var ok: Bool? = nil        // nil = 中性,不涂色

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if let ok {
                Circle()
                    .fill(ok ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
            }
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

struct WalkieTalkieView: View {
    @ObservedObject var model: WalkieTalkieApp

    private var s: WalkieSnapshot { model.snapshot }

    var body: some View {
        Form {
            Section("状态") {
                StatusRow(label: "对讲服务", text: s.connected ? "已连接" : "未连接",
                          ok: s.connected)
                // ⚠ 这里说的是「设备」,不是用户昵称。原来的标签写的是
                // "Passport",在配套 app 里勉强能懂,但同一个字符串也会被推到
                // 设备屏幕上 —— 那时它在说"我没连上我自己"。
                StatusRow(label: "设备", text: s.deviceConnected ? "已连接" : "未连接",
                          ok: s.deviceConnected)
                StatusRow(label: "房间", text: s.room)
                // ⚠ 这个数字是**房间里的连接数**,不是"别人"。你自己的每台
                // Passport 都是独立的一位(各有 clientId,否则会被服务端顶号),
                // 所以两台设备接一台电脑就已经是 2 了 —— 不写清楚的话,用户会
                // 以为有同事在听。
                StatusRow(label: "在线", text: "\(s.members) 人(含你自己的设备)")
                StatusRow(label: "频道",
                          text: s.speaker.map { "\($0) 正在讲话" } ?? s.status,
                          ok: s.speaker == nil ? nil : true)
            }

            Section {
                TextField("服务器", text: $model.serverAddress, prompt: Text("ws://127.0.0.1:8787/v1/ws"))
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                TextField("房间", text: $model.room, prompt: Text("local"))
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                TextField("昵称", text: $model.displayName, prompt: Text("Passport"))
                SecureField("共享口令", text: $model.sharedToken, prompt: Text("留空表示服务端未设口令"))
            } header: {
                Text("连接")
            } footer: {
                // 口令的去向值得说一句 —— 用户填的是能进同一个房间听音频的东西。
                Text("同一个房间里的人才能互相听到。口令存在系统钥匙串,不写配置文件、不进日志。")
            }

            Section {
                HStack {
                    Button("重新连接") { model.reconnect() }
                    Spacer()
                    Button("保存并连接") { model.saveAndReconnect() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            } footer: {
                Text("装到设备首屏后会持续监听,设备不用停在对讲机页面也能收听。讲话时在设备上按住下键。")
            }
        }
        // ⚠ .grouped 不是装饰:不加的话 macOS 上 Form 会退化成一堆挤在一起的
        // 控件,分组标题和分隔线都不出现,看着就是"没做样式"。
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }
}
