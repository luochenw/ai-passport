import Foundation

struct MealOutlet: Codable, Equatable {
    let floor: String
    let name: String
    let dishes: [String]

    init(floor: String, name: String, dishes: [String] = []) {
        self.floor = floor
        self.name = name
        self.dishes = dishes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        floor = try values.decode(String.self, forKey: .floor)
        name = try values.decode(String.self, forKey: .name)
        dishes = try values.decodeIfPresent([String].self, forKey: .dishes) ?? []
    }
}

struct MealPeriod: Codable, Equatable {
    let outlets: [MealOutlet]
    let recommendedFloor: String
    let recommendation: String
}

struct MealDay: Codable, Equatable, Identifiable {
    var id: String { date }
    let date: String
    let weekday: String
    let lunch: MealPeriod
    let dinner: MealPeriod
}

struct MealWeek: Codable, Equatable, Identifiable {
    var id: String { weekOf }
    let weekOf: String
    let building: String
    let source: String
    let updatedAt: String
    let days: [MealDay]
}

struct MealReminder: Codable, Equatable {
    let date: String
    let meal: String
    let floor: String
    let summary: String
    let message: String

    init(date: String, meal: String, floor: String,
         summary: String = "", message: String) {
        self.date = date
        self.meal = meal
        self.floor = floor
        self.summary = summary
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        date = try values.decode(String.self, forKey: .date)
        meal = try values.decode(String.self, forKey: .meal)
        floor = try values.decode(String.self, forKey: .floor)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        message = try values.decode(String.self, forKey: .message)
    }
}

struct MealServerEvent: Decodable {
    let type: String
    var weeks: [MealWeek]?
    var reminder: MealReminder?
    var message: String?
}

struct MealClientMessage: Encodable {
    let type: String
    var clientId: String?
    var installed: Bool?
    var token: String?
}

struct MealSnapshot: Equatable {
    var installed = false
    var connected = false
    var weeks: [MealWeek] = []
    var status = "尚未启用"
}

enum MealDateNavigation {
    static func dates(in weeks: [MealWeek]) -> [String] {
        guard let week = weeks.first else { return [] }
        var dates = Set(week.days.map(\.date))
        if let monday = parse(week.weekOf) {
            for offset in 0..<5 {
                if let date = calendar.date(byAdding: .day, value: offset, to: monday) {
                    dates.insert(format(date))
                }
            }
        }
        return dates.sorted()
    }

    static func nextDate(in weeks: [MealWeek], current: String, delta: Int) -> String? {
        guard delta != 0 else { return nil }
        let dates = dates(in: weeks)
        guard dates.count > 1 else { return nil }
        let currentIndex = dates.firstIndex(of: current) ?? 0
        let step = delta < 0 ? -1 : 1
        return dates[(currentIndex + step + dates.count) % dates.count]
    }

    static func weekday(for value: String) -> String {
        guard let date = parse(value) else { return "" }
        switch calendar.component(.weekday, from: date) {
        case 2: return "周一"
        case 3: return "周二"
        case 4: return "周三"
        case 5: return "周四"
        case 6: return "周五"
        case 7: return "周六"
        default: return "周日"
        }
    }

