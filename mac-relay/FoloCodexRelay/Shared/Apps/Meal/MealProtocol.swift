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
