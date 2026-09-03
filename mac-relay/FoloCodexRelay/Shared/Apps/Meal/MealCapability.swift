import Foundation
import SwiftUI

// 这个文件现在是**能力**,不是应用。
//
// 屏幕布局在 AppManifests/meal.json 里。留在这里的是清单描述不了的:
// 从一周菜单里解析出"今天这一餐"、按菜品推荐楼层、文字折行,以及伴侣端
// 那个 SwiftUI 设置页的 @Published 模型。
//
// 分界很清楚:**算**出该显示什么留在这儿,**怎么摆**交给清单。折行和楼层
// 归并是真计算,把它们塞进模板语言只会让那个语言长成半个编程语言。
final class MealCapability: ObservableObject, AppCapability {
    static let id = "meal"
    /// 只留给 `.notInstalled` 那一屏的标题用 —— 名字、说明、图标现在都在
    /// 清单里,这里不再重复一份(重复的那份迟早跟清单对不上)。
    let name = "吃饭"

    var onChange: (() -> Void)?
    /// 饭点提醒走 cmd.notify,跟屏幕是两条路。由解释器注入。
    var notify: ((String) -> Void)?

    @Published var serverAddress: String
    @Published private(set) var snapshot: MealSnapshot

    private let client: MealClient
    /// 这一台。用来告诉全局 MealClient「是**我**装了/卸了」。
    private let deviceKey: String
    private let notifications: MealNotificationScheduler
    private let lock = NSLock()
    private var deviceSnapshot: MealSnapshot
    private var selectedDate = ""
    private var dinner = false

    /// ⚠ `installedHere` 是**这一台**装没装,跟 `snapshot.installed`
    /// ("还有没有任何一台装着",它决定那条全局 WebSocket 要不要活)是两回事。
    /// 屏幕上"请先安装应用"必须看前者:看后者的话,只要还有别的设备装着,
    /// 这台没装的设备也会显示出整周菜单。
    private var installedHere = false

    /// `notifications` 由外面传进来、全局一份。饭点提醒是弹给**一个人**看的,
    /// 跟他手里有几台 Passport 无关;而且通知标识符没有设备区分,每台各起
    /// 一个调度器的话,后一个 update 会把前一个排好的通知全删掉。
    init(client: MealClient, deviceKey: String, notifications: MealNotificationScheduler) {
        self.client = client
        self.deviceKey = deviceKey
        self.notifications = notifications
        let initialSnapshot = client.currentSnapshot()
        serverAddress = client.currentConfiguration()
        snapshot = initialSnapshot
        deviceSnapshot = initialSnapshot

        client.addSnapshotObserver { [weak self] value in
            guard let self else { return }
            self.lock.lock()
            self.deviceSnapshot = value
            if self.selectedDate.isEmpty ||
                !MealDateNavigation.dates(in: value.weeks).contains(self.selectedDate) {
                self.selectedDate = Self.defaultDay(in: value.weeks)?.date ?? ""
            }
            self.lock.unlock()
            self.snapshot = value
            self.notifications.update(enabled: value.installed, weeks: value.weeks)
            self.onChange?()
        }
        client.addReminderObserver { [weak self] reminder in
            self?.notify?(reminder.message)
        }
    }

    func setInstalled(_ installed: Bool) {
        lock.lock()
        installedHere = installed
        lock.unlock()
        // 通知的开关由 client 的快照驱动(见上面的 addSnapshotObserver):
        // 那一位是"还有没有任何一台装着",正是全局提醒该不该排的判据。
        // 这里**不能**拿本台的 installed 去调 —— 在 B 上卸载会把 A 的提醒
        // 一起删掉。
        client.setInstalled(installed, for: deviceKey)
    }

    func setActive(_ active: Bool) {
        guard active else { return }
        lock.lock()
        if selectedDate.isEmpty {
            selectedDate = Self.defaultDay(in: deviceSnapshot.weeks)?.date ?? ""
        }
        lock.unlock()
        onChange?()
    }

    /// 清单里 `up/down.click` 换天、`ok.click` 切午/晚餐。
    @discardableResult
    func perform(_ action: String) -> Bool {
        switch action {
        case "prevDay": return shiftDay(-1)
        case "nextDay": return shiftDay(1)
        case "togglePeriod":
            lock.lock(); dinner.toggle(); lock.unlock()
            return true
        default: return false
        }
    }

    private func shiftDay(_ delta: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let next = MealDateNavigation.nextDate(
            in: deviceSnapshot.weeks, current: selectedDate, delta: delta
        ) else { return false }
        selectedDate = next
        return true
    }

