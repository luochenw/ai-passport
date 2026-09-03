import Foundation

// 从 main.swift 拆出来。原来 2000 多行混在一个文件里,通用层和 macOS 专有层
// 分不开,没法谈三端复用。

// MARK: - Codex workspace/session/page browser model

/// Computes the workspace list, session list, and paginated session content from
/// ~/.codex/sessions, handles all five CMD request types, and polls once a second to
/// auto-advance the currently open session when it is still the newest file in the
/// system and new content has been appended.
///
/// All mutable state is confined to `modelQueue` (a single serial queue), mirroring the
/// bleQueue-confinement pattern already used by BLERelay -- so no separate locking is
/// needed here either.
// CodexBackend 的 macOS 实现。签名本来就对得上,加个 conformance 就行 ——
// 这条缝原本就很干净,CodexApp 从头到尾只用了 handleRequest 这一个方法。
final class CodexBrowserModel: CodexBackend {
    private let sessionsRoot: URL
    private let modelQueue = DispatchQueue(label: "com.folotoy.codexrelay.model")
    private let pollQueue = DispatchQueue(label: "com.folotoy.codexrelay.filewatch")

    /// (kind, index, total, text) -- forwarded straight into BLERelay.enqueue.
    private let sender: (UInt8, UInt16, UInt16, String) -> Void

    private struct WorkspaceEntry {
        let cwd: String
        let displayName: String
        let files: [URL]       // this workspace's session files, sorted by mtime descending
        let newestMTime: Date
    }

    /// The ordering computed by the most recent REQ_LIST_WORKSPACES call. REQ_LIST_SESSIONS
    /// and REQ_OPEN_SESSION index into this cache, per the protocol spec.
    private var workspaceCache: [WorkspaceEntry] = []

    /// 每个会话文件的 cwd 缓存。
    ///
    /// computeWorkspaces() 要按 cwd 把会话归到工作区里,而 cwd 只能从文件里读。
    /// 早先是**每次**列工作区都把 ~/.codex/sessions 下的每个文件重新开一遍读
    /// 一行 —— 会话攒到几百个之后,用户每次进 Codex 都要干等这几百次文件 IO。
    ///
    /// cwd 是建会话时写进 rollout 文件的,此后不会变,所以按路径缓存是安全的:
    /// 新文件读一次,老文件再也不读。
    private var cwdCache: [URL: String] = [:]

    /// "Currently open session" + "current page" -- a Mac-side singleton, since only one
    /// device is ever connected at a time.
    private var currentSessionFile: URL?
    private var currentPages: [(kind: UInt8, text: String)] = []
    private var currentPageIndex: Int = 0
    private var lastCheckedSize: UInt64 = 0

    // 一页的容量按**显示宽度**算,不按字符数 —— 见 DeviceText 的说明。
    //
    // ⚠ 这里原来是"每页 180 个字符"。那个数字对中文太大、对英文又太小:
    // 180 个中文字排出来是 14 行,而设备一屏只放得下 10 行,后面 4 行**直接
    // 看不到**(渲染时按行数截断,没有任何提示);反过来 180 个英文字符只用掉
    // 半屏多一点,白白多翻几页。
    //
    // 改成按半角宽度切,两种内容都正好填满一屏。
    private static let pageWidthBudget = DeviceText.pageBudget

    init(sender: @escaping (UInt8, UInt16, UInt16, String) -> Void) {
        self.sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        self.sender = sender
    }

    func start() {
        pollQueue.async { [weak self] in
            self?.scheduleTick()
        }
    }

    /// Entry point for VoiceInputPipeline.sessionContextProvider: the thread/session id
    /// (same UUID recorded as session_id in the rollout file, and accepted directly by
    /// `codex exec resume <id>`) and the model that session's most recent turn actually
    /// used, for whichever session the device is currently browsing -- (nil, nil) if none
    /// is open. Passed to HeadlessCodexSender.send so a voice message lands in the session
    /// actually shown on the device (falling back to `--last` when nothing is open) AND
    /// continues with that session's own model instead of silently falling back to
    /// whatever this Mac's config.toml defaults to (a session can and does switch models
    /// mid-conversation, so "current" means the last turn_context, not the first).
    func currentSessionContext(completion: @escaping (_ threadId: String?, _ model: String?) -> Void) {
        modelQueue.async { [weak self] in
            guard let self = self, let file = self.currentSessionFile else {
                completion(nil, nil)
                return
            }
            completion(Self.readSessionId(of: file), Self.readLastModel(of: file))
        }
    }

