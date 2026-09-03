import Foundation

// =====================================================================
// 模板:`{{ … }}` 求值
//
// 刻意做得小。清单是从网上拉下来的数据,一个能力越强的模板语言就是一个越大
// 的攻击面 —— 这里**没有**函数调用、没有任意表达式、没有循环(循环是行的
// 结构,见 ManifestRow.each),只有:
//
//   {{path.to.field}}                取值
//   {{path | fixed:2}}               保留几位小数
//   {{path | pick:在线/离线}}         真假二选一
//   {{path | default:-}}             空值兜底
//   {{path | count}}                 数组长度
//
// 求值不会失败:路径写错就是空串。一个写错的字段不该让整屏消失 —— 设备上
// 少一行远比黑屏容易发现和定位。
// =====================================================================

enum Template {
    /// 把一段带 `{{}}` 的模板按 `root` 求值。
    static func render(_ template: String, _ root: JSONValue) -> String {
        guard template.contains("{{") else { return template }
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            out += rest[rest.startIndex..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                // 没闭合:把剩下的原样吐出去。清单写错了,但屏幕上看得见
                // 那对没闭合的括号,比默默吞掉整行好定位。
                out += "{{" + afterOpen
                return out
            }
            let expr = afterOpen[afterOpen.startIndex..<close.lowerBound]
            out += evaluate(String(expr), root)
            rest = afterOpen[close.upperBound...]
        }
        out += rest
        return out
    }

    /// 求一个条件(`when` 用)。整串就是一个路径,可带 `!` 取反。
    static func condition(_ expr: String, _ root: JSONValue) -> Bool {
        let e = expr.trimmingCharacters(in: .whitespaces)
        if e.hasPrefix("!") {
            return !root.value(at: String(e.dropFirst())).isTruthy
        }
        return root.value(at: e).isTruthy
    }

    // MARK: -

    private static func evaluate(_ expr: String, _ root: JSONValue) -> String {
        let parts = expr.split(separator: "|", omittingEmptySubsequences: false)
        guard let first = parts.first else { return "" }
        let path = first.trimmingCharacters(in: .whitespaces)
        var value = root.value(at: path)
        var text = value.stringValue

        for filter in parts.dropFirst() {
            let f = filter.trimmingCharacters(in: .whitespaces)
            let name = f.prefix { $0 != ":" }
            let arg = f.dropFirst(name.count).dropFirst()   // 去掉冒号

            switch name {
            case "fixed":
                let digits = Int(arg) ?? 1
                text = String(format: "%.\(max(0, min(6, digits)))f", value.doubleValue)
            case "pick":
                // `pick:在线/离线` —— 真取前者,假取后者。
                let options = arg.split(separator: "/", maxSplits: 1,
                                        omittingEmptySubsequences: false)
                let yes = options.first.map(String.init) ?? ""
                let no = options.count > 1 ? String(options[1]) : ""
                text = value.isTruthy ? yes : no
            case "default":
                if text.isEmpty { text = String(arg) }
            case "count":
                text = String(value.arrayValue.count)
                value = .number(Double(value.arrayValue.count))
            default:
                // 不认识的过滤器:原样保留取到的值,并且**不**报错。
                // 清单可能来自比这个伴侣端更新的版本 —— 少一层格式化
                // 远好过整屏空白。
                break
            }
        }
        return text
    }
}
