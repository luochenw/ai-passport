import Foundation
import SwiftUI

// 这个文件现在是**能力**,不是应用。
//
// 对讲最能说明"应用"和"能力"是两件事:WalkieTalkieApp.render() 里从来没有
// 一行音频代码 —— 它只是四行插值加一个三分支,handleKey 也只有两行
// (下键按下 beginTalk、松开 endTalk)。音频走的是
// 设备 → BLE 对讲特征值 → BLERelay → WalkieClient → WebSocket,那是传输层。
//
// 所以屏幕和按键绑定进了 AppManifests/walkie.json,可以从 GitHub 更新;
// 留在这里的是清单描述不了的:实时音频通道、抢麦状态机、以及伴侣端那个
// SwiftUI 设置页的 @Published 模型。
final class WalkieCapability: ObservableObject, AppCapability {
    static let id = "walkie"

    var onChange: (() -> Void)?
    /// 后台来话的通知。由解释器注入 —— 通知走 cmd.notify,跟屏幕是两条路。
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
            self.onChange?()
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
            onChange?()
        } else {
            client.endTalk()
        }
    }

    /// 清单里 `down.press` / `down.release` 绑到这儿。
    ///
    /// ⚠ 返回 false:按住说话不该触发重推屏幕。真正的界面变化由服务器的
    /// 抢麦回执驱动(onSnapshot → onChange),按下的那一瞬间还什么都没变 ——
    /// 返回 true 会让每次按住都多推一屏没有变化的内容。
    @discardableResult
    func perform(_ action: String) -> Bool {
        switch action {
        case "beginTalk": client.beginTalk()
        case "endTalk": client.endTalk()
        default: break
        }
        return false
    }

    /// 交给模板取值的那棵树。
    func state() -> JSONValue {
        stateLock.lock()
        let s = deviceSnapshot
        stateLock.unlock()
        return .object([
            "room": .string(s.room),
            "connected": .bool(s.connected),
            "members": .number(Double(s.members)),
            "transmitting": .bool(s.transmitting),
            "speaker": s.speaker.map { JSONValue.string($0) } ?? .null,
            "status": .string(s.status),
        ])
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
    @ObservedObject var model: WalkieCapability

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
                TextField("服务器地址", text: $model.serverAddress, prompt: Text("服务器IP:8787"))
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
                Text("局域网可填写“服务器IP:8787”；公网请使用带受信任证书的 wss:// 域名。同一房间和口令的用户可以互相通话；口令保存在系统钥匙串。")
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
