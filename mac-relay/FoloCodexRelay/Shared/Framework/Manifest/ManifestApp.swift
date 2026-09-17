import Foundation

// =====================================================================
// 清单解释器:把一份 JSON 变成一个 RemoteApp
//
// 这是"从 GitHub 更新应用"能成立的那一块。清单是数据,这里是唯一会执行它的
// 地方 —— 所以这里的每一条容错都不是洁癖:清单可能来自比这个伴侣端更新的
// 版本,也可能干脆写错了。任何一种情况下,设备上都该显示一屏**能看懂的东西**,
// 而不是黑屏或者崩溃。
// =====================================================================

final class ManifestApp: RemoteApp {
    let manifest: AppManifest
    private let capability: AppCapability
    private let lock = NSLock()

    /// 当前第几屏。上下键翻页。
    private var page = 0

    var name: String { manifest.name }
    var detail: String { manifest.detail }
    var defaultIcon: String { manifest.icon }
    /// 清单里写的是路由名(字符串),这里翻成枚举。翻不出来就是没有设置页 ——
    /// 一个更新的清单可能引用了这个伴侣端还没有的设置页,那时候少一个齿轮
    /// 图标,远好过点进去一片空白。
    /// 这一端跑不了的原因。从能力的覆盖层里取 —— 应用列表要能显示出来
    /// (灰掉 + 一句原因),而不是让用户装上、点进去才发现是空的。
    var unavailableReason: String? {
        if case let .unavailable(reason, _) = capability.overlay { return reason }
        return nil
    }

    var settingsRoute: RemoteAppSettingsRoute? {
        manifest.settings.flatMap(RemoteAppSettingsRoute.init(rawValue:))
    }

    var requestPush: (() -> Void)?
    var notify: ((String) -> Void)?

    init(manifest: AppManifest, capability: AppCapability) {
        self.manifest = manifest
        self.capability = capability
        capability.onChange = { [weak self] in self?.requestPush?() }
    }

    // MARK: RemoteApp

    func setActive(_ active: Bool) {
        if active { lock.lock(); page = 0; lock.unlock() }
        capability.setActive(active)
    }

    func setInstalled(_ installed: Bool) {
        capability.setInstalled(installed)
    }

    func render() -> Screen {
        // 挡着的层优先,而且由框架统一画 —— 清单不描述这些,因为它们的
        // 措辞和按键行为必须在所有应用之间一致。
        if let overlay = capability.overlay {
            return overlay.render(title: manifest.name)
        }

        let root = capability.state()

        // 屏幕由谁决定:能力给了 `screen` 就听它的(Codex 的导航栈),
        // 没给就按上下翻页的那个下标(看板的五页)。
        let byID = root.value(at: "screen").stringValue
        let idx: Int
        if !byID.isEmpty, let i = manifest.screens.firstIndex(where: { $0.id == byID }) {
            idx = i
        } else {
            lock.lock()
            idx = min(page, manifest.screens.count - 1)
            lock.unlock()
        }
        let screen = manifest.screens[idx]

        var s = Screen()
        // 翻页式多屏才带页码 —— 用户得知道还有别的页、自己在第几页。
        // 能力驱动的多屏(Codex 的工作区→会话→阅读)不是"第几页",给它
        // 加个 1/3 只会误导。
        let title = Template.render(screen.title, root)
        let paged = manifest.screens.count > 1 && manifest.screens.allSatisfy { $0.id == nil }
        s.title = paged ? "\(title)  \(idx + 1)/\(manifest.screens.count)" : title
        emit(screen.rows, root, into: &s)
        if let footer = screen.footer {
            s.footer = Template.render(footer, root)
        }
        switch screen.hint {
        case "walkie": s.walkie = true
        case "mic": s.mic = true
        default: break
        }
        return s
    }

    func handleKey(_ button: RemoteButton, _ event: RemoteButtonEvent) -> Bool {
        // 挂着的错误吃掉这一下,并且只做这一件事(见 PinnedError)。
        if capability.dismissOverlayError() { return true }

        // 清单里绑了动作的键优先给能力 —— 对讲的"按住下键讲话"就是这么来的。
        if let eventName = event.manifestName,
           let action = manifest.keys[button.manifestName]?[eventName] {
            return capability.perform(action)
        }

        // 没绑的话,上下键是翻页。只有一屏、或者屏幕由能力决定时都不翻。
        guard manifest.screens.count > 1,
              manifest.screens.allSatisfy({ $0.id == nil }) else { return false }
        switch (button, event) {
        case (.up, .click), (.up, .hold):
            lock.lock()
            page = (page - 1 + manifest.screens.count) % manifest.screens.count
            lock.unlock()
            return true
        case (.down, .click), (.down, .hold):
            lock.lock()
            page = (page + 1) % manifest.screens.count
            lock.unlock()
            return true
        default:
            return false
        }
    }