    /// Entry point for VoiceInputPipeline.onSendFailure: surfaces a `codex exec resume`
    /// failure on the device screen (as a STATUS page) instead of it only ever showing up
    /// in this Mac process's own log file -- previously a failed voice send (write-lock
    /// conflict, the user's model relay rejecting the request, etc.) was completely silent
    /// from the device's point of view. Whatever real page/status the device was already
    /// showing gets restored automatically the next time the session file actually
    /// changes (checkForUpdates) or the user pages/re-opens a session (both call
    /// sendCurrentPage() directly), so this doesn't need its own revert timer.
    func reportVoiceError(_ text: String) {
        modelQueue.async { [weak self] in
            // RelayKind.error, not sendStatus()/RelayKind.status -- status is silently
            // overwritten by the next auto-refresh push (fine for an informational "no
            // session" placeholder), but an error needs the user to actually see it, so
            // it goes out as the pinned kind the device holds until a key dismisses it.
            self?.sender(RelayKind.error, 0, 1, "语音发送失败: \(text)")
        }
    }

    /// Entry point for BLERelay.onCmdRequest. Hands off to modelQueue immediately so the
    /// (potentially slower, file-IO-bound) request handling never blocks bleQueue.
    func handleRequest(req: UInt8, a: UInt8, b: UInt8) {
        modelQueue.async { [weak self] in
            guard let self = self else { return }
            switch req {
            case CmdReq.activeSession:
                self.handleActiveSession()
            case CmdReq.listWorkspaces:
                self.handleListWorkspaces()
            case CmdReq.listSessions:
                self.handleListSessions(workspaceIndex: a)
            case CmdReq.openSession:
                self.handleOpenSession(workspaceIndex: a, sessionIndex: b)
            case CmdReq.page:
                self.handlePage(direction: a)
            default:
                log("收到未知 CMD 请求 req=\(req),忽略")
            }
        }
    }

    // MARK: Request handlers (all run on modelQueue)

    private func handleActiveSession() {
        log("收到请求: REQ_ACTIVE_SESSION")
        guard let newest = Self.findNewestJSONL(under: sessionsRoot) else {
            log("没有任何会话文件,发送空状态")
            currentSessionFile = nil
            currentPages = []
            currentPageIndex = 0
            lastCheckedSize = 0
            sendStatus("暂无正在进行的会话")
            return
        }
        openSession(file: newest)
    }

    private func handleListWorkspaces() {
        log("收到请求: REQ_LIST_WORKSPACES")
        let entries = computeWorkspaces()
        workspaceCache = entries
        guard !entries.isEmpty else {
            log("没有任何工作区,发送空状态")
            sendStatus("暂无工作区")
            return
        }
        let total = UInt16(min(entries.count, 255))
        for (i, entry) in entries.enumerated() where i < 255 {
            sender(RelayKind.workspaceItem, UInt16(i), total, entry.displayName)
        }
    }

    private func handleListSessions(workspaceIndex: UInt8) {
        log("收到请求: REQ_LIST_SESSIONS workspace=\(workspaceIndex)")
        guard Int(workspaceIndex) < workspaceCache.count else {
            log("REQ_LIST_SESSIONS 工作区下标越界,忽略: \(workspaceIndex)")
            return
        }
        let entry = workspaceCache[Int(workspaceIndex)]
        let total = UInt16(min(entry.files.count, 255))
        let titles = Self.loadSessionTitles()
        for (i, file) in entry.files.enumerated() where i < 255 {
            let line = Self.sessionDisplayLine(for: file, titles: titles)
            sender(RelayKind.sessionItem, UInt16(i), total, line)
        }
    }

    private func handleOpenSession(workspaceIndex: UInt8, sessionIndex: UInt8) {
        log("收到请求: REQ_OPEN_SESSION workspace=\(workspaceIndex) session=\(sessionIndex)")
        guard Int(workspaceIndex) < workspaceCache.count else {
            log("REQ_OPEN_SESSION 工作区下标越界,忽略")
            return
        }
        let entry = workspaceCache[Int(workspaceIndex)]
        guard Int(sessionIndex) < entry.files.count else {
            log("REQ_OPEN_SESSION 会话下标越界,忽略")
            return
        }
        openSession(file: entry.files[Int(sessionIndex)])
    }

