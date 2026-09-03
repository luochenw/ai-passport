import Foundation

// =====================================================================
// Codex 会话浏览器,作为一个独立的远程应用。
//
// 跟另一个方案的取舍
// ──────────────────
// 本来可以从零写一个:自己扫 ~/.codex/sessions、自己
// 分页、自己判断哪个会话是活的。没那么做,是因为 CodexBrowserModel 里那套
// 逻辑不是"读几个文件"那么简单 —— 它要按 cwd 归并工作区、按 mtime 排序、
// 跟踪文件增长做增量刷新、从 rollout 文件里挖出 session_id 和**最后一轮实际
// 用的模型**(会话中途可以换模型,取第一条是错的)。重写一份必然会漏掉其中
// 某些,而且漏掉的地方不会报错,只会在某些会话上表现得不对。
//
// 所以这里是个**适配器**:浏览逻辑照旧归 CodexBrowserModel,这个类只做两件事
//   1. 把按键翻译成它认识的请求(REQ_LIST_WORKSPACES / REQ_OPEN_SESSION / …);
//   2. 把它吐出来的条目攒成一屏,用 Screen 画出来。
//
// 语音为什么还在设备上
// ────────────────────
// 别的都能搬到电脑上,唯独麦克风不行 —— 采样和编码的起点在硬件那一侧。所以
// 阅读界面会把 Screen.mic 置真(协议里的 M1),设备收到之后自己把"长按下键"
// 接到录音上,音频经 Codex 那条 AUDIO 通道流回来,由 VoiceInputPipeline 转写
// 并发给当前正在看的那个会话。
// =====================================================================

/// Codex 浏览逻辑的后端。
///
/// 抽成协议是为了让 CodexApp 本身留在 Shared/ 里 —— 它的按键处理、分屏、
/// 列表攒批、加载过场全是三端通用的界面逻辑,不该被"数据从哪儿来"绑死在
/// macOS 上。唯一不通用的是实现:macOS 上是 CodexBrowserModel(起子进程跑
/// `codex exec`、扫 ~/.codex/sessions),iOS 上没有对应实现,注入 nil。
protocol CodexBackend: AnyObject {
    func handleRequest(req: UInt8, a: UInt8, b: UInt8)
}

final class CodexCapability: AppCapability {
    static let id = "codex"
    /// 只留给覆盖层当标题。名字、说明、图标在清单里。
    let name = "Codex"
    let detail = "浏览会话,长按下键说话"
    // Codex 是个终端里的东西,用键盘图标。
    let defaultIcon = DeviceIcon.find("\u{F11C}").glyph
    var onChange: (() -> Void)?
    var notify: ((String) -> Void)?

    private enum Mode {
        case workspaces
        case sessions
        case reading
    }

    // CodexBrowserModel 在它自己的 modelQueue 上回调,而 render()/handleKey()
    // 跑在 RemoteAppHost 的队列上 —— 两个队列都会碰下面这些状态,必须加锁。
    private let lock = NSLock()

    private var mode: Mode = .workspaces
    private var workspaces: [String] = []
    private var sessions: [String] = []
    private var wsSel = 0
    private var sessSel = 0
    private var pageText = ""
    private var pageIndex = 0
    private var pageTotal = 0
    private var pageIsUser = false
    private var status: String?
    /// 正在等对面回数据。设成非 nil 时 render() 直接出一屏过场,盖住一切。
    ///
    /// 没有这个的话,按下确定到内容回来之间屏幕是**一动不动**的 —— 扫会话文件
    /// 要花时间,用户不知道设备收到没有,只会再按一次,于是排队又多一轮。
    private var loading: String?

