import Foundation

func log(_ s: String) {
    if ProcessInfo.processInfo.environment["VERBOSE"] != nil {
        print(s)
    }
}

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✓ \(message)")
    } else {
        print("  ✗ \(message)")
        failures += 1
    }
}

@main
struct TestWalkieClient {
    static func main() {
        let suite = "test.walkie.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("   ", forKey: "walkie.server")

        let client = WalkieClient(deviceKey: "devA", defaultName: "Passport-2C44",
                                  defaults: defaults)
        let config = client.currentConfiguration()
        check(config.server == "ws://127.0.0.1:8787/v1/ws", "默认连接本机服务")
        check(config.room == "local", "默认房间为 local")
        check(config.name == "Passport-2C44", "默认昵称派生自设备广播名")
        check(WalkieClient.normalizedURL("203.0.113.8")?.absoluteString ==
              "ws://203.0.113.8:8787/v1/ws", "公网 IP 可省略协议和默认端口")
        check(WalkieClient.normalizedURL("https://talk.example.com")?.absoluteString ==
              "wss://talk.example.com/v1/ws", "HTTPS 地址转换为安全 WebSocket")
        check(WalkieClient.normalizedURL("") == nil, "拒绝空服务器地址")

        let configDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"]!)
            .appendingPathComponent(".folotoy/apps", isDirectory: true)
        try! FileManager.default.createDirectory(at: configDir,
                                                 withIntermediateDirectories: true)
        try! Data(#"{"server":"198.51.100.7:8787"}"#.utf8)
            .write(to: configDir.appendingPathComponent("walkie.json"))
        let configSuite = "test.walkie.config.\(UUID().uuidString)"
        let configDefaults = UserDefaults(suiteName: configSuite)!
        defer { configDefaults.removePersistentDomain(forName: configSuite) }
        let configured = WalkieClient(deviceKey: "configured", defaultName: "Passport",
                                      defaults: configDefaults)
        check(configured.currentConfiguration().server ==
              "ws://198.51.100.7:8787/v1/ws",
              "从标准本地配置读取对讲服务地址")
        try? FileManager.default.removeItem(at: configDir.appendingPathComponent("walkie.json"))

        // ⚠ 每台设备必须有**不同**的 clientId。服务端在同一房间里按 clientId
        // 顶号(services/walkie-server/main.go:296-308),两台共用一个的话会
        // 每两秒互踢一次,谁按住说话都会在几秒内掉线 —— 这是"两个设备就是
        // 两个人"这件事在协议层的硬要求,不是风格问题。
        let other = WalkieClient(deviceKey: "devB", defaultName: "Passport-5144",
                                 defaults: defaults)
        check(client.currentClientID() != other.currentClientID(),
              "不同设备拿到不同的对讲 clientId")
        check(other.currentConfiguration().name == "Passport-5144",
              "第二台有自己的昵称")
        // 口令/房间/服务器仍然是全局一份:那是房间口令,按设备拆的话用户
        // 每选一台设备都得重填一次。
        check(client.currentConfiguration().room == other.currentConfiguration().room,
              "房间是全局一份")

        var frame = Data(repeating: 0, count: WalkieWire.headerSize + 80)
        frame[0] = WalkieWire.protocolVersion
        frame[1] = WalkieWire.flagStart
        frame[2] = 0x34
        frame[3] = 0x12
        frame[6] = 160
        check(WalkieWire.validate(frame), "合法实时音频帧可通过校验")
        check(WalkieWire.streamID(in: frame) == 0x1234, "正确读取 stream id")

        frame[0] = 2
        check(!WalkieWire.validate(frame), "拒绝未知协议版本")

        defaults.set(["对讲机"], forKey: "remote.installed")
        let restored = WalkieClient(deviceKey: "devA", defaultName: "Passport-2C44",
                                    defaults: defaults)
        check(restored.currentSnapshot().installed, "冷启动时恢复已安装对讲状态")
        restored.setInstalled(true)
        restored.setInstalled(false)

        if failures == 0 {
            print("walkie client: PASS")
            exit(0)
        }
        exit(1)
    }
}
