import Foundation
import SwiftUI

// =====================================================================
// 远程应用框架:设备是显示终端,应用逻辑全在这一端。
//
// 一个"应用"就是实现 RemoteApp 的一个类型。它不需要碰蓝牙、不需要懂固件、
// 也不可能把设备写坏 —— 只要回答两个问题:
//
//   1. 现在这一屏长什么样？          → render()
//   2. 用户按了个键,接下来显示什么？  → handleKey()
//
// 设备侧那份固件是通用的、永不更换的,所以:应用在设备上不占空间,想加几个
// 加几个,切换是瞬间的。这跟早先"每个应用编译一份 1.9MB 固件、只能装一个、
// 换一次要重刷两分钟"是根本不同的量级。
//
// 屏幕描述的线格式见 main/remote_ui.h,这里由 Screen 负责生成,应用作者不用
// 手写协议。
// =====================================================================

/// 一屏的内容。用 builder 而不是让应用直接拼协议字符串 —— 拼字符串很容易漏
/// 掉换行或写错前缀,而那类错误在设备上表现为"某一行莫名其妙不显示"。
struct Screen {
    var title: String = ""
    var footer: String = ""

    /// 这一屏要不要收语音输入。
    ///
    /// 麦克风长在设备上,采样和编码的起点在硬件那一侧,没法由这边代劳 ——
    /// 所以应用能做的只是**声明意图**,设备收到 M1 之后自己决定把哪个手势
    /// 接到录音上(当前是长按下键)。录下来的音频走 Codex 那条 AUDIO 通道
    /// 回到这边转写。
    var mic: Bool = false
    /// Realtime push-to-talk mode. The device forwards DOWN press/release
    /// immediately instead of waiting for the long-press threshold.
    var walkie: Bool = false

    private var rows: [String] = []

    mutating func text(_ s: String) {
        // 每一行也压成一行宽度。设备侧虽然有兜底(限宽 + 固定高度 + 省略号),
        // 但让它去截意味着截在哪儿这边不知道;在这里截,末尾的省略号位置是
        // 确定的,而且两端对"一行能放多少"的判断是同一份。
        rows.append("L" + DeviceText.fitOneLine(sanitize(s)))
    }

    /// 进度条。percent 会被夹到 0...100 —— 越界值在设备上会画出超出边框的
    /// 填充条,不如在这里就夹住。
    mutating func bar(_ label: String, percent: Double) {
        let p = Int(max(0, min(100, percent)).rounded())
        rows.append("B\(p)|" + sanitize(label))
    }

    /// 空行,用来分组。
    mutating func spacer() {
        rows.append("L")
    }

    /// 协议是行式的,内容里混进换行会被解析成新的一行、错位显示。
    /// 竖线只在进度条那一行有特殊含义,顺带一并换掉,省得作者踩坑。
    private func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
         .replacingOccurrences(of: "|", with: "/")
    }

    func encode() -> String {
        var out = ""
        // ⚠ 标题必须压成一行。设备上标题和第一行内容只隔 3px,一旦换行,
        // 第二行会直接盖在内容上,两行字叠在一起。
        if !title.isEmpty {
            out += "T" + DeviceText.fitOneLine(title.replacingOccurrences(of: "\n", with: " ")) + "\n"
        }
        for r in rows       { out += r + "\n" }
        if !footer.isEmpty {
            out += "H" + DeviceText.fitOneLine(footer.replacingOccurrences(of: "\n", with: " ")) + "\n"
        }
        // 只在需要时发 M1。不发等于 M0 —— 设备侧结构体是 { 0 } 初始化的,
        // 默认就是不收语音,所以省掉这一行不会有歧义。
        if mic { out += "M1\n" }
        if walkie { out += "W1\n" }
        // 设备靠结尾的换行判断"这一屏收齐了"(一次写入可能被 ATT 拆成多个包),
        // 所以最后一行必须以 \n 结束。上面每行都带了,这里只兜底空屏的情况。
        return out.isEmpty ? "\n" : out
    }
}

/// 一个可以放到设备首屏上的图标。
///
/// ⚠ 为什么一个图标要带两套呈现:
///
/// 设备上画的是 LVGL 的符号字形,码位在 Unicode **私有区**(U+F0xx)。那一段
/// 在 macOS 上没有任何字体覆盖 —— 直接把 `glyph` 显示在配置界面里,用户看到的
/// 是一排方框,根本没法挑。所以界面上用 SF Symbol 预览,发给设备的是 glyph。
///
/// ⚠ 而且不能随便加:设备的 montserrat 字库只内置了**一批特定的** FontAwesome
/// 字形(见 lv_font_montserrat_14.c 开头那行 -r 参数列的码位)。往这里加一个
/// 不在那批里的,设备上画出来是空白 —— 界面上却看着好好的,极难联想到原因。
struct DeviceIcon: Identifiable, Hashable {
    /// 设备上的字形(LVGL 私有区码位的 UTF-8)。这就是发过去的东西。
    let glyph: String
    /// 配置界面上的中文名。
    let label: String
    /// 配置界面上的预览图标。**只**用于 Mac 这一侧,不发给设备。
    let sfSymbol: String

    var id: String { glyph }