    /// 现在有没有挡在内容前面的一层。顺序即优先级。
    private var currentOverlay: AppOverlay? {
        if let overlay = pinned.overlay { return overlay }
        if let why = unavailableReason {
            return .unavailable(reason: why, hint: "把设备连到 Mac 上即可使用")
        }
        if let what = loading { return .loading(what) }
        return nil
    }
    /// 错误要一直挂着直到用户按键确认,不能被下一次自动刷新悄悄盖掉 ——
    /// 语音发送失败这种事,一闪而过等于没提示。
    private var pinned = PinnedError()

    // 攒列表用。条目是一条一条推过来的(带 index/total),收齐了才整体替换,
    // 否则界面会在加载过程中一行一行地跳。
    private var pending: [String] = []

    /// nil = 本端没有能跑 Codex 的后端(iOS)。
    private let browser: CodexBackend?

    /// 本端跑不了的话,原因是什么。iOS 上非 nil。
    let unavailableReason: String?

    init(browser: CodexBackend?, unavailableReason: String? = nil) {
        self.browser = browser
        // 两者必须一致:有后端就不该说跑不了,没后端就必须给出原因。
        // 不一致的话,用户会看到一个"可用"但点进去一片空白的应用。
        self.unavailableReason = browser == nil
            ? (unavailableReason ?? "Codex 只能在 Mac 上运行")
            : nil
    }

    // MARK: 来自 CodexBrowserModel 的输出

    /// 接到 CodexBrowserModel 的 sender 上。(kind, index, total, text)
    func handleOutput(kind: UInt8, index: UInt16, total: UInt16, text: String) {
        lock.lock()
        // ⚠ 只有**这一屏真的变了**才推。
        //
        // 列表是一条一条推过来的(带 index/total),早先每收到一条就
        // requestPush() 一次 —— 20 个工作区就是 20 次整屏 BLE 写入,而中间那
        // 19 次画出来的还是旧内容。用户看到的就是"按下去要等很久",实际时间
        // 全花在推那些没用的中间态上了。
        var changed = false
        switch kind {
        case RelayKind.workspaceItem, RelayKind.sessionItem:
            if index == 0 { pending = [] }
            pending.append(text)
            if Int(index) + 1 >= Int(total) {
                changed = true
                if kind == RelayKind.workspaceItem {
                    workspaces = pending
                    if wsSel >= workspaces.count { wsSel = max(0, workspaces.count - 1) }
                    mode = .workspaces
                } else {
                    sessions = pending
                    if sessSel >= sessions.count { sessSel = max(0, sessions.count - 1) }
                    mode = .sessions
                }
                pending = []
                status = nil
                loading = nil
            }
        case RelayKind.pageUser, RelayKind.pageAssistant:
            changed = true
            pageText = text
            pageIndex = Int(index)
            pageTotal = Int(total)
            pageIsUser = (kind == RelayKind.pageUser)
            mode = .reading
            status = nil
            loading = nil
        case RelayKind.status:
            status = text
            loading = nil
            changed = true
        case RelayKind.error:
            pinned.set(text)
            loading = nil
            changed = true
        default:
            break
        }
        lock.unlock()
        if changed { onChange?() }
    }

    // MARK: RemoteApp

    func setActive(_ active: Bool) {
        guard active else { return }
        // 没有后端就别摆"正在读取"的过场 —— 那一屏会一直挂着,因为永远
        // 不会有数据回来。直接让 render() 出那一屏说明。
        guard let browser = browser else { return }
        lock.lock()
        mode = .workspaces
        loading = "正在读取工作区…"
        lock.unlock()
        browser.handleRequest(req: CmdReq.listWorkspaces, a: 0, b: 0)
    }

