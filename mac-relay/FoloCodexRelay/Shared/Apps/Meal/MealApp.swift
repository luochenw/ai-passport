import Foundation
import SwiftUI

final class MealApp: ObservableObject, RemoteApp {
    let name = "吃饭"
    let detail = "本周菜单与楼层推荐"
    let defaultIcon = DeviceIcon.find("\u{F0C9}").glyph
    let settingsRoute: RemoteAppSettingsRoute? = .meal
    var requestPush: (() -> Void)?
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
            self.requestPush?()
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
        requestPush?()
    }

    func handleKey(_ button: RemoteButton, _ event: RemoteButtonEvent) -> Bool {
        guard event == .click || event == .hold else { return false }
        lock.lock()
        defer { lock.unlock() }
        switch button {
        case .up, .down:
            let delta = button == .up ? -1 : 1
            guard let nextDate = MealDateNavigation.nextDate(
                in: deviceSnapshot.weeks, current: selectedDate, delta: delta
            ) else {
                return false
            }
            selectedDate = nextDate
            return true
        case .ok:
            dinner.toggle()
            return true
        }
    }

    func render() -> Screen {
        lock.lock()
        let value = deviceSnapshot
        let date = selectedDate
        let showDinner = dinner
        let installedHereNow = installedHere
        lock.unlock()

        var screen = Screen()
        guard installedHereNow else {
            screen.title = "吃饭"
            screen.text("请先安装应用")
            return screen
        }
        guard value.connected else {
            screen.title = "吃饭"
            screen.text(value.status)
            screen.footer = "请检查本地服务"
            return screen
        }
        guard let week = value.weeks.first, !date.isEmpty else {
            screen.title = "吃饭"
            screen.text("本周菜单还没更新")
            screen.footer = "周一 11:00 自动更新"
            return screen
        }

        guard let day = week.days.first(where: { $0.date == date }) else {
            let weekday = MealDateNavigation.weekday(for: date)
            screen.title = "\(weekday) \(showDinner ? "晚餐" : "午餐")"
            screen.text("当日菜单未归档")
            screen.text(date)
            screen.footer = "上/下换天  确定午/晚"
            return screen
        }

        let period = showDinner ? day.dinner : day.lunch
        screen.title = "\(day.weekday) \(showDinner ? "晚餐" : "午餐")"
        screen.text("推荐  \(period.recommendedFloor.isEmpty ? "暂无" : period.recommendedFloor)")
        if !period.recommendation.isEmpty {
            for line in DeviceText.wrap(period.recommendation, limit: 2) {
                screen.text(line)
            }
        }
        screen.spacer()
        let floors = Self.floorSummary(period.outlets)
        for floor in floors.prefix(5) {
            screen.text(floor)
        }
        screen.footer = MealDateNavigation.dates(in: value.weeks).count > 1
            ? "上/下换天  确定午/晚"
            : "仅今日菜单  确定午/晚"
        return screen
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
    @ObservedObject var model: MealApp

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