    /// 可选的图标。每一项的码位都在 montserrat_14 内置的那批里,已逐个核对。
    static let all: [DeviceIcon] = [
        DeviceIcon(glyph: "\u{F04B}", label: "应用",   sfSymbol: "play.fill"),
        DeviceIcon(glyph: "\u{F01C}", label: "服务器", sfSymbol: "externaldrive"),
        DeviceIcon(glyph: "\u{F11C}", label: "终端",   sfSymbol: "keyboard"),
        DeviceIcon(glyph: "\u{F0C9}", label: "列表",   sfSymbol: "list.bullet"),
        DeviceIcon(glyph: "\u{F015}", label: "主页",   sfSymbol: "house"),
        DeviceIcon(glyph: "\u{F013}", label: "设置",   sfSymbol: "gearshape"),
        DeviceIcon(glyph: "\u{F0F3}", label: "提醒",   sfSymbol: "bell"),
        DeviceIcon(glyph: "\u{F0E0}", label: "消息",   sfSymbol: "envelope"),
        DeviceIcon(glyph: "\u{F158}", label: "文件",   sfSymbol: "doc"),
        DeviceIcon(glyph: "\u{F07B}", label: "目录",   sfSymbol: "folder"),
        DeviceIcon(glyph: "\u{F03E}", label: "图片",   sfSymbol: "photo"),
        DeviceIcon(glyph: "\u{F124}", label: "位置",   sfSymbol: "location"),
        DeviceIcon(glyph: "\u{F1EB}", label: "网络",   sfSymbol: "wifi"),
        DeviceIcon(glyph: "\u{F06E}", label: "监控",   sfSymbol: "eye"),
        DeviceIcon(glyph: "\u{F0C7}", label: "存储",   sfSymbol: "internaldrive"),
        DeviceIcon(glyph: "\u{F0E7}", label: "电源",   sfSymbol: "bolt.fill"),
        DeviceIcon(glyph: "\u{F074}", label: "随机",   sfSymbol: "shuffle"),
        DeviceIcon(glyph: "\u{F079}", label: "循环",   sfSymbol: "repeat"),
        DeviceIcon(glyph: "\u{F304}", label: "编辑",   sfSymbol: "pencil"),
        DeviceIcon(glyph: "\u{F043}", label: "主题",   sfSymbol: "drop"),
    ]

    static let fallback = all[0]

    static func find(_ glyph: String) -> DeviceIcon {
        all.first { $0.glyph == glyph } ?? fallback
    }
}

/// 设备那块屏能放下多少字。
///
/// ⚠ 关键事实:设备用的是 14px 中日韩点阵字库,**全角字约 14px 宽,ASCII 约
/// 7px** —— 一个中文字顶两个英文字符。按"字符数"排版会两头不讨好:一行英文
/// 只用掉半屏,一行中文又超出去被截断成省略号。所以这里一律按**半角宽度**算。
enum DeviceText {
    /// 一行放得下几个半角宽度。正文区宽 212px,按 8px/半角保守估,留一点余量。
    static let rowBudget = 26

    /// 一屏正文最多几行。Screen 硬上限是 12 行,留出标题和底部提示的余量。
    static let bodyRows = 10

    /// 一屏正文总共放得下多少半角宽度。分页的预算就该按这个来 —— 按字符数
    /// 定预算的话,同一个数字对中文太大(排出来超过一屏、后面的被吃掉)、
    /// 对英文又太小(一页只用了半屏,白白多翻几页)。
    static let pageBudget = rowBudget * bodyRows

    static func width(_ ch: Character) -> Int {
        guard let v = ch.unicodeScalars.first?.value else { return 1 }
        switch v {
        case 0x1100...0x115F,          // 谚文字母
             0x2E80...0x303E,          // 中日韩部首、标点
             0x3041...0x33FF,          // 假名、注音、兼容字符
             0x3400...0x4DBF,          // 扩展 A
             0x4E00...0x9FFF,          // 基本汉字
             0xA000...0xA4CF,          // 彝文
             0xAC00...0xD7A3,          // 谚文音节
             0xF900...0xFAFF,          // 兼容汉字
             0xFE30...0xFE6F,          // 竖排标点
             0xFF00...0xFF60,          // 全角字符
             0xFFE0...0xFFE6:
            return 2
        default:
            return 1
        }
    }

    static func width(_ s: String) -> Int {
        s.reduce(0) { $0 + width($1) }
    }

    /// 截成刚好一行。标题和底部提示都只占一行 —— 设备侧也会兜底(限宽 +
    /// 省略号),但那是按像素截的,截在哪儿这边并不知道。在这里按显示宽度先
    /// 截一刀,两端对同一段文本的判断就一致了,而且能保证截掉的是尾巴。
    static func fitOneLine(_ s: String) -> String {
        guard width(s) > rowBudget else { return s }
        var out = ""
        var w = 0
        for ch in s {
            let cw = width(ch)
            if w + cw > rowBudget - 1 { break }   // 留一格给省略号
            out.append(ch)
            w += cw
        }
        return out + "…"
    }

    /// 按显示宽度折行。英文优先在词边界断开 —— 把一个单词从中间劈开在这么窄的
    /// 屏幕上特别难读,而代码和路径又恰恰是最常出现的内容。
    ///
    /// 超过 limit 行的部分会被丢掉,调用方要自己保证内容分页时就已经放得下。
    static func wrap(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        for rawPara in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if out.count >= limit { return out }
            let para = String(rawPara)
            if para.isEmpty { out.append(""); continue }

            var line: [Character] = []
            var w = 0
            var breakAt = -1        // line 里最后一个词边界(空格之后的位置)

            for ch in para {
                let cw = width(ch)
                if w + cw > rowBudget && !line.isEmpty {
                    var head = line
                    var rest: [Character] = []
                    // 词边界离行尾太远就不用了 —— 那样会在行尾留下一大块空白,
                    // 比把长单词断开还难看。
                    if breakAt > 0 && line.count - breakAt <= 12 {
                        rest = Array(line[breakAt...])
                        head = Array(line[..<breakAt])
                    }
                    out.append(String(head).trimmingCharacters(in: .whitespaces))
                    if out.count >= limit { return out }
                    line = rest
                    w = rest.reduce(0) { $0 + width($1) }
                    breakAt = -1
                }
                line.append(ch)
                w += cw
                if ch == " " { breakAt = line.count }
            }
            if !line.isEmpty {
                out.append(String(line).trimmingCharacters(in: .whitespaces))
            }
        }
        return out
    }
}