    /// 交给模板取值的那棵树。
    ///
    /// `screen` 决定解释器画哪一屏 —— 三级导航是能力的状态,不是"第几页"。
    func state() -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        switch mode {
        case .workspaces:
            return .object([
                "screen": .string("workspaces"),
                "workspaces": .array(workspaces.map { .string($0) }),
                "wsSel": .number(Double(wsSel)),
                "status": .string(status ?? ""),
            ])
        case .sessions:
            return .object([
                "screen": .string("sessions"),
                "sessions": .array(sessions.map { .string($0) }),
                "sessSel": .number(Double(sessSel)),
                "status": .string(status ?? ""),
            ])
        case .reading:
            // 标题("我  3/12" 还是就一个"我")在这里拼好。
            // 模板里没有嵌套表达式,也**不该**有 —— 一个能在字符串里套
            // 条件的模板语言,离变成半个编程语言只差几次"再加一点点"。
            let who = pageIsUser ? "我" : "Codex"
            return .object([
                "screen": .string("reading"),
                "title": .string(pageTotal > 0 ? "\(who)  \(pageIndex + 1)/\(pageTotal)" : who),
                "status": .string(status ?? ""),
                // 折行在这儿做完 —— 那是真计算,不该进模板语言。
                "lines": .array(status == nil
                    ? DeviceText.wrap(pageText, limit: DeviceText.bodyRows).map { .string($0) }
                    : []),
            ])
        }
    }

    var overlay: AppOverlay? {
        lock.lock(); defer { lock.unlock() }
        return currentOverlay
    }
    /// 清单把按键绑到这些具名动作上。
    ///
    /// 三级导航(工作区 → 会话 → 阅读)由能力自己管:它在 state() 里给一个
    /// `screen` 字段,解释器据此选屏。清单只声明每一屏长什么样、键绑到哪个
    /// 动作 —— 它不知道也不需要知道现在是第几级。
    @discardableResult
    func perform(_ action: String) -> Bool {
        lock.lock()
        let m = mode
        lock.unlock()

        switch action {
        case "up":   return moveSelection(-1)
        case "down": return moveSelection(1)

        case "open":
            switch m {
            case .workspaces:
                lock.lock(); let i = wsSel; loading = "正在读取会话…"; lock.unlock()
                browser?.handleRequest(req: CmdReq.listSessions, a: UInt8(min(i, 255)), b: 0)
                return true          // 立刻把过场屏推出去
            case .sessions:
                lock.lock(); let w = wsSel; let ss = sessSel; loading = "正在打开会话…"; lock.unlock()
                browser?.handleRequest(req: CmdReq.openSession,
                                       a: UInt8(min(w, 255)), b: UInt8(min(ss, 255)))
                return true
            case .reading:
                return false
            }

        case "back":
            // ⚠ 只在**还有上一级**的时候消费这一下。在工作区里返回 false,
            // 让它继续往上交给框架去退出应用 —— 吃掉的话用户就出不来了。
            switch m {
            case .workspaces: return false
            case .sessions:
                lock.lock(); mode = .workspaces; loading = nil; lock.unlock()
                return true
            case .reading:
                lock.lock(); mode = .sessions; loading = nil; lock.unlock()
                return true
            }

        // 翻页方向:0 = 上一页,1 = 下一页(见 CodexBrowserModel.handlePage)。
        // 返回 false:翻页很快,不值得为它闪一屏过场。
        case "prevPage":
            browser?.handleRequest(req: CmdReq.page, a: 0, b: 0)
            return false
        case "nextPage":
            browser?.handleRequest(req: CmdReq.page, a: 1, b: 0)
            return false

        default: return false
        }
    }

    /// 挂着的错误被任意键清掉。这条规则在框架里(PinnedError.consumeKey),
    /// 三个应用共用同一份 —— 清错误的那一下不能顺带翻页。
    func dismissOverlayError() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pinned.consumeKey()
    }
    // MARK: 私有

    private func moveSelection(_ delta: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch mode {
        case .workspaces:
            guard !workspaces.isEmpty else { return false }
            wsSel = max(0, min(workspaces.count - 1, wsSel + delta))
        case .sessions:
            guard !sessions.isEmpty else { return false }
            sessSel = max(0, min(sessions.count - 1, sessSel + delta))
        case .reading:
            return false
        }
        return true
    }

}
