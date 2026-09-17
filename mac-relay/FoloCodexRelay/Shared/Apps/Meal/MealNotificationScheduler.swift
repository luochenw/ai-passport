import Foundation
import UserNotifications

final class MealNotificationScheduler {
    private static let prefix = "com.folotoy.codexrelay.meal."
    private let center: UNUserNotificationCenter
    private let calendar: Calendar

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ??
            TimeZone(secondsFromGMT: 8 * 60 * 60)!
        self.calendar = calendar
    }

    func update(enabled: Bool, weeks: [MealWeek]) {
        guard enabled else {
            removePending()
            return
        }
        // 启动时服务可能暂时未连上，此时 weeks 为空。保留上次已经排好的
        // 通知，避免一次短暂断网把本周剩余饭点全部取消。
        guard let week = weeks.first else { return }

        center.requestAuthorization(options: [.alert, .sound]) { [center, calendar] granted, error in
            if let error {
                log("[meal] 通知权限请求失败: \(error.localizedDescription)")
                return
            }
            guard granted else {
                log("[meal] 用户未开启系统通知")
                return
            }
            center.getPendingNotificationRequests { requests in
                let identifiers = requests.map(\.identifier).filter {
                    $0.hasPrefix(Self.prefix)
                }
                center.removePendingNotificationRequests(withIdentifiers: identifiers)
                Self.schedule(week: week, center: center, calendar: calendar)
            }
        }
    }

    private func removePending() {
        center.getPendingNotificationRequests { [center] requests in
            let identifiers = requests.map(\.identifier).filter {
                $0.hasPrefix(Self.prefix)
            }
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }

    private static func schedule(week: MealWeek,
                                 center: UNUserNotificationCenter,
                                 calendar: Calendar) {
        let now = Date()
        for day in week.days {
            schedule(day: day, meal: "lunch", hour: 12, minute: 10,
                     center: center, calendar: calendar, now: now)
            schedule(day: day, meal: "dinner", hour: 18, minute: 10,
                     center: center, calendar: calendar, now: now)
        }
    }

    private static func schedule(day: MealDay, meal: String, hour: Int, minute: Int,
                                 center: UNUserNotificationCenter,
                                 calendar: Calendar, now: Date) {
        let parts = day.date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = hour
        components.minute = minute
        guard let fireDate = calendar.date(from: components), fireDate > now else { return }
        let weekday = calendar.component(.weekday, from: fireDate)
        guard weekday >= 2 && weekday <= 6 else { return }

        let period = meal == "lunch" ? day.lunch : day.dinner
        guard !period.recommendedFloor.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "字节餐厅"
        let mealName = meal == "lunch" ? "午饭" : "晚饭"
        content.body = mealName + "去" + period.recommendedFloor +
            (period.recommendation.isEmpty ? "" : "：" + period.recommendation)
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.prefix + day.date + "." + meal,
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error {
                log("[meal] 安排 \(day.date) \(mealName) 通知失败: \(error.localizedDescription)")
            }
        }
    }
}
