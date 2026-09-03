import Foundation

func log(_ message: String) {
    if ProcessInfo.processInfo.environment["VERBOSE"] != nil {
        print(message)
    }
}

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ✓ \(message)")
    } else {
        print("  ✗ \(message)")
        failures += 1
    }
}

/// 一个只回答"当前状态"的假能力。清单解释器不该关心能力是怎么拿到数据的。
private final class FakeCapability: AppCapability {
    static let id = "fake"
    var onChange: (() -> Void)?
    var state: JSONValue = .object([:])
    var overlayValue: AppOverlay?
    private(set) var performed: [String] = []

    var overlay: AppOverlay? { overlayValue }
    func snapshot() -> JSONValue { state }

    @discardableResult
    func perform(_ action: String) -> Bool {
        performed.append(action)
        return true
    }
}

private func manifest(_ json: String) -> AppManifest {
    try! AppManifest.decode(Data(json.utf8))
}

@main
struct TestManifest {
    static func main() {
        // ---------- 模板 ----------
        let root = JSONValue.object([
            "name": .string("面板"),
            "cpu": .number(37.5),
            "ok": .bool(true),
            "down": .bool(false),
            "empty": .string(""),
            "items": .array([.object(["n": .string("a")]), .object(["n": .string("b")])]),
            "nested": .object(["deep": .string("命中")]),
        ])

        check(Template.render("{{name}}", root) == "面板", "取值")
        check(Template.render("{{nested.deep}}", root) == "命中", "按路径取值")
        check(Template.render("负载 {{cpu|fixed:2}}", root) == "负载 37.50", "fixed 保留小数")
        check(Template.render("{{ok|pick:在线/离线}}", root) == "在线", "pick 取真的一边")
        check(Template.render("{{down|pick:在线/离线}}", root) == "离线", "pick 取假的一边")
        check(Template.render("{{empty|default:-}}", root) == "-", "default 兜空值")
        check(Template.render("{{items|count}} 项", root) == "2 项", "count 数组长度")

        // 整数不该显示成 37.0 —— "连接数 12.0" 是这个 DSL 最容易犯的丑。
        check(Template.render("{{n}}", .object(["n": .number(12)])) == "12", "整数不带小数点")

        // ⚠ 布尔不能被当成数字。JSONSerialization 把 true 做成 NSNumber,
        // 先按数字接的话屏幕上会出现"服务 1"。
        let fromCodable = JSONValue.from(["flag": true])
        check(Template.render("{{flag}}", fromCodable) == "true", "布尔不会退化成 1")

        // 写错的路径是空串,不是崩溃 —— 一个笔误不该让整屏消失。
        check(Template.render("[{{nope.nothing}}]", root) == "[]", "路径写错取到空串")
        // 没闭合的括号原样吐出去,看得见才好定位。
        check(Template.render("{{unclosed", root).contains("{{"), "没闭合的括号看得见")

        // ---------- 条件 ----------
        check(Template.condition("ok", root), "条件:真")
        check(!Template.condition("down", root), "条件:假")
        check(Template.condition("!down", root), "条件:取反")
        check(!Template.condition("empty", root), "空串算假")
        check(Template.condition("items", root), "非空数组算真")

        // ---------- 解释器 ----------
        let cap = FakeCapability()
        cap.state = root
        let m = manifest("""
        {
          "id": "fake", "name": "假应用", "capability": "fake",
          "keys": { "ok": { "click": "refresh" } },
          "screens": [
            { "title": "第一屏", "footer": "f",
              "rows": [
                { "text": "名字 {{name}}" },
                { "bar": { "label": "CPU", "value": "cpu" } },
                { "spacer": true },
                { "when": { "cond": "ok",
                            "then": [ { "text": "真" } ],
                            "else": [ { "text": "假" } ] } },
                { "each": { "path": "items", "body": [ { "text": "- {{item.n}}" } ] } }
              ] },
            { "title": "第二屏", "rows": [ { "text": "另一页" } ] }
          ]
        }
        """)
        let app = ManifestApp(manifest: m, capability: cap)

        check(app.name == "假应用", "名字来自清单")
        var screen = app.render()
        var text = screen.encode()
        check(text.contains("名字 面板"), "文字行插值")
        check(text.contains("真") && !text.contains("假"), "when 只出真的一支")
        check(text.contains("- a") && text.contains("- b"), "each 遍历出两行")
        // 多屏时标题要带页码,否则用户不知道还有别的页
        check(text.contains("1/2"), "多屏标题带页码")

        // 下键翻页
        _ = app.handleKey(.down, .click)
        text = app.render().encode()
        check(text.contains("另一页"), "下键翻到第二屏")
        check(text.contains("2/2"), "页码跟着变")
        // 翻到底回卷,而不是卡在最后一页
        _ = app.handleKey(.down, .click)
        check(app.render().encode().contains("1/2"), "翻到底回到第一屏")

        // 绑了动作的键交给能力,不当成翻页
        _ = app.handleKey(.ok, .click)
        check(cap.performed == ["refresh"], "绑定的键交给能力")

        // ---------- 覆盖层盖住一切 ----------
        cap.overlayValue = .loading("正在读取…")
        check(app.render().encode().contains("正在读取…"), "覆盖层盖住内容")
        cap.overlayValue = nil

        // ---------- each 必须有上限 ----------
        //
        // 这个数组由能力给(容器列表、菜单条目),长度不受清单控制。不截的话
        // 一屏几百行会把设备侧 1KB 的接收缓冲撑爆,整屏被丢弃 —— 表现是
        // "某天容器多了之后这一页就白了"。
        cap.state = .object(["many": .array((0..<500).map { .string("x\($0)") })])
        let big = manifest("""
        {
          "id": "fake", "name": "多", "capability": "fake",
          "screens": [ { "title": "t", "rows": [
            { "each": { "path": "many", "limit": 9999, "body": [ { "text": "{{item}}" } ] } }
          ] } ]
        }
        """)
        let lines = ManifestApp(manifest: big, capability: cap).render().encode()
            .split(separator: "\n").filter { $0.hasPrefix("L") }
        check(lines.count <= 32, "each 有硬上限,清单写多大都不越过(实际 \(lines.count) 行)")

        // ---------- 坏清单不能让整个应用消失 ----------
        check((try? AppManifest.decode(Data("{}".utf8))) == nil, "缺字段的清单解码失败")
        check((try? AppManifest.decode(Data(#"{"id":"a","name":"b","capability":"c","screens":[]}"#.utf8))) == nil,
              "一屏都没有的清单被拒")

        if failures == 0 {
            print("manifest: PASS")
            exit(0)
        }
        exit(1)
    }
}
