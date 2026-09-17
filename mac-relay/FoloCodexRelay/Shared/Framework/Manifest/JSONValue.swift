import Foundation

// =====================================================================
// 清单应用的数据模型
//
// 清单是**数据**,不是代码 —— 它从 GitHub 拉下来,不能带类型定义。所以能力
// 交给模板的那份状态也必须是动态的:一棵可以按路径取值的树。
//
// 为什么不直接用 `[String: Any]`:取值要按 `a.b.c` 这种路径走,还要能安全地
// 转成字符串/数字/布尔。用 Any 的话每一处取值都要 `as?` 一遍,而漏掉一处的
// 表现是那一行悄悄变成空字符串 —— 屏幕上少一行,没有任何报错。
// =====================================================================

/// 能力交给模板的状态。
indirect enum JSONValue {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    /// 从 `Codable` 的东西转过来。能力通常直接持有自己的结构体,
    /// 编码一遍是最省事、也最不容易漏字段的做法。
    static func from<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let any = try? JSONSerialization.jsonObject(with: data,
                                                          options: [.fragmentsAllowed]) else {
            return .null
        }
        return JSONValue(any: any)
    }

    init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let b as Bool where type(of: any) == type(of: NSNumber(value: true)):
            // ⚠ 必须在 NSNumber 之前判布尔。JSONSerialization 把 true/false
            // 也做成 NSNumber,先按数字接的话 `{{connected}}` 会拿到 1 / 0,
            // 条件判断照样过,但界面上会出现"服务 1"这种字样。
            self = .bool(b)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map { JSONValue(any: $0) })
        case let d as [String: Any]:
            self = .object(d.mapValues { JSONValue(any: $0) })
        default:
            self = .null
        }
    }

    /// 按 `a.b.0.c` 取值。取不到返回 `.null` —— 模板里就是空串/假,
    /// 不抛错:一个写错的路径不该让整屏消失。
    func value(at path: String) -> JSONValue {
        var cur = self
        for part in path.split(separator: ".") {
            switch cur {
            case let .object(d):
                cur = d[String(part)] ?? .null
            case let .array(a):
                guard let i = Int(part), a.indices.contains(i) else { return .null }
                cur = a[i]
            default:
                return .null
            }
        }
        return cur
    }

    var stringValue: String {
        switch self {
        case .null: return ""
        case let .bool(b): return b ? "true" : "false"
        case let .number(n):
            // 整数不显示小数点 —— "连接数 12" 比 "连接数 12.0" 好。
            return n == n.rounded() && abs(n) < 1e15
                ? String(Int(n)) : String(n)
        case let .string(s): return s
        case let .array(a): return a.map(\.stringValue).joined(separator: " ")
        // 带 `text` 的对象可直接作为模板值显示。这样数组项能在保留
        // `item.style` 等元数据的同时继续使用 `{{item}}`；旧清单仍会把它
        // 当普通字符串渲染，样式字段缺失时自然降级为正文色。
        case let .object(o): return o["text"]?.stringValue ?? ""
        }
    }

    var doubleValue: Double {
        switch self {
        case let .number(n): return n
        case let .bool(b): return b ? 1 : 0
        case let .string(s): return Double(s) ?? 0
        default: return 0
        }
    }

    /// 真假判断。空串、空数组、0、null 都是假 —— 跟大多数模板语言一致,
    /// 免得清单里到处写 `x != ""`。
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case let .bool(b): return b
        case let .number(n): return n != 0
        case let .string(s): return !s.isEmpty
        case let .array(a): return !a.isEmpty
        case let .object(o): return !o.isEmpty
        }
    }

    var arrayValue: [JSONValue] {
        if case let .array(a) = self { return a }
        return []
    }
}
