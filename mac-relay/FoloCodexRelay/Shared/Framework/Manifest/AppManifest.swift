import Foundation

// =====================================================================
// 应用清单
//
// 一个应用 = 一份清单(数据)+ 一个能力(原生)。
//
// 为什么必须这么切:Swift 是 AOT 编译的,iOS 明令禁止下载并执行代码
// (App Store 2.5.2)。所以"从 GitHub 重新获取所有的应用"只能是**取数据**。
// 好在应用协议小得惊人 —— RemoteApp 一共 7 个成员,其中真正有内容的只有
// render 和 handleKey,而这两件事都是可以描述的。
//
// 原生的那一半是**能力**,不是应用:对讲的实时音频通道、Codex 的会话查询、
// 看板的本地文件轮询。这一层数量少、接口窄、编进 app;清单在它上面画屏幕、
// 绑按键,从网上更新。
//
// 早先我把它分成"原生应用 vs 清单应用",那是错的 —— 它把"应用"和"能力"
// 混成了一件事。WalkieTalkieApp.render() 里没有一行音频代码,它只是四行插值
// 加一个三分支;音频走的是 BLE 特征值 → WalkieClient → WebSocket,那是传输层。
// =====================================================================

/// 一行的声明。
indirect enum ManifestRow {
    /// 一行文字。内容是模板。
    case text(String)
    /// 进度条。`label` 是模板,`value` 是取百分比的路径。
    case bar(label: String, value: String)
    /// 空行。
    case spacer
    /// 条件。`cond` 是路径(可 `!` 取反)。
    case when(cond: String, then: [ManifestRow], otherwise: [ManifestRow])
    /// 遍历数组。循环体里 `.` 开头的路径指向当前项。
    case each(path: String, limit: Int?, body: [ManifestRow])
}

/// 一屏。上下键在多屏之间翻页。
struct ManifestScreen {
    var title: String
    var rows: [ManifestRow]
    var footer: String?
    /// 给设备的提示位:`"walkie"` 开实时对讲手势,`"mic"` 收语音。
    var hint: String?
}

/// 一个应用的完整声明。
struct AppManifest {
    var id: String
    var name: String
    var detail: String
    var icon: String
    /// 绑哪个能力。能力提供数据和动作。
    var capability: String
    /// 一屏或多屏。多屏时上下键翻页,页码显示在标题里。
    var screens: [ManifestScreen]
    /// 这个应用在伴侣端有没有自己的设置页,以及是哪一页。
    /// 设置页是 SwiftUI 写的原生界面 —— 清单只说"有",不描述它长什么样。
    var settings: String?
    /// 按键绑到能力的哪个动作。键名:`up` / `down` / `ok`,
    /// 值形如 `press:beginTalk` / `release:endTalk` / `click:toggle`。
    var keys: [String: [String: String]]
}

// MARK: - 解码
//
// 手写 Decodable 而不是让编译器合成:ManifestRow 是个带递归的和类型,
// JSON 里长成 `{"text": "..."}` / `{"when": {...}}` 这种形状,合成出来的
// 编码是 `{"text": {"_0": "..."}}` —— 那种格式没法手写,而清单是要给人写的。

extension ManifestRow: Decodable {
    private enum Keys: String, CodingKey {
        case text, bar, spacer, when, each
        case label, value, cond, then, `else`, path, limit, body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let t = try c.decodeIfPresent(String.self, forKey: .text) {
            self = .text(t); return
        }
        if c.contains(.spacer) {
            self = .spacer; return
        }
        if let bar = try? c.nestedContainer(keyedBy: Keys.self, forKey: .bar) {
            self = .bar(label: try bar.decodeIfPresent(String.self, forKey: .label) ?? "",
                        value: try bar.decode(String.self, forKey: .value))
            return
        }
        if let w = try? c.nestedContainer(keyedBy: Keys.self, forKey: .when) {
            self = .when(cond: try w.decode(String.self, forKey: .cond),
                         then: try w.decodeIfPresent([ManifestRow].self, forKey: .then) ?? [],
                         otherwise: try w.decodeIfPresent([ManifestRow].self, forKey: .else) ?? [])
            return
        }
        if let e = try? c.nestedContainer(keyedBy: Keys.self, forKey: .each) {
            self = .each(path: try e.decode(String.self, forKey: .path),
                         limit: try e.decodeIfPresent(Int.self, forKey: .limit),
                         body: try e.decodeIfPresent([ManifestRow].self, forKey: .body) ?? [])
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .text, in: c,
            debugDescription: "行必须是 text / bar / spacer / when / each 之一")
    }
}

extension ManifestScreen: Decodable {}
extension AppManifest: Decodable {
    private enum Keys: String, CodingKey {
        case id, name, detail, icon, capability, screens, keys, settings
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "▶"
        capability = try c.decode(String.self, forKey: .capability)
        screens = try c.decode([ManifestScreen].self, forKey: .screens)
        keys = try c.decodeIfPresent([String: [String: String]].self, forKey: .keys) ?? [:]
        settings = try c.decodeIfPresent(String.self, forKey: .settings)
        guard !screens.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .screens, in: c, debugDescription: "至少要有一屏")
        }
    }

    static func decode(_ data: Data) throws -> AppManifest {
        try JSONDecoder().decode(AppManifest.self, from: data)
    }
}