/// 设备按键。数值必须跟固件 components/bsp/include/bsp_button.h 里的
/// bsp_btn_t / bsp_btn_ev_t **逐个对上**。
///
/// ⚠ 这里曾经写错过:按"上/确定/下"和"单击/长按/双击"的直觉顺序编号,而
/// 固件里实际是"上/下/确定"和"按下/单击/双击/长按/连发"。后果是下键和确定
/// 键互换、双击被当成长按 —— 而且不会有任何报错,只是按下去做的事不对。
/// 改这里之前先去看那个头文件,不要照直觉写。
enum RemoteButton: UInt8 {
    case up = 0
    case down = 1
    case ok = 2
}

enum RemoteButtonEvent: UInt8 {
    case press = 0
    case click = 1
    case double = 2
    case long = 3
    case hold = 4
    case longUp = 5
    case release = 6
}

/// Companion-app settings pages exposed by remote applications.
///
/// Navigation uses a typed route instead of an application's display name.
/// Names are user-facing copy and may change; the route is an app contract.
enum RemoteAppSettingsRoute: String, Hashable {
    case walkieTalkie
    case meal
}

protocol RemoteApp: AnyObject {
    /// 应用列表里显示的名字。
    var name: String { get }
    /// 一句话说明,显示在列表的第二行。
    var detail: String { get }

    /// 这个应用**建议**的图标。用户可以在配套 app 的「应用」页里改掉,改过之后
    /// 以用户选的为准。不实现的话用默认的 ▶。
    var defaultIcon: String { get }

    /// 当前该显示什么。会被反复调用,应当是廉价的、不阻塞的 —— 取数据要放到
    /// 后台去做,拿到之后调 requestPush() 通知框架重新推一屏。
    func render() -> Screen

    /// 用户按了键。返回 true 表示需要立刻重推一屏。
    func handleKey(_ button: RemoteButton, _ event: RemoteButtonEvent) -> Bool

    /// 用户进入/离开这个应用。可以在这里起停定时器、开始/停止拉数据。
    func setActive(_ active: Bool)
    /// The host calls this when the app is installed or removed. Apps that
    /// need background service connectivity should use this instead of keeping
    /// work alive merely because their type is registered.
    func setInstalled(_ installed: Bool)

    /// 框架注入:应用自己有新数据时调它,触发一次推送。
    var requestPush: (() -> Void)? { get set }

    /// 框架注入:提示用户。**前台后台都能调**,这是它跟 requestPush 的
    /// 全部区别 —— requestPush 只有当前显示着的那个应用有资格用
    /// (见 register() 里的 guard),后台应用有事要说本来没有任何通道。
    ///
    /// 设备上表现为屏幕中央一张钉住的卡片,按任意键关闭;息屏时会先点亮。
    /// 应用不需要知道这些,写一行 `notify?("磁盘 92%")` 就完了。
    var notify: ((String) -> Void)? { get set }

    /// 这个应用在**本端**能不能跑。nil = 能跑;非 nil = 跑不了,内容是给
    /// 用户看的原因。
    ///
    /// 这是整套三端复用的分界线所在:能共享到哪一层是**操作系统能力**划的,
    /// 不是框架划的。Codex 要起子进程跑 `codex exec`、要读 ~/.codex/sessions,
    /// 而 iOS 内核禁止 fork/exec、沙盒里也没有那个目录 —— SwiftUI、Catalyst、
    /// "Designed for iPad" 都改变不了这一点。所以按能力分而不是按平台分:
    /// 应用照常出现在列表里,自己说明白为什么在这台机器上跑不了,而不是
    /// 在 iPhone 上凭空消失(用户会以为是 bug)或者点进去一片空白。
    var unavailableReason: String? { get }

    /// Optional settings destination in the companion app.
    var settingsRoute: RemoteAppSettingsRoute? { get }
}

extension RemoteApp {
    // 大多数应用不需要操心图标,给个能用的默认值。
    var defaultIcon: String { DeviceIcon.fallback.glyph }
    // 绝大多数应用三端都能跑。
    var unavailableReason: String? { nil }
    // 大多数应用没有独立设置页。
    var settingsRoute: RemoteAppSettingsRoute? { nil }
    func setInstalled(_ installed: Bool) {}
}

// MARK: - 框架

/// 管理"当前在显示哪个应用",以及应用列表本身。
///
/// 应用列表也是一屏普通的远程界面 —— 设备侧不需要知道"列表"这个概念,
/// 它只是先显示了一屏碰巧长得像列表的内容。
/// 给界面看的一行。RemoteApp 本身是个带状态的对象,不适合直接丢进 SwiftUI 的
/// diff 里;这是它的一份不可变快照。
struct RemoteAppInfo: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let detail: String
    let installed: Bool
    /// 当前生效的图标字形(用户改过就是用户选的,否则是应用建议的那个)。
    let icon: String
    /// 本端跑不了的话,这里是原因;能跑就是 nil。界面据此把这一行标灰
    /// 并把原因显示出来。
    var unavailable: String? = nil
    /// 应用专属设置页。nil 表示列表项没有详情入口。
    var settingsRoute: RemoteAppSettingsRoute? = nil
}

final class RemoteAppHost {
    /// 首屏最多能列出几个已安装应用。
    ///
    /// ⚠ 必须跟固件 main/remote_ui.h 的 REMOTE_UI_MAX_APPS 一致。设备侧收到
    /// 超出的清单会**静默截断**(它只有那么多槽),表现为"在电脑上装了,设备
    /// 首屏却没有" —— 没有任何报错。所以这边先挡住并明确告诉用户,而不是
    /// 让它悄悄消失。
    static let maxInstalled = 8

