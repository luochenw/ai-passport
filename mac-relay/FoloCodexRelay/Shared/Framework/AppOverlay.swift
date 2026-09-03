import Foundation

// =====================================================================
// 覆盖层:内容之前挡着的那一屏
//
// 每个应用都会遇到"现在还画不出正经内容"的情况,而且理由就那么几种:
// 这一端根本跑不了、还没配置、正在加载、出了个错要用户确认。以前每个应用
// 各写一遍,写法还都不一样 —— Codex 有完整的三层,吃饭是两个裸 guard,
// 看板只有一句"未配置"。同一件事在三个应用里长三个样,用户看到的措辞和
// 按键行为也就跟着不一致。
//
// 收在这里之后:应用只回答"有没有挡着的理由",怎么画、footer 写什么、
// 哪个盖哪个,由框架统一决定。
// =====================================================================

/// 挡在应用内容前面的一层。`nil` 表示没有,正常画内容。
enum AppOverlay {
    /// 这一端跑不了(比如 Codex 要起子进程,iOS 做不到)。**永久**,
    /// 不是等一等就好 —— 所以要把原因说清楚,并给出可行动的下一步。
    case unavailable(reason: String, hint: String?)

    /// 这台设备没装这个应用。设备的首屏清单是缓存的,可能比这边旧 ——
    /// 从一份过期的清单点进来,得说清楚,而不是画一屏空的正经内容。
    case notInstalled(String)

    /// 缺配置。`path` 是配置文件该放的位置 —— 用户看到"未配置"三个字是
    /// 没法行动的,得告诉他文件放哪儿。
    case notConfigured(what: String, path: String)

    /// 过场。别让用户对着一动不动的屏幕猜。
    case loading(String)

    /// 钉住的错误,按任意键清掉。
    ///
    /// ⚠ 清错误的那一下**只**清错误,不能顺带触发翻页/选中 ——
    /// 否则用户为了消掉提示按的那一下会把界面也带走,他就看不清刚才
    /// 到底出了什么事。见 `consumeKey`。
    case error(String)
}

extension AppOverlay {
    /// 画成一屏。`title` 是应用自己的标题,错误那一层会换成"出错了"。
    func render(title: String) -> Screen {
        var s = Screen()
        switch self {
        case let .unavailable(reason, hint):
            s.title = title
            s.spacer()
            for line in DeviceText.wrap(reason, limit: 6) { s.text(line) }
            if let hint {
                s.spacer()
                s.text(hint)
            }
            s.footer = "双击确定返回"

        case let .notInstalled(name):
            s.title = name
            s.spacer()
            s.text("这台设备还没装这个应用")
            s.footer = "在伴侣端的「应用」页安装"

        case let .notConfigured(what, path):
            s.title = title
            s.spacer()
            s.text(what)
            s.spacer()
            // 路径大概率超过一行,按行拆 —— 截断成"~/.folotoy/apps/das…"
            // 对用户毫无用处。
            for line in DeviceText.wrap(path, limit: 3) { s.text(line) }
            s.footer = "配置好之后重新进入"

        case let .loading(what):
            s.title = title
            s.spacer()
            s.text("  " + what)
            s.footer = "请稍候"

        case let .error(message):
            s.title = "出错了"
            for line in DeviceText.wrap(message, limit: 8) { s.text(line) }
            s.footer = "按任意键继续"
        }
        return s
    }

    /// 这一层会不会吃掉按键。
    ///
    /// 只有钉住的错误会 —— 加载中按键应当照常传下去(用户可能想返回),
    /// 而"跑不了""没配置"那两层本来也没有可按的东西。
    var swallowsKeys: Bool {
        if case .error = self { return true }
        return false
    }
}

/// 帮应用管住"钉住的错误"这一小段状态机。
///
/// 单独抽出来是因为它有一条容易漏的规则:清错误的那一下按键必须被**吃掉**。
/// 三个应用里已经有两个漏过 —— 用户按一下消提示,顺带翻了一页,回头问
/// "刚才那个错是什么"。
struct PinnedError {
    private var message: String?

    var overlay: AppOverlay? {
        message.map { .error($0) }
    }

    mutating func set(_ message: String) { self.message = message }
    mutating func clear() { message = nil }

    /// 返回 true 表示这一下按键被错误层吃掉了,应用不要再处理。
    mutating func consumeKey() -> Bool {
        guard message != nil else { return false }
        message = nil
        return true
    }
}
