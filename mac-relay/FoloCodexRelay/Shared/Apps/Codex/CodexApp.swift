import Foundation

// =====================================================================
// Codex 会话浏览器,作为一个独立的远程应用。
//
// 跟另一个方案的取舍
// ──────────────────
// 本来可以照着 DashboardApp 那样从零写一个:自己扫 ~/.codex/sessions、自己
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

final class CodexApp: RemoteApp {
    let name = "Codex"
    let detail = "浏览会话,长按下键说话"
    // Codex 是个终端里的东西,用键盘图标。
    let defaultIcon = DeviceIcon.find("\u{F11C}").glyph
    var requestPush: (() -> Void)?
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
        if changed { requestPush?() }
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

    func render() -> Screen {
        lock.lock()
        defer { lock.unlock() }

        // 三层覆盖("跑不了 / 加载中 / 出错了")在框架里,不在这儿各写一遍。
        // 优先级也由框架定:错误盖住一切,然后是跑不了,最后才是加载中。
        if let overlay = currentOverlay {
            return overlay.render(title: "Codex")
        }

        var s = Screen()

        switch mode {
        case .workspaces:
            s.title = "Codex 工作区"
            if workspaces.isEmpty {
                s.text(status ?? "没有找到工作区")
            } else {
                appendList(&s, workspaces, sel: wsSel)
            }
            s.footer = "上/下选择  确定进入"

        case .sessions:
            s.title = "会话"
            if sessions.isEmpty {
                s.text(status ?? "这个工作区没有会话")
            } else {
                appendList(&s, sessions, sel: sessSel)
            }
            s.footer = "确定打开  双击确定返回"

        case .reading:
            s.title = pageTotal > 0 ? "\(pageIsUser ? "我" : "Codex")  \(pageIndex + 1)/\(pageTotal)"
                                    : (pageIsUser ? "我" : "Codex")
            if let st = status {
                s.text(st)
            } else {
                for line in DeviceText.wrap(pageText, limit: DeviceText.bodyRows) { s.text(line) }
            }
            s.footer = "上/下翻页  双击确定返回"
            // 只有阅读界面收语音:说话是"对当前这个会话说",在工作区列表上
            // 录音没有明确的收件人。
            s.mic = true
        }
        return s
    }

    func handleKey(_ button: RemoteButton, _ event: RemoteButtonEvent) -> Bool {
        lock.lock()
        // 任意键先清掉挂着的错误,并且**只**做这一件事 —— 否则用户为了消掉
        // 提示按的那一下会顺带翻页,看不清刚才发生了什么。这条规则收在
        // PinnedError.consumeKey 里,三个应用共用同一份。
        if pinned.consumeKey() {
            lock.unlock()
            return true
        }
        let m = mode
        lock.unlock()

        switch m {
        case .workspaces:
            switch (button, event) {
            case (.up, .click), (.up, .hold):    return moveSelection(-1)
            case (.down, .click), (.down, .hold): return moveSelection(1)
            case (.ok, .click):
                lock.lock(); let i = wsSel; loading = "正在读取会话…"; lock.unlock()
                browser?.handleRequest(req: CmdReq.listSessions, a: UInt8(min(i, 255)), b: 0)
                return true          // 立刻把过场屏推出去
            default: return false
            }

        case .sessions:
            switch (button, event) {
            case (.up, .click), (.up, .hold):    return moveSelection(-1)
            case (.down, .click), (.down, .hold): return moveSelection(1)
            case (.ok, .click):
                lock.lock(); let w = wsSel; let ss = sessSel; loading = "正在打开会话…"; lock.unlock()
                browser?.handleRequest(req: CmdReq.openSession,
                                      a: UInt8(min(w, 255)), b: UInt8(min(ss, 255)))
                return true          // 立刻把过场屏推出去
            case (.ok, .double):
                lock.lock(); mode = .workspaces; loading = nil; lock.unlock()
                return true
            default: return false
            }

        case .reading:
            switch (button, event) {
            // 翻页方向:0 = 上一页,1 = 下一页(见 CodexBrowserModel.handlePage)。
            case (.up, .click), (.up, .hold):
                browser?.handleRequest(req: CmdReq.page, a: 0, b: 0)
                return false          // 翻页很快,不值得为它闪一屏过场
            case (.down, .click), (.down, .hold):
                browser?.handleRequest(req: CmdReq.page, a: 1, b: 0)
                return false
            case (.ok, .double):
                lock.lock(); mode = .sessions; loading = nil; lock.unlock()
                return true
            default: return false
            }
        }
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

    /// 列表带一个滚动窗口:设备一屏放不下 12 行以上,而工作区可能有几十个。
    /// 没有窗口的话选中项一旦超出前 11 项就永远看不见了 —— 而按键还在响应,
    /// 表现为"按下键没反应"。
    private func appendList(_ s: inout Screen, _ items: [String], sel: Int) {
        let visible = 10
        var start = 0
        if items.count > visible {
            start = max(0, min(sel - visible / 2, items.count - visible))
        }
        let end = min(items.count, start + visible)
        if start > 0 { s.text("  ↑ 还有 \(start) 项") }
        for i in start..<end {
            s.text((i == sel ? "> " : "  ") + items[i])
        }
        if end < items.count { s.text("  ↓ 还有 \(items.count - end) 项") }
    }

}
