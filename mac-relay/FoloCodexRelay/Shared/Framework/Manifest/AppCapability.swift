import Foundation

// =====================================================================
// 能力:清单站在上面的那一层原生代码
//
// 判据:**清单描述不了的**才是能力。实时音频通道、子进程、文件轮询、
// WebSocket 订阅 —— 这些要平台能力,进不了一份 JSON。
//
// ⚠ 能力的接口必须**窄且稳定**。这是整个方案里最需要克制的地方:接口一旦
// 频繁改,清单就得跟着改,而清单是从 GitHub 拉的、可能比伴侣端旧或新 ——
// "从网上更新应用"的价值当场归零。宁可能力少一点、笨一点。
// =====================================================================

protocol AppCapability: AnyObject {
    /// 清单里 `capability` 字段的值。
    static var id: String { get }

    /// 当前状态,交给模板取值。会被频繁调用,应当廉价 ——
    /// 取数据放后台,拿到之后调 `onChange`。
    func state() -> JSONValue

    /// 状态变了,该重推一屏。由框架注入。
    var onChange: (() -> Void)? { get set }

    /// 往设备上弹一条全局通知(跟屏幕是两条路)。由框架注入。
    ///
    /// 放进协议是为了让注册那一步能统一 —— 以前 walkie 和 meal 各自在
    /// DeviceSession 里手工接一次线,于是"加一个应用"必须去改那段代码。
    var notify: ((String) -> Void)? { get set }

    /// 有没有挡在内容前面的一层(没配置 / 加载中 / 出错了)。
    var overlay: AppOverlay? { get }

    /// 用户进/出这个应用。起停定时器、开始/停止拉数据。
    func setActive(_ active: Bool)
    /// 这台设备装/卸了这个应用。要后台连接的能力看这个,而不是看
    /// "类型被注册了"。
    func setInstalled(_ installed: Bool)

    /// 按键绑过来的动作。`action` 是清单里写的名字。
    /// 返回 true 表示要立刻重推一屏。
    @discardableResult
    func perform(_ action: String) -> Bool

    /// 清掉挡着的错误(用户按了任意键)。没有错误就返回 false。
    func dismissOverlayError() -> Bool
}

extension AppCapability {
    var overlay: AppOverlay? { nil }
    func setActive(_ active: Bool) {}
    func setInstalled(_ installed: Bool) {}
    @discardableResult func perform(_ action: String) -> Bool { false }
    func dismissOverlayError() -> Bool { false }
}
