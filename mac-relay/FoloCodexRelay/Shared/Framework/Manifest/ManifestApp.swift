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

        lock.lock()
        let idx = min(page, manifest.screens.count - 1)
        lock.unlock()

        let screen = manifest.screens[idx]
        let root = capability.snapshot()

        var s = Screen()
        // 多屏时标题带页码 —— 用户得知道还有别的页,以及自己在第几页。
        let title = Template.render(screen.title, root)
        s.title = manifest.screens.count > 1
            ? "\(title)  \(idx + 1)/\(manifest.screens.count)"
            : title
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

        // 没绑的话,上下键是翻页。只有一屏就什么都不做。
        guard manifest.screens.count > 1 else { return false }
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
            case let .text(t):
                s.text(Template.render(t, root))

            case let .bar(label, value):
                s.bar(Template.render(label, root),
                      percent: root.value(at: value).doubleValue)

            case .spacer:
                s.spacer()

            case let .when(cond, then, otherwise):
                emit(Template.condition(cond, root) ? then : otherwise, root, into: &s)

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
    /// 只暴露这四个。设备侧还会发 double / long / longUp —— 那三个在框架里
    /// 有固定含义(双击返回、长按退出),放开给清单绑会让某个应用把"返回"
    /// 抢走,用户就出不来了。
    var manifestName: String? {
        switch self {
        case .press: return "press"
        case .release: return "release"
        case .click: return "click"
        case .hold: return "hold"
        case .double, .long, .longUp: return nil
        }
    }
}