    private var apps: [RemoteApp] = []
    /// 已安装的应用名(顺序即首屏顺序)。持久化在本机 —— 这是"用户装了什么"
    /// 这个决定,属于这一端;设备只是缓存一份用来画首屏。
    private var installed: [String] = []
    /// 用户在界面上改过的图标。没改过的应用不在这里,用它自己声明的默认值。
    private var iconOverrides: [String: String] = [:]
    private var current: RemoteApp?          // nil = 不在任何应用里
    private var inStore = false              // 正停在应用商店那一屏
    private var storeSelection = 0
    /// 商店里要给用户看的一句话(比如装满了)。显示过一次就清掉。
    private var storeNotice: String?
    private var deviceActive = false

    /// 列表变化(装了/卸了/注册了新应用)时被调一次,给界面刷新用。
    /// **在 host 自己的队列上调**,界面那边要自己 hop 回主线程。
    ///
    /// ⚠ 用 setListObserver() 设置,不要直接赋值。两个原因:
    ///
    /// 1. 竞态。register() 的函数体整个跑在 host 队列上,里面会发一次
    ///    publishList()。如果观察者是之后在主线程赋的,那几次发布读到的
    ///    就是 nil —— 全部丢掉。而列表只在 register / 装卸时发布,错过了
    ///    **再没有第二次机会**:界面会永远停在"还没有可用的应用",而设备端
    ///    的清单其实是正常的。
    /// 2. 数据竞争。闭包是(函数指针 + 上下文)两个字加 ARC,主线程写、host
    ///    队列读,没有同步就是真正的 UB。
    private var onListChanged: (([RemoteAppInfo]) -> Void)?

    /// 设置列表观察者,并立刻补发一次当前状态。
    func setListObserver(_ fn: @escaping ([RemoteAppInfo]) -> Void) {
        queue.async {
            self.onListChanged = fn
            // 补发:设置之前 register() 已经发过的那几次,观察者是收不到的。
            fn(self.snapshot())
        }
    }

    private let send: (String) -> Void
    private let sendManifest: (String) -> Void
    /// 把一条通知下发到设备(走 cmd.notify)。
    private let sendNotify: (String) -> Void
    /// 上一条通知的内容和时间,用来压掉重复。
    ///
    /// 应用的定时器是几秒一轮的,"磁盘 92%" 这种条件一旦成立就会每轮都触发 ——
    /// 不压的话就是每秒一次 BLE 写。历史上 NimBLE 的 mbuf 池被连续 notify
    /// 打爆过(rc=6 / BLE_HS_ENOMEM),同样的内容没有必要重发。
    private var lastNotifyText = ""
    private var lastNotifyAt = Date.distantPast
    private let queue = DispatchQueue(label: "com.folotoy.codexrelay.remoteapps")

    /// 单设备时代的键。新键在它后面加设备后缀;第一次用某台设备时从这里
    /// 播种,老用户升级上来首屏不会突然变空。
    private static let legacyInstalledKey = "remote.installed"
    private static let legacyIconsKey = "remote.icons"
    /// 这一台自己的键。
    ///
    /// ⚠ 清单必须**每台一份**。设备端 REMOTE_EVT_OPEN 报的是下标,而那个
    /// 下标是设备用自己缓存的那份清单算出来的 —— 两台共用一份逻辑清单、
    /// 却各自缓存的话,下标含义就可能对不上,点开的是另一个应用。
    /// 每台各一份之后,发出去的和算下标用的是同一份,结构上不会错位。
    /// 首屏槽位上限(maxInstalled,来自固件的 REMOTE_UI_MAX_APPS)也因此
    /// 是按那一台自己的数量算的。
    private let installedKey: String
    private let iconsKey: String

    /// 已安装清单存哪儿。默认是 .standard;**测试传一个临时 suite 进来**,
    /// 否则宿主机测试会读写用户真实的安装状态 —— 跑一次测试就把人家装的应用
    /// 全清了,而且是静默的。
    private let defaults: UserDefaults

    /// 调试通道的轮询在测试里没有意义(还会在 /tmp 上留文件),默认开,
    /// 测试关掉。
    init(send: @escaping (String) -> Void,
         sendManifest: @escaping (String) -> Void,
         sendNotify: @escaping (String) -> Void = { _ in },
         deviceKey: String? = nil,
         defaults: UserDefaults = .standard,
         enableDebugChannel: Bool = true) {
        self.send = send
        self.sendManifest = sendManifest
        self.sendNotify = sendNotify
        self.defaults = defaults
        let suffix = deviceKey.map { "." + $0 } ?? ""
        self.installedKey = Self.legacyInstalledKey + suffix
        self.iconsKey = Self.legacyIconsKey + suffix
        // 这一台还没有自己的清单就从单设备时代那份播种 —— 升级上来的用户
        // 第一次连上设备,首屏应该还是他原来那几个应用,不是一片空白。
        self.installed = defaults.stringArray(forKey: installedKey)
            ?? defaults.stringArray(forKey: Self.legacyInstalledKey) ?? []
        self.iconOverrides = (defaults.dictionary(forKey: iconsKey) as? [String: String])
            ?? (defaults.dictionary(forKey: Self.legacyIconsKey) as? [String: String]) ?? [:]
        if enableDebugChannel { pollDebugTrigger() }
    }

    /// 测试用:把排队在内部串行队列上的活儿全部做完再返回。
    /// 生产代码不该调它 —— 界面那边靠 onListChanged 回调,不需要同步等待。
    func waitForPendingWork() {
        queue.sync { }
    }

