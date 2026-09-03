// tests/test_remote_apps.swift —— 远程应用商店逻辑的宿主机回归测试。
//
// 覆盖的是用户明确要求的那条链路:
//   进应用商店 → 选择安装 → 出现在首屏 → 商店里不再列出它 → 能卸载
//
// 为什么值得单独测:这条链路横跨"设备按键 → 事件 → host 状态 → 清单推送"
// 四层,而它的失败模式全都是**静默**的 —— 装了但清单没推出去、卸了但设备
// 首屏还留着、装到第 9 个被悄悄丢掉。这些在真机上要一步步试才能发现,而且
// 设备不在手边时根本没法验。
//
// 编译运行(tools/validate.sh --static 会自动跑):
//   swiftc -o /tmp/t tests/test_remote_apps.swift \
//       mac-relay/FoloCodexRelay/RemoteApps.swift && /tmp/t
import Foundation

// RemoteApps.swift 里用到 main.swift 的 log();测试只需要一个不吵的桩。
func log(_ s: String) { if ProcessInfo.processInfo.environment["VERBOSE"] != nil { print(s) } }

// MARK: - 断言

var failures = 0
func check(_ cond: Bool, _ what: String) {
    if cond {
        print("  ✓ \(what)")
    } else {
        print("  ✗ \(what)")
        failures += 1
    }
}
func checkEqual<T: Equatable>(_ a: T, _ b: T, _ what: String) {
    if a == b {
        print("  ✓ \(what)")
    } else {
        print("  ✗ \(what)\n      期望: \(b)\n      实际: \(a)")
        failures += 1
    }
}

// MARK: - 测试替身

final class FakeApp: RemoteApp {
    let name: String
    let detail: String
    /// ⚠ 必须是这个类自己的成员,不能靠 RemoteApp 协议扩展里的默认实现:
    /// 协议扩展的默认实现是**静态派发**的,子类覆盖不了,通过协议类型调用时
    /// 拿到的还是默认值。真实应用(CodexApp 等)也是这么写的。
    let defaultIcon: String
    let settingsRoute: RemoteAppSettingsRoute?
    var requestPush: (() -> Void)?
    var notify: ((String) -> Void)?
    private(set) var activeCount = 0
    private(set) var installed = false

    init(_ name: String, _ detail: String = "测试用",
         icon: String = DeviceIcon.fallback.glyph,
         settingsRoute: RemoteAppSettingsRoute? = nil) {
        self.name = name
        self.detail = detail
        self.defaultIcon = icon
        self.settingsRoute = settingsRoute
    }
    func render() -> Screen {
        var s = Screen()
        s.title = name
        s.text("hello from \(name)")
        return s
    }
    func handleKey(_ button: RemoteButton, _ event: RemoteButtonEvent) -> Bool { true }
    func setActive(_ active: Bool) { activeCount += active ? 1 : -1 }
    func setInstalled(_ installed: Bool) { self.installed = installed }
}

/// 每个用例一份全新的、不落到用户真实配置里的存储。
func freshDefaults(_ tag: String) -> UserDefaults {
    let name = "test.remoteapps.\(tag)"
    UserDefaults.standard.removePersistentDomain(forName: name)
    return UserDefaults(suiteName: name)!
}

/// 收集 host 发出去的东西。必须是**引用类型** —— 用局部数组变量的话,闭包
/// 捕获的是那一刻的值副本,测试里永远读到空的。
final class Collector {
    var screens: [String] = []
    var manifests: [String] = []
    var lists: [[RemoteAppInfo]] = []
}

func makeHost(_ tag: String, _ c: Collector) -> RemoteAppHost {
    let h = RemoteAppHost(
        send: { c.screens.append($0) },
        sendManifest: { c.manifests.append($0) },
        defaults: freshDefaults(tag),
        enableDebugChannel: false
    )
    // 必须用 setListObserver:直接赋值会跟 register() 在 host 队列上的
    // 那几次发布抢跑,而且是数据竞争。
    h.setListObserver { c.lists.append($0) }
    return h
}

