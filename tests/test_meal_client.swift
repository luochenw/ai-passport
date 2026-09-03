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

@main
struct TestMealClient {
    static func main() {
        check(
            MealClient.mealEndpoint(from: "ws://127.0.0.1:8787/v1/ws")?.absoluteString ==
                "ws://127.0.0.1:8787/v1/meals/ws",
            "对讲服务地址可转换为吃饭服务地址"
        )
        check(
            MealClient.mealEndpoint(from: "http://192.168.1.8:8787")?.absoluteString ==
                "ws://192.168.1.8:8787/v1/meals/ws",
            "HTTP 地址转换为 WebSocket"
        )
        check(MealClient.mealEndpoint(from: "") == nil, "拒绝空地址")

        let json = """
        {
          "type": "meal_state",
          "weeks": [{
            "weekOf": "2026-08-31",
            "building": "示例大厦",
            "source": "示例餐厅",
            "updatedAt": "2026-09-03T11:00:00+08:00",
            "days": [{
              "date": "2026-09-03",
              "weekday": "周四",
              "lunch": {
                "outlets": [],
                "recommendedFloor": "3层",
                "recommendation": "示例水饺、示例汤粉"
              },
              "dinner": {
                "outlets": [],
                "recommendedFloor": "5层",
                "recommendation": "示例烧腊"
              }
            }]
          }]
        }
        """
        let event = try? JSONDecoder().decode(MealServerEvent.self, from: Data(json.utf8))
        check(event?.weeks?.first?.days.first?.lunch.recommendedFloor == "3层",
              "解析周菜单和推荐楼层")

        let sparseJSON = """
        {
          "type": "meal_reminder",
          "reminder": {
            "date": "2026-09-03",
            "meal": "lunch",
            "floor": "2层",
            "message": "午饭去2层"
          }
        }
        """
        let sparseEvent = try? JSONDecoder().decode(
            MealServerEvent.self, from: Data(sparseJSON.utf8))
        check(sparseEvent?.reminder?.summary == "",
              "提醒摘要省略时按空字符串解析")

        let outletJSON = """
        {
          "type": "meal_state",
          "weeks": [{
            "weekOf": "2026-08-31",
            "building": "示例大厦",
            "source": "示例餐厅",
            "updatedAt": "2026-09-03T11:00:00+08:00",
            "days": [{
              "date": "2026-09-03",
              "weekday": "周四",
              "lunch": {
                "outlets": [{"floor": "2层", "name": "示例自助档"}],
                "recommendedFloor": "2层",
                "recommendation": "示例自助档"
              },
              "dinner": {
                "outlets": [],
                "recommendedFloor": "",
                "recommendation": ""
              }
            }]
          }]
        }
        """
        let outletEvent = try? JSONDecoder().decode(
            MealServerEvent.self, from: Data(outletJSON.utf8))
        check(outletEvent?.weeks?.first?.days.first?.lunch.outlets.first?.dishes == [],
              "档口菜品省略时按空列表解析")

        let period = MealPeriod(
            outlets: [], recommendedFloor: "2层", recommendation: "测试")
        let oneDayWeek = MealWeek(
            weekOf: "2026-08-31",
            building: "示例大厦",
            source: "测试",
            updatedAt: "2026-09-03T11:00:00+08:00",
            days: [
                MealDay(date: "2026-09-03", weekday: "周四",
                        lunch: period, dinner: period)
            ])
        check(MealDateNavigation.dates(in: [oneDayWeek]) == [
            "2026-08-31", "2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04"
        ], "单日数据仍提供本周工作日导航")
        check(MealDateNavigation.nextDate(
            in: [oneDayWeek], current: "2026-09-03", delta: 1) == "2026-09-04",
              "单日数据也能切到下一工作日占位页")
        check(MealDateNavigation.nextDate(
            in: [oneDayWeek], current: "2026-09-03", delta: -1) == "2026-09-02",
              "单日数据也能切到上一工作日占位页")

        let twoDayWeek = MealWeek(
            weekOf: oneDayWeek.weekOf,
            building: oneDayWeek.building,
            source: oneDayWeek.source,
            updatedAt: oneDayWeek.updatedAt,
            days: [
                MealDay(date: "2026-09-03", weekday: "周四",
                        lunch: period, dinner: period),
                MealDay(date: "2026-09-04", weekday: "周五",
                        lunch: period, dinner: period)
            ])
        check(MealDateNavigation.nextDate(
            in: [twoDayWeek], current: "2026-09-03", delta: 1) == "2026-09-04",
              "下键切到下一天")
        check(MealDateNavigation.nextDate(
            in: [twoDayWeek], current: "2026-08-31", delta: -1) == "2026-09-04",
              "上键从周一循环到周五")

        // ⚠ 回归:「装没装吃饭」必须按设备记。
        //
        // 这条 bug 的可怕之处是**用户什么都没做**:A 上装了吃饭正在用,把
        // 没装吃饭的 B 插上电,会话建立时 register() 会拿 B 自己的清单调
        // setInstalled(false) —— 共用那一位布尔当场被清掉,连接断开,A 的
        // 屏幕跳成"请先安装应用",这台电脑上排好的饭点提醒被一并删光。
        let suite = "test.meal.\(UUID().uuidString)"
        let mealDefaults = UserDefaults(suiteName: suite)!
        defer { mealDefaults.removePersistentDomain(forName: suite) }
        let shared = MealClient(defaults: mealDefaults)
        check(!shared.currentSnapshot().installed, "初始状态:一台都没装")

        shared.setInstalled(true, for: "devA")
        shared.waitForPendingWork()
        check(shared.currentSnapshot().installed, "A 装上之后服务变成启用")

        // 关键的一步:B 报"我没装",不能把 A 的连上状态踢掉。
        shared.setInstalled(false, for: "devB")
        shared.waitForPendingWork()
        check(shared.currentSnapshot().installed,
              "另一台报未安装,不影响已经装了的那台(核心回归)")

        shared.setInstalled(true, for: "devB")
        shared.waitForPendingWork()
        shared.setInstalled(false, for: "devA")
        shared.waitForPendingWork()
        check(shared.currentSnapshot().installed, "A 卸载后 B 还装着,服务照常")

        shared.setInstalled(false, for: "devB")
        shared.waitForPendingWork()
        check(!shared.currentSnapshot().installed, "最后一台也卸了才真的停用")

        if failures == 0 {
            print("meal client: PASS")
            exit(0)
        }
        exit(1)
    }
}