    func register(_ app: RemoteApp) {
        queue.async {
            app.requestPush = { [weak self, weak app] in
                guard let self = self else { return }
                self.queue.async {
                    // 只有正在前台显示的那个应用才有资格推屏 —— 后台应用的
                    // 定时器还在跑,不拦住的话会把用户正在看的界面覆盖掉。
                    guard self.current === app, self.deviceActive else { return }
                    self.push()
                }
            }
            app.notify = { [weak self, weak app] text in
                guard let self = self, let app = app else { return }
                self.queue.async { self.deliverNotify(text, from: app) }
            }
            self.apps.append(app)
            app.setInstalled(self.installed.contains(app.name))
            // ⚠ 这里绝对不能推清单。注册只是说"本机能跑这个应用",不是
            // 安装事件。启动时应用是一个一个注册的,每注册一次就推一次的
            // 话,设备会先收到几份残缺清单;而全新安装(installed 还是空
            // 的)推过去的是空清单,设备会把 NVS 里缓存的首屏直接清掉 ——
            // 用户什么都没做,首屏就空了。真正该推的时机有三个,都已经有
            // 了:连上设备(deviceReady)、装卸(applyInstalled)、换图标。
            self.publishList()
        }
    }

    /// 当前所有应用及其安装状态。已安装的排在前面并保持首屏顺序,未安装的跟在
    /// 后面 —— 跟设备上看到的顺序一致,免得两边对不上号。
    private func snapshot() -> [RemoteAppInfo] {
        (installedApps.map { ($0, true) } + availableApps.map { ($0, false) }).map { app, yes in
            RemoteAppInfo(name: app.name, detail: app.detail, installed: yes,
                          icon: icon(for: app), unavailable: app.unavailableReason,
                          settingsRoute: app.settingsRoute)
        }
    }

    private func publishList() { onListChanged?(snapshot()) }

    /// **必须在 queue 上调。**
    ///
    /// `from` 传 nil 表示"不是某个应用发的"(调试通道),跳过安装检查。
    private func deliverNotify(_ text: String, from app: RemoteApp?) {
        // 只做清理,**不按单行截断** —— 设备侧卡片是 LV_LABEL_LONG_WRAP,
        // 有四行可用,自己会按宽度折行。用 fitOneLine 会把它砍成 26 个半角,
        // 白白浪费另外三行。换行符要去掉:它会打乱设备侧的折行。
        let body = text.replacingOccurrences(of: "\n", with: " ")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        // ⚠ 只有**已安装**的应用能发通知。
        //
        // 所有应用在 AppCore 里是无条件 register 的 —— installed 只是
        // UserDefaults 里的一份名字列表,register 跟"装没装"完全无关。
        // 不加这道门的话,一个用户从来没装过、首屏上根本看不到的应用,
        // 照样能往设备上弹卡片。用户会完全不知道这是谁发的、也没法关掉它,
        // 因为那个应用在他的首屏上压根不存在。
        if let app = app, !installed.contains(app.name) {
            log("[notify] \(app.name) 没有安装,丢弃")
            return
        }

        // 同一条内容 30 秒内不重发。见 lastNotifyText 的说明。
        if body == lastNotifyText, Date().timeIntervalSince(lastNotifyAt) < 30 { return }
        lastNotifyText = body
        lastNotifyAt = Date()

        // ⚠ 没连设备时**不排队**。三小时后补送一条"磁盘满了"比不送更糟 ——
        // 通知是有时效的,而排队会把它变成一条谎报。应用自己还在轮询,
        // 条件仍然成立的话下一轮会再发一次,那时才是真的。
        guard deviceLinked else {
            log("[notify] 设备没连着,丢弃:\(body)")
            return
        }
        // 带上来源:设备上同时只显示一条卡片,不写清楚是谁发的,用户
        // 只能靠猜。设备侧卡片有四行可用,放得下。
        let full = app.map { "\($0.name) · \(body)" } ?? body
        log("[notify] \(full)")
        sendNotify(full)
    }

    /// 设备连没连着。由入口接 BLERelay.onLinkChange 填。
    private var deviceLinked = false

    func setDeviceLinked(_ linked: Bool) {
        queue.async { self.deviceLinked = linked }
    }

    /// 能不能再装一个。返回拒绝原因,nil 表示可以。
    /// **必须在 queue 上调**。设备端商店和电脑端界面共用这一份判断 ——
    /// 两处各写一遍的话迟早会有一处忘了改。
    private func installRefusal(_ name: String) -> String? {
        guard !installed.contains(name) else { return nil }   // 已经装了,幂等
        guard installed.count >= Self.maxInstalled else { return nil }
        return "最多放 \(Self.maxInstalled) 个,先卸掉一个"
    }

    /// 界面调用:装 / 卸一个应用。completion 的参数是失败原因,nil 表示成功。
    func requestInstall(_ name: String, _ yes: Bool,
                        completion: ((String?) -> Void)? = nil) {
        queue.async {
            if yes, let refusal = self.installRefusal(name) {
                completion?("设备首屏" + refusal)
                return
            }
            self.applyInstalled(name, yes)
            // 卸掉的正好是当前正在显示的那个:退回首屏。不然设备会停在一个
            // 已经不存在的应用界面上,按键也没人处理。
            if !yes, let cur = self.current, cur.name == name {
                cur.setActive(false)
                self.current = nil
                self.deviceActive = false
            }
            completion?(nil)
        }
    }

    // MARK: 安装状态

    /// 某个应用当前该用哪个图标。用户改过就听用户的。
    private func icon(for app: RemoteApp) -> String {
        iconOverrides[app.name] ?? app.defaultIcon
    }