    /// 交给模板取值的那棵树。
    ///
    /// **算**出该显示什么在这里做完(哪一天、哪一餐、折行、楼层归并),
    /// 清单只管怎么摆。这条界线是刻意的:折行和归并是真计算,塞进模板
    /// 语言只会让那个语言长成半个编程语言。
    func state() -> JSONValue {
        lock.lock()
        let value = deviceSnapshot
        let date = selectedDate
        let showDinner = dinner
        let installedHereNow = installedHere
        lock.unlock()

        var root: [String: JSONValue] = [
            "installed": .bool(installedHereNow),
            "connected": .bool(value.connected),
            "status": .string(value.status),
            "multiDay": .bool(MealDateNavigation.dates(in: value.weeks).count > 1),
            "period": .string(showDinner ? "晚餐" : "午餐"),
            "date": .string(date),
        ]

        guard let week = value.weeks.first, !date.isEmpty else {
            root["hasMenu"] = .bool(false)
            return .object(root)
        }
        root["hasMenu"] = .bool(true)

        guard let day = week.days.first(where: { $0.date == date }) else {
            // 这一天没归档:标题还是要显示星期几,否则用户不知道自己翻到哪儿了。
            root["hasDay"] = .bool(false)
            root["weekday"] = .string(MealDateNavigation.weekday(for: date))
            return .object(root)
        }
        root["hasDay"] = .bool(true)
        root["weekday"] = .string(day.weekday)

        let p = showDinner ? day.dinner : day.lunch
        root["floor"] = .string(p.recommendedFloor.isEmpty ? "暂无" : p.recommendedFloor)
        root["recommendation"] = .array(
            p.recommendation.isEmpty ? []
                : DeviceText.wrap(p.recommendation, limit: 2).map { JSONValue.string($0) })
        root["floors"] = .array(Self.floorSummary(p.outlets).map { JSONValue.string($0) })
        return .object(root)
    }

    /// 没装在这一台上的时候由框架画那一屏。
    var overlay: AppOverlay? {
        lock.lock(); let here = installedHere; lock.unlock()
        return here ? nil : .notInstalled(name)
    }
    func saveAndReconnect() {
        client.configure(server: serverAddress)
    }

    func reconnect() {
        client.reconnect()
    }

    private static func defaultDay(in weeks: [MealWeek]) -> MealDay? {
        guard let week = weeks.first else { return nil }
        let today = Self.dateFormatter.string(from: Date())
        return week.days.first(where: { $0.date == today }) ?? week.days.first
    }

    private static func floorSummary(_ outlets: [MealOutlet]) -> [String] {
        var dishesByFloor: [String: [String]] = [:]
        for outlet in outlets {
            var dishes = dishesByFloor[outlet.floor] ?? []
            for dish in outlet.dishes where !dishes.contains(dish) {
                dishes.append(dish)
            }
            dishesByFloor[outlet.floor] = dishes
        }
        return dishesByFloor.keys.sorted {
            Int(String($0.filter(\.isNumber))) ?? 999 <
                Int(String($1.filter(\.isNumber))) ?? 999
        }.map { floor in
            let dishes = dishesByFloor[floor] ?? []
            return dishes.isEmpty ? floor : "\(floor) \(dishes.prefix(2).joined(separator: "/"))"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct MealSettingsView: View {
    @ObservedObject var model: MealCapability

    var body: some View {
        Form {
            Section("状态") {
                LabeledContent("服务", value: model.snapshot.connected ? "已连接" : "未连接")
                LabeledContent("菜单记录", value: "\(model.snapshot.weeks.count) 周")
                if let latest = model.snapshot.weeks.first {
                    LabeledContent("最新一周", value: latest.weekOf)
                    LabeledContent("楼宇", value: latest.building)
                }
            }

            Section("本地服务") {
                TextField("WebSocket 地址", text: $model.serverAddress)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                HStack {
                    Button("重新连接") { model.reconnect() }
                    Spacer()
                    Button("保存并连接") { model.saveAndReconnect() }
                        .keyboardShortcut(.defaultAction)
                }
            }

            if !model.snapshot.weeks.isEmpty {
                Section("历史菜单") {
                    ForEach(Array(model.snapshot.weeks.prefix(12))) { week in
                        HStack {
                            Text(week.weekOf)
                            Spacer()
                            Text("\(week.days.count) 天")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 380)
        #endif
    }
}