/// 清单里的应用名。每行是 "<图标>\t<名字>";空清单在协议上是一个单独的换行。
func manifestNames(_ s: String) -> [String] {
    s.split(separator: "\n").map { line in
        guard let tab = line.firstIndex(of: "\t") else { return String(line) }
        return String(line[line.index(after: tab)...])
    }
}

/// 清单里的图标(跟 manifestNames 一一对应)。
func manifestIcons(_ s: String) -> [String] {
    s.split(separator: "\n").map { line in
        guard let tab = line.firstIndex(of: "\t") else { return "" }
        return String(line[..<tab])
    }
}

// MARK: - 用例
//
// Swift 只允许名为 main.swift 的文件写顶层语句,所以这里用 @main 入口。
@main
struct TestRemoteApps {
    static func main() {
        print("== 1. 装之前:清单是空的,首屏什么都不列 ==")
        do {
            let c = Collector()
            let h = makeHost("empty", c)
            h.register(FakeApp("面板"))
            h.register(FakeApp("Codex"))
            h.waitForPendingWork()
            // ⚠ 回归:注册不是安装事件,一次清单都不该推。原来 register()
            // 里推清单,后果是(a)启动时应用一个一个注册,设备先收到几份
            // 残缺清单;(b)全新安装时 installed 是空的,推过去的空清单会
            // 把设备 NVS 里缓存的首屏清掉 —— 用户什么都没做,首屏就空了。
            checkEqual(c.manifests.count, 0, "注册不推清单")
            checkEqual(c.lists.last?.count, 2, "两个应用都在列表里")
            checkEqual(c.lists.last?.allSatisfy { !$0.installed }, true, "都还没装")

            // 连上设备才推,而且推的是一份货真价实的空清单。
            h.deviceReady()
            h.waitForPendingWork()
            checkEqual(c.manifests.count, 1, "连上设备推一次")
            checkEqual(manifestNames(c.manifests.last ?? ""), [], "清单为空")
        }

        print("== 2. 进商店 → 选中 → 确定安装 ==")
        do {
            let c = Collector()
            let h = makeHost("install", c)
            h.register(FakeApp("面板"))
            h.register(FakeApp("Codex"))
            h.waitForPendingWork()

            h.openApp(0xFE)                       // 设备首屏选了"应用商店"
            h.waitForPendingWork()
            check(c.screens.last?.contains("应用商店") == true, "商店那一屏推出去了")
            check(c.screens.last?.contains("面板") == true, "商店列出了「面板」")

            h.handleKey(RemoteButton.ok.rawValue, RemoteButtonEvent.click.rawValue)
            h.waitForPendingWork()
            checkEqual(manifestNames(c.manifests.last ?? ""), ["面板"], "「面板」进了清单 → 会出现在设备首屏")

            // 用户的原话:「应用商店记录状态,再次点击就不出现了」
            check(c.screens.last?.contains("面板") == false, "装完之后商店里不再列出「面板」")
            check(c.screens.last?.contains("Codex") == true, "没装的「Codex」还在")
        }

        print("== 2b. 应用专属设置入口跟随应用元数据 ==")
        do {
            let c = Collector()
            let h = makeHost("settings-route", c)
            h.register(FakeApp("面板"))
            h.register(FakeApp("对讲机", settingsRoute: .walkieTalkie))
            h.waitForPendingWork()

            let panel = c.lists.last?.first { $0.name == "面板" }
            let walkie = c.lists.last?.first { $0.name == "对讲机" }
            checkEqual(panel?.settingsRoute, nil, "普通应用不显示设置入口")
            checkEqual(walkie?.settingsRoute, .walkieTalkie,
                       "对讲机列表项携带设置路由")
        }

        print("== 3. 首屏按下标打开的是已安装的那个 ==")
        do {
            let c = Collector()
            let h = makeHost("open", c)
            let panel = FakeApp("面板")
            h.register(FakeApp("Codex"))          // 注册顺序故意跟安装顺序不同
            h.register(panel)
            h.requestInstall("面板", true)
            h.waitForPendingWork()

            h.openApp(0)                          // 首屏第 0 项 = 已安装列表的第 0 个
            h.waitForPendingWork()
            check(c.screens.last?.contains("hello from 面板") == true, "打开的是「面板」而不是注册顺序里的第一个")
        }

        print("== 3b. BLE 恢复后能恢复设备正在看的应用 ==")
        do {
            let c = Collector()
            let h = makeHost("restore-open", c)
            let panel = FakeApp("面板")
            h.register(panel)
            h.requestInstall("面板", true)
            h.waitForPendingWork()

            h.deviceReady(active: true, appIndex: 0)
            h.waitForPendingWork()
            check(c.screens.last?.contains("hello from 面板") == true,
                  "恢复连接后重新推出当前应用屏幕")
            checkEqual(panel.activeCount, 1, "恢复连接后应用重新进入 active")
        }

        print("== 4. 卸载:从清单里消失,商店里重新出现 ==")
        do {
            let c = Collector()
            let h = makeHost("uninstall", c)
            h.register(FakeApp("面板"))
            h.requestInstall("面板", true)
            h.waitForPendingWork()
            checkEqual(manifestNames(c.manifests.last ?? ""), ["面板"], "先装上")

            h.requestInstall("面板", false)
            h.waitForPendingWork()
            checkEqual(manifestNames(c.manifests.last ?? ""), [], "卸载后清单清空")
            checkEqual(c.lists.last?.first?.installed, false, "界面列表里标记为未安装")
        }

        print("== 5. 装满 8 个之后必须明确拒绝,不能静默丢掉 ==")
        do {
            let c = Collector()
            let h = makeHost("cap", c)
            for i in 1...9 { h.register(FakeApp("应用\(i)")) }
            h.waitForPendingWork()

            for i in 1...8 { h.requestInstall("应用\(i)", true) }
            h.waitForPendingWork()
            checkEqual(manifestNames(c.manifests.last ?? "").count, 8, "装满 8 个")

            var refusal: String?
            h.requestInstall("应用9", true) { refusal = $0 }
            h.waitForPendingWork()
            check(refusal != nil, "第 9 个被拒绝并给出了原因")
            checkEqual(manifestNames(c.manifests.last ?? "").count, 8, "清单没有被撑大(设备侧只有 8 个槽,多了会静默截断)")
        }

        print("== 5b. 设备上的商店按确定安装,同样受 8 个上限约束 ==")
        do {
            let c = Collector()
            let h = makeHost("cap-device", c)
            for i in 1...9 { h.register(FakeApp("应用\(i)")) }
            for i in 1...8 { h.requestInstall("应用\(i)", true) }
            h.waitForPendingWork()

            // 进商店,对着唯一剩下的那个按确定 —— 这条路径以前绕过了上限检查,
            // 于是能装进第 9 个,而设备首屏只有 8 个槽,那一个静默消失。
            h.openApp(0xFE)
            h.handleKey(RemoteButton.ok.rawValue, RemoteButtonEvent.click.rawValue)
            h.waitForPendingWork()
            checkEqual(manifestNames(c.manifests.last ?? "").count, 8,
                       "设备端按确定没能突破上限")
            check(c.screens.last?.contains("最多放 8 个") == true,
                  "而且在设备屏幕上说明了原因,不是默默没反应")
        }

        print("== 6. 卸载正在显示的那个应用:要退回首屏 ==")
        do {
            let c = Collector()
            let h = makeHost("uninstall-active", c)
            let panel = FakeApp("面板")
            h.register(panel)
            h.requestInstall("面板", true)
            h.waitForPendingWork()
            h.openApp(0)
            h.waitForPendingWork()

            let before = c.screens.count
            h.requestInstall("面板", false)
            h.waitForPendingWork()
            // 退回首屏之后,应用自己的 requestPush 不应该再推出任何东西。
            panel.requestPush?()
            h.waitForPendingWork()
            checkEqual(c.screens.count, before, "卸载后不再推这个应用的屏(设备已回到自己的首屏)")
        }

        print("== 7. 清单协议:结尾必须是空行,空清单也要发 ==")
        do {
            let c = Collector()
            let h = makeHost("proto", c)
            h.register(FakeApp("面板"))
            h.deviceReady()
            h.waitForPendingWork()
            checkEqual(c.manifests.last, "\n\n",
                       "空清单也以空行收尾(设备靠它区分「没装」和「还没收到」)")

            h.requestInstall("面板", true)
            h.waitForPendingWork()
            // ⚠ 回归:结尾是空行(两个换行),不是一个换行。设备按 ATT 包
            // 收清单,包的最后一个字节是换行只说明这一包断在行尾,不说明
            // 收齐了。iOS 的 ATT MTU 只有 185,一份满清单必然拆成几包 ——
            // 用单换行做哨兵,设备会把前半份当完整清单落盘。
            checkEqual(c.manifests.last, DeviceIcon.fallback.glyph + "\t面板\n\n",
                       "非空清单一行一个 <图标>\\t<名字>,结尾是空行")
            check(c.manifests.allSatisfy { $0.hasSuffix("\n\n") }, "每一份清单都以空行收尾")
        }

        print("== 8. 折行按显示宽度算,不按字符数 ==")
        do {
            // 中文一个字占两个半角宽度,所以一行只能放 13 个;英文能放 26 个。
            // 早先按"字符数 15"折行:英文只用掉半屏,中文又超出去被截断。
            let cn = String(repeating: "中", count: 40)
            let cnLines = DeviceText.wrap(cn, limit: 10)
            check(cnLines.allSatisfy { DeviceText.width($0) <= DeviceText.rowBudget },
                  "中文每行都没超过一行的宽度预算")
            checkEqual(cnLines.first?.count, 13, "一行放得下 13 个中文字")

            let en = "the quick brown fox jumps over the lazy dog again and again"
            let enLines = DeviceText.wrap(en, limit: 10)
            check(enLines.allSatisfy { DeviceText.width($0) <= DeviceText.rowBudget },
                  "英文每行都没超过一行的宽度预算")
            check(enLines.count < cnLines.count,
                  "同样长度的英文比中文占更少的行(说明确实按宽度而不是字符数)")
            // 词边界:不能把单词从中间劈开
            check(enLines.allSatisfy { !$0.hasSuffix("-") && !$0.isEmpty },
                  "英文在词边界断开")
            check(enLines.joined(separator: " ").contains("quick"), "单词没有被劈成两半")

            // 一个超长的、没有空格的 token(路径/URL 很常见)必须硬切,不能死循环
            let longToken = String(repeating: "a", count: 200)
            let cut = DeviceText.wrap(longToken, limit: 5)
            checkEqual(cut.count, 5, "无空格长串按行数上限截断,不会卡住")
            check(cut.allSatisfy { $0.count == DeviceText.rowBudget }, "每行都填满")

            // 换行要保留成段落
            let para = DeviceText.wrap("a\n\nb", limit: 10)
            checkEqual(para, ["a", "", "b"], "空行保留(段落之间的间隔不能丢)")
        }

        print("== 9. 图标:应用可以声明默认值,用户可以在界面上改掉 ==")
        do {
            let c = Collector()
            let h = makeHost("icons", c)
            h.register(FakeApp("带图标的", icon: DeviceIcon.all[1].glyph))
            h.requestInstall("带图标的", true)
            h.waitForPendingWork()
            checkEqual(manifestIcons(c.manifests.last ?? "").first,
                       DeviceIcon.all[1].glyph, "清单里带的是应用声明的默认图标")

            // 用户改一个
            h.setIcon(DeviceIcon.all[5].glyph, for: "带图标的")
            h.waitForPendingWork()
            checkEqual(manifestIcons(c.manifests.last ?? "").first,
                       DeviceIcon.all[5].glyph, "用户选的图标覆盖了默认值")
            checkEqual(manifestNames(c.manifests.last ?? "").first, "带图标的",
                       "名字没被图标挤掉")
            checkEqual(c.lists.last?.first?.icon, DeviceIcon.all[5].glyph,
                       "界面列表里也是新图标")

            // 目录里每个图标都得能反查回来,否则界面上会退回默认图标
            for icon in DeviceIcon.all {
                if DeviceIcon.find(icon.glyph).glyph != icon.glyph {
                    check(false, "图标 \(icon.label) 反查不回来")
                }
            }
            check(true, "目录里 \(DeviceIcon.all.count) 个图标都能按字形反查")
        }

        print("== 10. 标题只能占一行 ==")
        do {
            // 设备上标题和第一行内容只隔 3px,标题一换行就直接盖在内容上。
            var s = Screen()
            s.title = String(repeating: "很长的标题", count: 10)
            s.footer = String(repeating: "提示", count: 30)
            let encoded = s.encode()
            for line in encoded.split(separator: "\n") {
                let body = String(line.dropFirst())      // 去掉 T/L/B/H 前缀
                check(DeviceText.width(body) <= DeviceText.rowBudget,
                      "「\(line.prefix(1))」这一行没超过一行的宽度")
            }
            check(encoded.contains("…"), "截断处有省略号,看得出来是被截了")

            // 正文行同理:设备上行距只有 22,一行换成两行就会盖住下一行。
            var s2 = Screen()
            s2.text(String(repeating: "会话标题很长", count: 8))
            s2.text("/Users/someone/a/very/long/path/that/keeps/going/on/and/on/forever")
            for line in s2.encode().split(separator: "\n") {
                check(DeviceText.width(String(line.dropFirst())) <= DeviceText.rowBudget,
                      "正文行没超过一行的宽度")
            }
        }

        print("")
        print("== 11. 平台边界:本端跑不了的应用要说清楚,不能一片空白 ==")
        do {
            // iOS 上没有 Codex 后端 —— 内核禁止 fork/exec,沙盒里也没有
            // ~/.codex/sessions。注入 nil 模拟。
            let ios = CodexApp(browser: nil)
            check(ios.unavailableReason != nil, "没有后端时,应用自己知道本端跑不了")

            // ⚠ 关键:setActive 之后 render() 必须出说明,不能挂在"正在读取…"。
            // 那一屏永远等不到数据,用户看到的是一个卡死的设备。
            ios.setActive(true)
            let screen = ios.render().encode()
            check(screen.contains("Codex"), "标题还在")
            check(!screen.contains("正在读取"), "不会挂在永远等不到数据的加载屏上")
            check(screen.contains("Mac"), "屏幕上说明白了要连 Mac")

            // 有后端时不该声称跑不了。
            final class FakeBackend: CodexBackend {
                var requests: [UInt8] = []
                func handleRequest(req: UInt8, a: UInt8, b: UInt8) { requests.append(req) }
            }
            let backend = FakeBackend()
            let mac = CodexApp(browser: backend)
            checkEqual(mac.unavailableReason, nil, "有后端时不声称跑不了")
            mac.setActive(true)
            checkEqual(backend.requests, [CmdReq.listWorkspaces], "有后端时照常去要工作区")

            // 跑不了的应用照样能装 —— 设备上点进去看到的是说明,不是空白。
            // 从列表里拿掉是更糟的选择:用户在 Mac 上见过它,到 iPhone 上
            // 凭空消失只会被当成 bug。
            let c = Collector()
            let h = makeHost("boundary", c)
            h.register(ios)
            h.waitForPendingWork()
            let info = c.lists.last?.first { $0.name == "Codex" }
            check(info?.unavailable != nil, "列表里带着原因,界面能显示出来")
        }

        if failures == 0 {
            print("全部通过")
            exit(0)
        } else {
            print("\(failures) 项失败")
            exit(1)
        }
    }
}