    /// 界面调用:给某个应用换个图标。会立刻重推清单,设备上当场就变。
    func setIcon(_ glyph: String, for name: String) {
        queue.async {
            self.iconOverrides[name] = glyph
            self.defaults.set(self.iconOverrides, forKey: self.iconsKey)
            self.pushManifest()
            self.publishList()
        }
    }

    private var installedApps: [RemoteApp] {
        // 按 installed 里记的顺序返回,过滤掉已经不存在的(比如这一版
        // 把某个应用去掉了)—— 否则首屏会列出一个点进去什么都没有的名字。
        installed.compactMap { name in apps.first { $0.name == name } }
    }

    private var availableApps: [RemoteApp] {
        apps.filter { !installed.contains($0.name) }
    }

    /// 把已安装清单推给设备。设备缓存进 NVS,断开电脑时首屏照常能列出来。
    private func pushManifest() {
        // 一行一个应用,格式是 "<图标>\t<名字>"。用制表符分隔而不是别的字符:
        // 名字是用户起的,空格和常见标点都可能出现,制表符不会。
        let lines = installedApps.map { icon(for: $0) + "\t" + $0.name }
        // 末尾必须有换行:设备靠它判断这一批收齐了。空清单也要发一个空行,
        // 否则设备无从知道"现在一个都没装"跟"还没收到过清单"的区别。
        // 结尾是空行(连着两个换行)而不是一个换行:设备按 ATT 包收,一个包
        // 的最后一个字节是换行只能说明"这一包正好断在行尾",不能说明清单
        // 收齐了。清单一旦超过单包容量(iOS 的 ATT MTU 只有 185,必然超),
        // 用单换行做哨兵会让设备把前半份当成完整清单落盘。
        // 空清单是 "\n\n"(一个空的内容行 + 哨兵空行),不是 "\n" —— 设备
        // 要看到两个换行才算收齐,只发一个字节它会一直等下去。解析两侧都
        // 跳过空行,所以多出来的这一行不会变成一个空应用。
        let text = lines.joined(separator: "\n") + "\n\n"
        log("[remote] 推送清单:\(lines.count) 个已安装应用")
        sendManifest(text)
    }

    private func applyInstalled(_ name: String, _ yes: Bool) {
        if yes {
            guard !installed.contains(name) else { return }
            installed.append(name)
        } else {
            installed.removeAll { $0 == name }
        }
        defaults.set(installed, forKey: installedKey)
        apps.first { $0.name == name }?.setInstalled(yes)
        pushManifest()
        publishList()
    }

    // MARK: 设备事件

    func setDeviceActive(_ active: Bool) {
        queue.async {
            self.deviceActive = active
            if active {
                self.push()
            } else {
                self.current?.setActive(false)
            }
        }
    }

    /// 重推一份清单,**不动**当前会话。
    ///
    /// 给"又一台设备上线了、它需要首屏"这种情况用:deviceReady() 会把当前
    /// 会话重置回首屏,拿它来伺候第二台设备会把正在用第一台的人踢出应用。
    func refreshManifest() {
        queue.async { self.pushManifest() }
    }

    /// 设备就绪(订阅完成)。推一遍清单,让它的首屏立刻是最新的。
    /// 不把 deviceActive 置真 —— 设备刚连上时多半还停在首屏,真进了某个
    /// 应用会另外发 ACTIVE 事件。
    func deviceReady(active: Bool = false, appIndex: UInt8 = 0) {
        queue.async {
            self.current?.setActive(false)
            self.current = nil
            self.inStore = false
            self.deviceActive = false
            self.pushManifest()
            guard active else { return }
            if appIndex == 0xFE {
                self.inStore = true
                self.deviceActive = true
                self.push()
                return
            }
            let list = self.installedApps
            guard Int(appIndex) < list.count else { return }
            self.current = list[Int(appIndex)]
            self.current?.setActive(true)
            self.deviceActive = true
            self.push()
        }
    }

    /// 用户在设备首屏选了第 index 项。0xFE = 应用商店。
    func openApp(_ index: UInt8) {
        queue.async {
            self.current?.setActive(false)
            if index == 0xFE {
                self.inStore = true
                self.current = nil
                self.storeSelection = 0
            } else {
                let list = self.installedApps
                guard Int(index) < list.count else {
                    log("[remote] 首屏下标越界: \(index),清单可能不同步")
                    return
                }
                self.inStore = false
                self.current = list[Int(index)]
                self.current?.setActive(true)
            }
            self.deviceActive = true
            self.push()
        }
    }

    func handleKey(_ raw: UInt8, _ rawEvent: UInt8) {
        queue.async {
            guard let btn = RemoteButton(rawValue: raw),
                  let ev = RemoteButtonEvent(rawValue: rawEvent) else { return }

            if self.inStore {
                self.handleStoreKey(btn, ev)
                return
            }
            guard let app = self.current else { return }
            if app.handleKey(btn, ev) { self.push() }
        }
    }

    // MARK: 应用商店

    private func handleStoreKey(_ btn: RemoteButton, _ ev: RemoteButtonEvent) {
        let list = availableApps
        switch (btn, ev) {
        case (.up, .click), (.up, .hold):
            if !list.isEmpty { storeSelection = max(0, storeSelection - 1) }
            push()
        case (.down, .click), (.down, .hold):
            if !list.isEmpty { storeSelection = min(list.count - 1, storeSelection + 1) }
            push()
        case (.ok, .click):
            guard storeSelection < list.count else { return }
            let app = list[storeSelection]
            // ⚠ 上限检查不能只做在电脑那一侧的界面里。设备上的商店按确定
            // 走的是同一条安装路径,绕过去的话可以装到第 9 个 —— 而设备首屏
            // 只有 8 个槽,多出来的那个**静默消失**,用户会以为没装上。
            if let refusal = installRefusal(app.name) {
                storeNotice = refusal
                push()
                return
            }
            applyInstalled(app.name, true)
            log("[remote] 已安装「\(app.name)」")
            // 装完这一项就从可装列表里消失了,选中项要跟着收回来,否则会
            // 指到一个不存在的下标上。
            let remaining = availableApps.count
            if storeSelection >= remaining { storeSelection = max(0, remaining - 1) }
            push()
        default:
            break
        }
    }