    private func handlePage(direction: UInt8) {
        guard !currentPages.isEmpty else {
            log("[debug] 收到 REQ_PAGE 但当前没有可翻页的内容,忽略")
            return
        }
        let delta = direction == 0 ? -1 : 1
        let newIndex = currentPageIndex + delta
        guard newIndex >= 0 && newIndex < currentPages.count else {
            log("[debug] REQ_PAGE 越界,忽略 (当前=\(currentPageIndex) 总数=\(currentPages.count) 方向=\(direction))")
            return
        }
        currentPageIndex = newIndex
        sendCurrentPage()
    }

    // MARK: Shared open/page-send helpers

    private func openSession(file: URL) {
        currentSessionFile = file
        let items = Self.parseSessionItems(file: file)
        currentPages = Self.buildPages(from: items)
        // Land on the most recent page, not the beginning -- this is a chat, and the
        // reader wants to see where the conversation currently stands; paging UP walks
        // back through history from there.
        currentPageIndex = max(0, currentPages.count - 1)
        lastCheckedSize = Self.fileSize(file)
        log("打开会话: \(file.path) 分页数=\(currentPages.count)")
        if currentPages.isEmpty {
            sendStatus("该会话暂无可显示内容")
        } else {
            sendCurrentPage()
        }
    }

    private func sendCurrentPage() {
        guard currentPageIndex >= 0 && currentPageIndex < currentPages.count else { return }
        let page = currentPages[currentPageIndex]
        let total = UInt16(min(currentPages.count, 65535))
        let index = UInt16(min(currentPageIndex, 65535))
        sender(page.kind, index, total, page.text)
    }

    private func sendStatus(_ text: String) {
        sender(RelayKind.status, 0, 1, text)
    }

    // MARK: Background auto-refresh (1s poll, adapted from v1's CodexSessionWatcher)

