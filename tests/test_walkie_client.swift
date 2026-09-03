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

        let client = WalkieClient(defaults: defaults)
        let config = client.currentConfiguration()
        check(config.server == "ws://127.0.0.1:8787/v1/ws", "默认连接本机服务")
        check(config.room == "local", "默认房间为 local")
        check(config.name == "Passport", "默认昵称可用")

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
        let restored = WalkieClient(defaults: defaults)
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