    private func storeScreen() -> Screen {
        var s = Screen()
        s.title = "应用商店"
        if let notice = storeNotice {
            // 只显示一次。留着的话用户上下翻的时候它会一直挂在那儿,
            // 看不出来是刚才那次操作的结果还是一直如此。
            storeNotice = nil
            s.text("⚠ " + notice)
            s.spacer()
        }
        let list = availableApps
        if list.isEmpty {
            s.text(apps.isEmpty ? "还没有可用的应用" : "已经全部安装")
            s.footer = "长按确定返回"
            return s
        }
        for (i, app) in list.enumerated() {
            s.text((i == storeSelection ? "> " : "  ") + app.name)
            s.text("   " + app.detail)
        }
        s.footer = "上/下选择  确定安装"
        return s
    }

    private func push() {
        let screen: Screen
        if inStore {
            screen = storeScreen()
        } else if let app = current {
            screen = app.render()
        } else {
            // 设备停在自己的首屏,这边没有要推的东西。
            return
        }
        let text = screen.encode()
        let lines = text.split(separator: "\n").count
        log("[remote] 推屏「\(screen.title)」\(lines) 行 \(text.utf8.count) 字节")
        send(text)
    }

    // MARK: 调试通道

    /// 往 /tmp/folo_remote_sim 写一行命令,模拟设备那边的动作:
    ///   open <n>       首屏选第 n 项(254 = 应用商店)
    ///   key <btn> <ev> 一次按键,btn 0=上 1=下 2=确定,ev 1=单击 2=双击
    ///   idle           离开远程界面
    ///   dump           把当前这一屏完整打进日志
    ///   installed      打印当前已安装列表
    ///   notify <文本>  发一条通知到设备(走跟应用完全相同的那条路)
    private static let simPath = "/tmp/folo_remote_sim"

    private func pollDebugTrigger() {
        // ⚠ 只在 macOS 上跑。这是个开发期调试钩子:在终端里往 /tmp 写个文件
        // 来驱动它。iOS 沙盒里既写不进那个路径、也没有终端能写,轮询永远
        // 命中不了,只剩每秒一次的空唤醒 —— 手机上那是白耗电。
        #if os(macOS)
        if let text = try? String(contentsOfFile: Self.simPath, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: Self.simPath)
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ").map(String.init)
                guard let cmd = parts.first else { continue }
                switch cmd {
                case "idle": log("[remote] 模拟:离开远程页"); setDeviceActive(false)
                case "dump": queue.async { self.dumpCurrent() }
                case "notify":
                    // 调试用:`echo "notify 磁盘 92%" > /tmp/folo_remote_sim`
                    // 走的是跟应用完全相同的那条路(deliverNotify),
                    // 所以验证它就等于验证了应用发通知。
                    let body = line.dropFirst("notify".count).trimmingCharacters(in: .whitespaces)
                    queue.async { self.deliverNotify(String(body), from: nil) }
                case "installed":
                    queue.async { log("[remote] 已安装: \(self.installed)") }
                case "open" where parts.count >= 2:
                    if let n = UInt8(parts[1]) {
                        log("[remote] 模拟:首屏选中第 \(n) 项")
                        openApp(n)
                    }
                case "key" where parts.count >= 3:
                    if let b = UInt8(parts[1]), let e = UInt8(parts[2]) {
                        log("[remote] 模拟按键 btn=\(b) ev=\(e)")
                        handleKey(b, e)
                    }
                default: break
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pollDebugTrigger()
        }
        #endif
    }

    private func dumpCurrent() {
        let screen: Screen
        if inStore { screen = storeScreen() }
        else if let app = current { screen = app.render() }
        else {
            log("[remote] ── 当前在设备首屏(内容由设备自己画)──\n已安装: \(installed)")
            return
        }
        log("[remote] ── 当前屏幕 ──\n" + screen.encode())
    }
}

// =====================================================================
// 应用管理界面。
//
// 设备上也有一个"应用商店"页(三个按键就能装),这一页是它在电脑上的对应物,
// 多做一件设备上做不了的事:**卸载**。
//
// 为什么卸载只在这里:设备端的商店按用户的要求只列"还没装的"—— 装过的就不
// 再出现。那样设计读起来很顺,但也意味着设备上没有任何地方能选中一个已装的
// 应用把它拿掉。与其为此在设备上再加一层交互,不如放在本来就该管这些的地方。
// =====================================================================

final class RemoteAppsModel: ObservableObject {
    @Published var apps: [RemoteAppInfo] = []
    @Published var notice: String = ""

    /// 设备连没连上。由入口接 BLERelay.onLinkChange 填。
    ///
    /// 「应用」页原来完全不知道这件事,于是不管连没连都照样显示"已安装" ——
    /// 而那个状态其实只是本机 UserDefaults 里的一份名字列表(installedKey),
    /// 跟设备上到底有什么没有必然关系。没连上时它就是个**无法验证的断言**,
    /// 尤其两端各存各的之后,两边还会互相矛盾。
    /// 不知道就别说:没连上时这一页不展示任何设备状态。
    @Published var isConnected = false {
        didSet {
            // 断开时把提示清掉。否则"设备首屏最多放 8 个,先卸掉一个"这类
            // 告警会一直挂在"设备未连接"下面,抱怨一个此刻根本没有按钮的
            // 操作,用户分不清那是残留还是当前状态。
            // (DeviceConfigModel.applyLinkChange 里对 statusText/wifiState
            //  一直是这么做的,这边之前漏了。)
            if !isConnected { notice = "" }
        }
    }