    private func scheduleTick() {
        pollQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.tick()
            self?.scheduleTick()
        }
    }

    private func tick() {
        modelQueue.async { [weak self] in
            self?.checkForUpdates()
        }
    }

    private func checkForUpdates() {
        guard let current = currentSessionFile else { return }
        guard let newest = Self.findNewestJSONL(under: sessionsRoot) else { return }
        guard newest == current else {
            // The currently-open session is no longer the newest file in the system --
            // the user is deliberately browsing history, so leave it alone.
            return
        }

        let size = Self.fileSize(current)
        guard size != lastCheckedSize else { return }
        lastCheckedSize = size

        let items = Self.parseSessionItems(file: current)
        let newPages = Self.buildPages(from: items)
        let oldTotal = currentPages.count
        // "Was following along" if the device was on the last page of the old page set,
        // OR there was nothing to show before (empty session that just got its first
        // content) -- both cases should auto-advance to newly-appended content.
        let wasFollowing = (oldTotal == 0) || (currentPageIndex == oldTotal - 1)
        currentPages = newPages

        guard !newPages.isEmpty else {
            currentPageIndex = 0
            return
        }

        if wasFollowing {
            currentPageIndex = min(oldTotal, newPages.count - 1)
            log("检测到当前会话有新增内容,自动推送新页 index=\(currentPageIndex) total=\(newPages.count)")
            sendCurrentPage()
        } else if currentPageIndex >= newPages.count {
            // User is on a historical page that no longer exists after re-splitting
            // (should be rare) -- just clamp, don't yank them to a different page.
            currentPageIndex = newPages.count - 1
        }
    }

    // MARK: Workspace computation
    //
    // "Workspace" here means the same thing the Codex desktop app's own sidebar calls a
    // "project" -- a curated, user-visible list of ~10-20 folders -- not "every distinct
    // cwd any session file ever recorded" (that raw grouping produced 100+ entries, mostly
    // one-off scratch directories, which is not what a person means by "my projects").
    // The desktop app persists its own project list at ~/.codex/.codex-global-state.json
    // under the key "electron-saved-workspace-roots" (an Electron persisted-atom store;
    // undocumented and could change shape in a future Codex release, but it's the only
    // available source for this distinction). A session belongs to a workspace when its
    // recorded cwd equals, or is nested under, that workspace's root path.

    private static func readSavedWorkspaceRoots() -> [String] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json")
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = obj["electron-saved-workspace-roots"] as? [String] else {
            log("读取 Codex 项目列表失败(~/.codex/.codex-global-state.json 缺失或格式变化),工作区列表将为空")
            return []
        }
        return roots
    }

    private func computeWorkspaces() -> [WorkspaceEntry] {
        let roots = Self.readSavedWorkspaceRoots()
        guard !roots.isEmpty else { return [] }

        let files = Self.findAllJSONL(under: sessionsRoot)
        var cwdByFile: [URL: String] = [:]
        var freshReads = 0
        for f in files {
            if let cached = cwdCache[f] {
                cwdByFile[f] = cached
                continue
            }
            if let cwd = Self.readCwd(of: f) {
                cwdByFile[f] = cwd
                cwdCache[f] = cwd
                freshReads += 1
            }
        }
        if freshReads > 0 {
            log("[codex] 扫描 \(files.count) 个会话文件,其中 \(freshReads) 个是新读的")
        }

        // Longest-root-wins: a cwd nested under two saved roots (e.g. both "/a" and
        // "/a/b" were saved) belongs to the more specific one.
        let sortedRoots = roots.sorted { $0.count > $1.count }
        func matchingRoot(for cwd: String) -> String? {
            for root in sortedRoots where cwd == root || cwd.hasPrefix(root + "/") {
                return root
            }
            return nil
        }

        var filesByRoot: [String: [URL]] = [:]
        for (file, cwd) in cwdByFile {
            guard let root = matchingRoot(for: cwd) else { continue } // not under any saved project
            filesByRoot[root, default: []].append(file)
        }

        // Naive display name = last path component; detect collisions so we know which
        // workspaces need the two-segment disambiguated name instead.
        var naiveNames: [String: String] = [:]
        for root in filesByRoot.keys {
            naiveNames[root] = URL(fileURLWithPath: root).lastPathComponent
        }
        var nameCounts: [String: Int] = [:]
        for name in naiveNames.values { nameCounts[name, default: 0] += 1 }

        var entries: [WorkspaceEntry] = []
        for (root, filesForRoot) in filesByRoot {
            let sortedFiles = filesForRoot.sorted { Self.fileMTime($0) > Self.fileMTime($1) }
            guard let newest = sortedFiles.first else { continue }
            let naiveName = naiveNames[root] ?? root
            let displayName: String
            if (nameCounts[naiveName] ?? 0) > 1 {
                let comps = (root as NSString).pathComponents
                displayName = comps.count >= 2 ? comps.suffix(2).joined(separator: "/") : naiveName
            } else {
                displayName = naiveName
            }
            entries.append(WorkspaceEntry(cwd: root, displayName: displayName,
                                           files: sortedFiles, newestMTime: Self.fileMTime(newest)))
        }
        entries.sort { $0.newestMTime > $1.newestMTime }
        return entries
    }

    // MARK: File parsing helpers (static: no instance state needed)

    /// Reads the full file and returns every (kind, text) item worth displaying, in
    /// order -- i.e. every event_msg/item_completed item whose item.type is UserMessage
    /// or AgentMessage. task_started/task_complete and everything else (developer/
    /// environment-context noise, reasoning items, tool calls, session_meta, ...) is
    /// skipped entirely; there is no longer any "task started/complete" STATUS.
    private static func parseSessionItems(file: URL) -> [(kind: UInt8, text: String)] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        var items: [(kind: UInt8, text: String)] = []
        let newline: UInt8 = 0x0A
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            let lineData = data.subdata(in: start..<end)
            if !lineData.isEmpty, let item = parseItemLine(lineData) {
                items.append(item)
            }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
        return items
    }

    /// Codex has recorded conversational turns under at least two different event_msg
    /// payload shapes across its history (confirmed against real session files, not
    /// assumed): older sessions (e.g. an Aug 2026 rollout) use a flat
    /// payload.type == "user_message"/"agent_message" with the text directly in
    /// payload.message; newer sessions wrap it as payload.type == "item_completed"
    /// with payload.item.type == "UserMessage"/"AgentMessage" and the text in
    /// item.content[].text. A session written under the old schema has zero
    /// item_completed events at all, so checking only the new shape silently produced
    /// "no content" for real, non-empty conversations -- both must be recognized.
    private static func parseItemLine(_ data: Data) -> (kind: UInt8, text: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (obj["type"] as? String) == "event_msg" else { return nil }
        guard let payload = obj["payload"] as? [String: Any] else { return nil }
        guard let payloadType = payload["type"] as? String else { return nil }

        if payloadType == "item_completed" {
            guard let item = payload["item"] as? [String: Any] else { return nil }
            guard let itemType = item["type"] as? String else { return nil }
            let kind: UInt8
            switch itemType {
            case "UserMessage": kind = RelayKind.pageUser
            case "AgentMessage": kind = RelayKind.pageAssistant
            default: return nil // ReasoningItem, ToolCall, etc. -- ignore
            }
            let contentArr = item["content"] as? [[String: Any]] ?? []
            let text = contentArr.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { return nil }
            return (kind, text)
        }

        if payloadType == "user_message" || payloadType == "agent_message" {
            let kind: UInt8 = payloadType == "user_message" ? RelayKind.pageUser : RelayKind.pageAssistant
            guard let text = payload["message"] as? String, !text.isEmpty else { return nil }
            return (kind, text)
        }

        return nil // task_started/task_complete/token_count/etc. -- ignore
    }

    /// Splits a sequence of (kind, text) message items into page-sized chunks of at most
    /// `pageCharBudget` Characters each, preferring to break on whitespace/newlines so
    /// words aren't cut mid-way, and -- because every cut point here is a Swift Character
    /// boundary, never a raw byte offset -- structurally incapable of splitting a
    /// multi-byte UTF-8 character across two pages. A message longer than the budget
    /// spans multiple pages, all carrying that same original kind.
    static func buildPages(from items: [(kind: UInt8, text: String)]) -> [(kind: UInt8, text: String)] {
        let budget = pageWidthBudget
        var pages: [(kind: UInt8, text: String)] = []
        for item in items {
            let chars = Array(item.text)
            guard !chars.isEmpty else { continue }

            // 每个字符的显示宽度先算好,后面反复要用。
            let widths = chars.map { DeviceText.width($0) }
            // 从 from 开始、累计宽度不超过 budget 的最远位置(不含)。
            func endOfPage(from: Int) -> Int {
                var w = 0
                var i = from
                while i < chars.count {
                    // 换行本身不占宽度,但会强制起新行 —— 折行的行数上限已经
                    // 体现在 budget 里了,这里按宽度近似即可。
                    let cw = chars[i].isNewline ? DeviceText.rowBudget : widths[i]
                    if w + cw > budget { break }
                    w += cw
                    i += 1
                }
                return i
            }

            var start = 0
            while start < chars.count {
                let hardEnd = endOfPage(from: start)
                if hardEnd >= chars.count {
                    pages.append((item.kind, String(chars[start...])))
                    break
                }

                // Scan backward from the budget boundary for a whitespace/newline break
                // point, but don't accept one that would make the page less than half
                // the budget (avoids pathologically short pages on dense text).
                let minBreak = start + (hardEnd - start) / 2
                var breakAt = hardEnd
                var scan = hardEnd
                while scan > minBreak {
                    if chars[scan - 1].isWhitespace {
                        breakAt = scan
                        break
                    }
                    scan -= 1
                }

                var pageChars = Array(chars[start..<breakAt])
                while let last = pageChars.last, last.isWhitespace {
                    pageChars.removeLast()
                }
                if pageChars.isEmpty {
                    // Defensive fallback (should not happen given minBreak above): don't
                    // emit an empty page, just hard-cut without trimming.
                    pageChars = Array(chars[start..<hardEnd])
                    breakAt = hardEnd
                }
                pages.append((item.kind, String(pageChars)))

                var next = breakAt
                while next < chars.count && chars[next].isWhitespace {
                    next += 1
                }
                start = next
            }
        }
        return pages
    }

    /// Streams a file's lines (without loading it fully into memory), invoking `handler`
    /// for each line's raw Data until it returns true ("found what I needed, stop") or
    /// EOF is reached. Used for the workspace/session list-building paths, which must
    /// not fully parse potentially-huge rollout files just to build a list.
    private static func scanLines(of file: URL, until handler: (Data) -> Bool) {
        guard let fh = FileHandle(forReadingAtPath: file.path) else { return }
        defer { fh.closeFile() }
        var buffer = Data()
        let chunkSize = 64 * 1024
        while true {
            while let idx = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<idx)
                buffer.removeSubrange(buffer.startIndex...idx)
                if !line.isEmpty, handler(line) { return }
            }
            let chunk = fh.readData(ofLength: chunkSize)
            if chunk.isEmpty {
                if !buffer.isEmpty { _ = handler(buffer) }
                return
            }
            buffer.append(chunk)
        }
    }

    /// Reads only the file's first line (a session_meta record) to get its cwd, without
    /// touching the rest of the file.
    private static func readCwd(of file: URL) -> String? {
        var result: String?
        scanLines(of: file) { line in
            result = parseCwd(from: line)
            return true // only the first line is ever relevant
        }
        return result
    }

    private static func parseCwd(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (obj["type"] as? String) == "session_meta" else { return nil }
        guard let payload = obj["payload"] as? [String: Any] else { return nil }
        return payload["cwd"] as? String
    }

    /// Reads only the file's first line to get its session_id, without touching the rest
    /// of the file. Used to look the session up in ~/.codex/session_index.jsonl for its
    /// Codex-assigned title.
    private static func readSessionId(of file: URL) -> String? {
        var result: String?
        scanLines(of: file) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return true }
            guard (obj["type"] as? String) == "session_meta" else { return true }
            guard let payload = obj["payload"] as? [String: Any] else { return true }
            result = payload["session_id"] as? String
            return true
        }
        return result
    }

    /// Scans the whole file for `turn_context` records and returns the `model` field of
    /// the LAST one -- the model actually in effect for the most recent turn, which can
    /// differ from the first turn's (users switch models mid-conversation; this exact
    /// session has done that). Used so a voice-triggered `codex exec resume` continues
    /// with the session's own current model instead of silently falling back to whatever
    /// this Mac's config.toml happens to default to.
    private static func readLastModel(of file: URL) -> String? {
        var result: String?
        scanLines(of: file) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (obj["type"] as? String) == "turn_context",
                  let payload = obj["payload"] as? [String: Any],
                  let model = payload["model"] as? String else {
                return false   // keep scanning -- false never stops scanLines early
            }
            result = model
            return false
        }
        return result
    }

    /// The Codex desktop app auto-generates a short title per conversation ("thread") and
    /// persists it to ~/.codex/session_index.jsonl, keyed by the same UUID recorded as
    /// session_id in the rollout file. This is the title shown in Codex's own session
    /// list, so it's what the device's session list should show too -- much more useful
    /// than a raw timestamp or a truncated first message.
    private static func loadSessionTitles() -> [String: String] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
        guard let data = try? Data(contentsOf: path) else { return [:] }
        var titles: [String: String] = [:]
        let newline: UInt8 = 0x0A
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            let lineData = data.subdata(in: start..<end)
            if !lineData.isEmpty,
               let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let id = obj["id"] as? String,
               let name = obj["thread_name"] as? String, !name.isEmpty {
                titles[id] = name
            }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
        return titles
    }

    /// Streams the file looking for the first UserMessage item_completed event, stopping
    /// as soon as it's found rather than parsing the whole file.
    private static func firstUserMessageSummary(of file: URL) -> String? {
        var result: String?
        scanLines(of: file) { line in
            guard let item = parseItemLine(line), item.kind == RelayKind.pageUser else { return false }
            result = String(item.text.prefix(24))
            return true
        }
        return result
    }

    private static func sessionDisplayLine(for file: URL, titles: [String: String]) -> String {
        if let sid = readSessionId(of: file), let title = titles[sid] {
            return title
        }
        if let summary = firstUserMessageSummary(of: file) {
            return summary
        }
        return formatSessionTime(fileMTime(file))
    }

    private static func formatSessionTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
        return f.string(from: date)
    }

    // MARK: File discovery helpers

    private static func findAllJSONL(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            results.append(url)
        }
        return results
    }

    private static func findNewestJSONL(under root: URL) -> URL? {
        findAllJSONL(under: root).max { fileMTime($0) < fileMTime($1) }
    }

    private static func fileMTime(_ url: URL) -> Date {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else { return Date.distantPast }
        return date
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    }
}