    // MARK: - 行

    private func emit(_ rows: [ManifestRow], _ root: JSONValue, into s: inout Screen) {
        for row in rows {
            switch row {
            case let .text(t, style):
                s.text(Template.render(t, root), style: Screen.RowStyle(
                    manifestValue: style.map { Template.render($0, root) } ?? ""))

            case let .bar(label, value):
                s.bar(Template.render(label, root),
                      percent: root.value(at: value).doubleValue)

            case .spacer:
                s.spacer()

            case let .when(cond, then, otherwise):
                emit(Template.condition(cond, root) ? then : otherwise, root, into: &s)

            case let .list(path, selected, limit, empty):
                let items = root.value(at: path).arrayValue
                guard !items.isEmpty else {
                    if let empty { s.text(Template.render(empty, root)) }
                    continue
                }
                let sel = Int(root.value(at: selected).doubleValue)
                emitList(items, selected: sel,
                         visible: min(limit ?? Self.defaultListRows, Self.hardEachLimit),
                         into: &s)

            case let .each(path, limit, body):
                var items = root.value(at: path).arrayValue
                // ⚠ 一定要有上限。屏幕只有 8 行左右,而这个数组是**能力**
                // 给的(容器列表、菜单条目),长度不受清单控制。不截的话
                // 一屏几百行会把设备侧的 1KB 接收缓冲撑爆,整屏被丢弃 ——
                // 表现是"某天容器多了之后这一页就白了"。
                let cap = min(limit ?? Self.defaultEachLimit, Self.hardEachLimit)
                if items.count > cap { items = Array(items.prefix(cap)) }
                for item in items {
                    // 循环体里用 `item.` 前缀取当前项;外层字段照常可见。
                    emit(body, root.merging(item: item), into: &s)
                }
            }
        }
    }

    /// 列表开窗。
    ///
    /// 选中项要留在可视区里 —— 十几个工作区一屏放不下,选中项滚出去之后
    /// 用户就不知道自己停在哪儿了。上下的"还有 N 项"也不能省:没有它,
    /// 列表看起来就是全部内容,用户不会想到还能继续往下。
    private func emitList(_ items: [JSONValue], selected: Int, visible: Int,
                          into s: inout Screen) {
        var start = 0
        if items.count > visible {
            start = max(0, min(selected - visible / 2, items.count - visible))
        }
        let end = min(items.count, start + visible)
        if start > 0 { s.text("  ↑ 还有 \(start) 项") }
        for i in start..<end {
            s.text((i == selected ? "> " : "  ") + items[i].stringValue)
        }
        if end < items.count { s.text("  ↓ 还有 \(items.count - end) 项") }
    }

    /// 列表默认显示几行。跟迁移之前的 appendList 一致。
    private static let defaultListRows = 10
    /// 清单没写 limit 时的默认条数。设备一屏放得下的量级。
    private static let defaultEachLimit = 8
    /// 清单写了也不能超过这个 —— 清单是从网上来的,不能让它决定
    /// 设备收多少字节。
    private static let hardEachLimit = 32
}

private extension JSONValue {
    /// 把当前遍历项挂到 `item` 下,和外层字段并存。
    func merging(item: JSONValue) -> JSONValue {
        guard case var .object(d) = self else {
            return .object(["item": item])
        }
        d["item"] = item
        return .object(d)
    }
}

private extension RemoteButton {
    /// 清单里写的键名。
    var manifestName: String {
        switch self {
        case .up: return "up"
        case .down: return "down"
        case .ok: return "ok"
        }
    }
}

private extension RemoteButtonEvent {
    /// 清单里能绑的事件名。
    ///
    /// `double` 也放开,因为"双击确定返回上一级"是真需求(Codex 的
    /// 工作区→会话→阅读三级导航)。放开是安全的:能力 `perform` 返回
    /// false 时,这一下会继续往上交给框架,框架的"退出应用"照常生效 ——
    /// 也就是说清单**抢不走**返回,它只能在自己还有上一级时先消费掉。
    ///
    /// `long` / `longUp` 不放开:长按下键是设备侧写死的录音手势
    /// (见 Screen.mic),给清单绑只会跟录音打架。
    var manifestName: String? {
        switch self {
        case .press: return "press"
        case .release: return "release"
        case .click: return "click"
        case .hold: return "hold"
        case .double: return "double"
        case .long, .longUp: return nil
        }
    }
}