    private let host: RemoteAppHost

    init(host: RemoteAppHost) {
        self.host = host
        host.setListObserver { [weak self] list in
            // host 在自己的串行队列上回调,@Published 只能在主线程改。
            DispatchQueue.main.async { self?.apps = list }
        }
    }

    var installedCount: Int { apps.filter { $0.installed }.count }

    func setIcon(_ glyph: String, for name: String) {
        host.setIcon(glyph, for: name)
    }

    func toggle(_ app: RemoteAppInfo) {
        host.requestInstall(app.name, !app.installed) { [weak self] err in
            DispatchQueue.main.async {
                self?.notice = err ?? ""
            }
        }
    }
}

struct RemoteAppsView: View {
    @ObservedObject var model: RemoteAppsModel
    /// 打开某个应用的设置页。由外层的 NavigationStack 提供 —— 见 RelayApp
    /// 里的说明:List 行里的 NavigationLink 在 macOS 上抢不到点击。
    var onOpenSettings: ((RemoteAppSettingsRoute) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("应用").font(.title2).bold()
                Spacer()
                if model.isConnected {
                    Text("已装 \(model.installedCount)/\(RemoteAppHost.maxInstalled)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("设备未连接", systemImage: "bolt.horizontal.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("装上的应用会出现在设备首屏。应用逻辑全部跑在这台电脑上,设备只负责显示 —— 所以装/卸是即时的,不需要重刷固件。")
                .font(.caption).foregroundStyle(.secondary)
            if model.isConnected {
                Text("左边的图标可以换,改完设备上立刻生效。")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("没连上设备,所以不显示安装状态 —— 那要问过设备才算数。下面是本机能跑的应用。")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if !model.notice.isEmpty {
                Text(model.notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if model.apps.isEmpty {
                Spacer()
                Text("还没有可用的应用。").foregroundStyle(.secondary)
                Spacer()
            } else {
                List(model.apps) { app in
                    HStack {
                        // 图标下拉。界面上显示的是 SF Symbol 预览 —— 设备上那套
                        // 字形在私有区,macOS 没有字体能画,直接显示是方框。
                        Menu {
                            ForEach(DeviceIcon.all) { icon in
                                Button {
                                    model.setIcon(icon.glyph, for: app.name)
                                } label: {
                                    Label(icon.label, systemImage: icon.sfSymbol)
                                }
                            }
                        } label: {
                            Image(systemName: DeviceIcon.find(app.icon).sfSymbol)
                                .frame(width: 20)
                        }
                        // .borderlessButton 只有 macOS 有 —— 这是全工程唯一
                        // 一处 iOS 编译不过的地方(其余的平台差异都是"编得过
                        // 但行为不对",不是缺 API)。iOS 上 Menu 的默认样式
                        // 本来就合适,不用替代品。
                        #if os(macOS)
                        .menuStyle(.borderlessButton)
                        #endif
                        .frame(width: 44)
                        .help("换一个在设备上显示的图标")

                        appSummary(app)
                        Spacer()
                        if let route = app.settingsRoute {
                            Button {
                                onOpenSettings?(route)
                            } label: {
                                Image(systemName: "gearshape")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("打开\(app.name)设置")
                            .accessibilityLabel("\(app.name)，打开设置")
                        }
                        // ⚠ 按钮的文字本身就是状态("卸载"=装了、"安装"=没装),
                        // 所以要真的不显示状态,按钮得跟着一起收起来 —— 只藏
                        // "已安装"那三个字是藏不住的。
                        //
                        // ⚠ 代价是真的,别低估:**离线装卸本来是能用的**,而且
                        // 不依赖 BLERelay 的 pendingManifest。链路是
                        //   requestInstall → applyInstalled 写 UserDefaults(:514)
                        //   → 设备下次订阅完成时 deviceReady() 全量 pushManifest()
                        // 这是一次持久化的本地决定 + 一次连上必然发生的补推,
                        // tests/test_remote_apps.swift 里"连上设备推一次"那条
                        // 断言正是在守它。收起按钮 = 把这条路堵死,用户想装应用
                        // 必须先把设备掏出来连上。
                        //
                        // 之所以还是这么做,是因为"显示一个问不到设备就无法证实的
                        // 状态"被判定为更糟。如果以后觉得离线装卸更重要,正确的
                        // 做法不是把按钮放回来,而是**改措辞** —— 连上时说
                        // "已安装"(设备确认过),没连时说"已选"(本机的选择,
                        // 连上生效),两者都是真话。
                        if model.isConnected {
                            if app.installed {
                                Text("已安装").font(.caption).foregroundStyle(.green)
                                Button("卸载") { model.toggle(app) }
                            } else {
                                Button("安装") { model.toggle(app) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        // 只有 macOS 需要:窗口是用户可拉的,给个不至于挤成一团的下限。
        // iPhone 上窗口就是屏幕,写死 460 会让内容横向溢出(iPhone
        // 竖屏逻辑宽度只有 390pt)。
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }

    @ViewBuilder
    private func appSummary(_ app: RemoteAppInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(app.name)
            Text(app.detail).font(.caption).foregroundStyle(.secondary)
            // 本端跑不了的应用照常列出来,但把原因说清楚。
            // 直接从列表里拿掉是更糟的选择:用户在 Mac 上
            // 见过 Codex,到 iPhone 上它凭空消失,只会以为
            // 是 bug。装上去也没问题 —— 设备上点进去会看到
            // 同一句说明,不是一片空白。
            if let why = app.unavailable {
                Label(why, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}