    static func monthDay(for value: String) -> String {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return value }
        return "\(parts[1])/\(parts[2])"
    }

    private static func parse(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func format(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else {
            return ""
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ??
            TimeZone(secondsFromGMT: 8 * 60 * 60)!
        return calendar
    }()
}

struct MealMenuRow: Equatable {
    enum Style: String {
        case body
        case accent
    }

    let text: String
    let style: Style
}

/// 把一餐的完整内容整理成有层级、能连续分页的设备行。
///
/// 标题和菜品是一个语义块：标题不会独自留在页尾；菜品跨页时，新页先重复
/// `续｜楼层｜档口`。菜品只折行、不截断，调用方要提供与设备宽度一致的折行器。
enum MealMenuPagination {
    static let rowsPerPage = 9

    private struct Block {
        let header: [String]
        let continuation: [String]
        let body: [String]
    }

    static func pages(for period: MealPeriod,
                      rowsPerPage: Int = MealMenuPagination.rowsPerPage,
                      wrapping: (String, Int) -> [String]) -> [[MealMenuRow]] {
        var blocks: [Block] = []
        let recommended = period.recommendedFloor.trimmingCharacters(in: .whitespacesAndNewlines)
        let recommendation = period.recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !recommendation.isEmpty {
            let title = recommended.isEmpty ? "推荐" : "推荐｜\(recommended)"
            blocks.append(Block(
                header: wrapped(title, reservedWidth: 0, wrapping: wrapping),
                continuation: wrapped("续｜\(title)", reservedWidth: 0, wrapping: wrapping),
                body: indented(recommendation, wrapping: wrapping)))
        }

        let outlets = period.outlets.enumerated().sorted { lhs, rhs in
            let left = floorNumber(lhs.element.floor)
            let right = floorNumber(rhs.element.floor)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)

        for outlet in outlets {
            let dishes = unique(outlet.dishes)
            // 没有菜品的档口不单独占一行；否则它既没有可读内容，也必然形成
            // 一个孤立标题。整餐都没有有效菜品时由 hasPeriodMenu 显示空状态。
            guard !dishes.isEmpty else { continue }
            let floor = outlet.floor.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = displayOutletName(outlet.name, floor: floor)
            let header: String
            switch (floor.isEmpty, name.isEmpty) {
            case (false, false): header = "\(floor)｜\(name)"
            case (false, true): header = floor
            case (true, false): header = name
            case (true, true): header = "档口"
            }
            blocks.append(Block(
                header: wrapped(header, reservedWidth: 0, wrapping: wrapping),
                continuation: wrapped("续｜\(header)", reservedWidth: 0, wrapping: wrapping),
                body: indented(dishes.joined(separator: "、"), wrapping: wrapping)))
        }

        return paginate(blocks, rowsPerPage: rowsPerPage)
    }

    static func status(pageIndex: Int, pageCount: Int) -> String {
        let pages = max(1, pageCount)
        let index = max(0, min(pageIndex, pages - 1))
        return "\(index + 1)/\(pages)"
    }

    private static func paginate(_ blocks: [Block], rowsPerPage: Int) -> [[MealMenuRow]] {
        // 一行页无法同时容纳标题和正文，也就无法兑现“标题不孤立”的约束。
        precondition(rowsPerPage >= 2)
        let pageSize = rowsPerPage
        var pages: [[MealMenuRow]] = []
        var page: [MealMenuRow] = []

        func finishPage() {
            guard !page.isEmpty else { return }
            pages.append(page)
            page.removeAll(keepingCapacity: true)
        }

        func appendHeading(_ lines: [String]) {
            for (index, line) in lines.enumerated() {
                // 即使异常长的标题本身超过一页，也把最后一行标题和第一行正文
                // 留在同一页。服务端名称有长度上限，正常菜单不会走到这个分支。
                let remainingTitleLines = lines.count - index
                if page.count == pageSize ||
                    (remainingTitleLines <= pageSize - 1 &&
                     pageSize - page.count < remainingTitleLines + 1) {
                    finishPage()
                }
                page.append(MealMenuRow(text: line, style: .accent))
            }
        }

        for block in blocks where !block.header.isEmpty {
            // 标题的所有折行后至少要紧跟一条正文；当前页放不下时整块换页。
            if !page.isEmpty && block.header.count + 1 <= pageSize &&
                pageSize - page.count < block.header.count + 1 {
                finishPage()
            }
            appendHeading(block.header)

            for line in block.body {
                if page.count == pageSize {
                    finishPage()
                    appendHeading(block.continuation)
                }
                page.append(MealMenuRow(text: line, style: .body))
            }
        }
        finishPage()
        return pages.isEmpty ? [[]] : pages
    }

    private static func indented(_ text: String,
                                 wrapping: (String, Int) -> [String]) -> [String] {
        guard !text.isEmpty else { return [] }
        // 两个半角空格形成稳定的二级缩进；折行时预先扣掉这两格，避免 Screen
        // 最后再按一行宽度兜底截成省略号。
        let lines = wrapped(text, reservedWidth: 2, wrapping: wrapping)
        return lines.compactMap { raw in
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "、"))
            return line.isEmpty ? nil : "  " + line
        }
    }

    private static func wrapped(_ text: String, reservedWidth: Int,
                                wrapping: (String, Int) -> [String]) -> [String] {
        let lines = wrapping(text, reservedWidth)
        return lines.isEmpty ? [text] : lines
    }

    static func hasMenu(_ period: MealPeriod) -> Bool {
        if !period.recommendation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return period.outlets.contains { outlet in
            !unique(outlet.dishes).isEmpty
        }
    }

    private static func displayOutletName(_ name: String, floor: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "-–—_|｜/·:："))
        while !floor.isEmpty, result.hasPrefix(floor) {
            result.removeFirst(floor.count)
            result = result.trimmingCharacters(in: separators)
        }
        return result
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { return nil }
            return cleaned
        }
    }

    private static func floorNumber(_ value: String) -> Int {
        var digits = ""
        var foundDigit = false
        for character in value {
            if character.isNumber {
                digits.append(character)
                foundDigit = true
            } else if foundDigit {
                break
            }
        }
        return Int(digits) ?? Int.max
    }
}
