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
        check(
            MealClient.mealEndpoint(from: "203.0.113.8")?.absoluteString ==
                "ws://203.0.113.8:8788/v1/meals/ws",
            "公网 IP 可省略协议和默认端口"
        )
        check(
            MealClient.mealEndpoint(from: "canteen.example.com:9000")?.absoluteString ==
                "ws://canteen.example.com:9000/v1/meals/ws",
            "保留显式餐厅服务端口"
        )
        check(MealClient.mealEndpoint(from: "") == nil, "拒绝空地址")

        let configDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"]!)
            .appendingPathComponent(".folotoy/apps", isDirectory: true)
        try! FileManager.default.createDirectory(at: configDir,
                                                 withIntermediateDirectories: true)
        try! Data(#"{"server":"203.0.113.8:8788"}"#.utf8)
            .write(to: configDir.appendingPathComponent("meal.json"))
        let configSuite = "test.meal.config.\(UUID().uuidString)"
        let configDefaults = UserDefaults(suiteName: configSuite)!
        defer { configDefaults.removePersistentDomain(forName: configSuite) }
        let configured = MealClient(defaults: configDefaults,
                                    loadSharedToken: { "" },
                                    storeSharedToken: { _ in })
        check(configured.currentConfiguration().server ==
              "ws://203.0.113.8:8788/v1/meals/ws",
              "从标准本地配置读取餐厅服务地址")
        try? FileManager.default.removeItem(at: configDir.appendingPathComponent("meal.json"))

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
        check(MealDateNavigation.monthDay(for: "2026-09-08") == "9/8",
              "标题日期使用紧凑月/日格式")

        let longPeriod = MealPeriod(
            outlets: [
                MealOutlet(floor: "10层", name: "面档",
                           dishes: ["牛肉面", "番茄鸡蛋面", "炸酱面"]),
                MealOutlet(floor: "2层", name: "2层-2层-自助档",
                           dishes: ["红烧肉", "清蒸鱼", "时蔬", "例汤", "红烧肉"]),
            ],
            recommendedFloor: "2层",
            recommendation: "红烧肉、清蒸鱼和时蔬")
        func wrap(_ text: String, reserved: Int) -> [String] {
            let width = reserved == 0 ? 100 : max(1, 5 - reserved)
            return stride(from: 0, to: text.count, by: width).map { start in
                let from = text.index(text.startIndex, offsetBy: start)
                let to = text.index(from, offsetBy: min(width, text.count - start))
                return String(text[from..<to])
            }
        }
        let menuPages = MealMenuPagination.pages(
            for: longPeriod, rowsPerPage: 4, wrapping: wrap)
        let menuRows = menuPages.flatMap { $0 }
        check(menuRows.first == MealMenuRow(text: "推荐｜2层", style: .accent),
              "推荐块标题使用强调层级")
        check(menuRows.contains { $0.text == "2层｜自助档" && $0.style == .accent },
              "档口标题去掉重复楼层前缀")
        check(menuRows.firstIndex { $0.text.hasPrefix("2层｜") }! <
              menuRows.firstIndex { $0.text.hasPrefix("10层｜") }!, "菜单按楼层数字排序")
        check(menuPages.allSatisfy { $0.count <= 4 }, "每页不超过设定行数")
        check(menuPages.allSatisfy { page in
            guard let last = page.last else { return true }
            return last.style != .accent || !longPeriod.outlets.contains {
                last.text == $0.floor || last.text.contains($0.name)
            }
        }, "有菜品的档口标题不会孤立在页尾")
        let continued = menuPages.filter { $0.first?.text.hasPrefix("续｜") == true }
        check(!continued.isEmpty && continued.allSatisfy {
            $0.count >= 2 && $0[0].style == .accent && $0[1].style == .body
        }, "跨页首行重复档口标题，后面紧跟菜品")
        let visibleText = menuRows.filter { $0.style == .body }
            .map { $0.text.trimmingCharacters(in: .whitespaces) }.joined()
        for dish in ["红烧肉", "清蒸鱼", "时蔬", "例汤", "牛肉面", "番茄鸡蛋面", "炸酱面"] {
            check(visibleText.contains(dish), "完整保留菜品：\(dish)")
        }
        check(menuRows.filter { $0.text.contains("红烧肉") }.count == 2,
              "推荐与档口各显示一次红烧肉，档口内重复菜品已去重")
        check(menuRows.filter { $0.style == .body }.allSatisfy { $0.text.hasPrefix("  ") },
              "菜品行统一缩进并使用正文层级")
        check(MealMenuPagination.status(pageIndex: 0, pageCount: 3) == "1/3",
              "页码只显示当前页/总页数")
        check(MealMenuPagination.status(pageIndex: 9, pageCount: 3) == "3/3",
              "页码越界时回落到有效范围")

        let emptyPeriod = MealPeriod(
            outlets: [MealOutlet(floor: "7层", name: "7层-空档口", dishes: [])],
            recommendedFloor: "", recommendation: "")
        check(!MealMenuPagination.hasMenu(emptyPeriod), "空推荐和空菜品判定为本餐无菜单")
        check(MealMenuPagination.pages(for: emptyPeriod, wrapping: wrap) == [[]],
              "空餐次不生成推荐或孤立档口标题")

        let noRecommendation = MealPeriod(
            outlets: [MealOutlet(floor: "7层", name: "7层-面档", dishes: ["牛肉面"])],
            recommendedFloor: "7层", recommendation: "")
        let noRecommendationRows = MealMenuPagination.pages(
            for: noRecommendation, wrapping: wrap).flatMap { $0 }
        check(noRecommendationRows.first?.text == "7层｜面档" &&
              !noRecommendationRows.contains { $0.text.hasPrefix("推荐") },
              "空推荐不生成推荐标题，有菜档口仍正常显示")

        let boundaryPeriod = MealPeriod(
            outlets: [MealOutlet(floor: "7层", name: "7层-面档", dishes: ["牛肉面"])],
            recommendedFloor: "2层", recommendation: "ABCDEFG")
        let boundaryPages = MealMenuPagination.pages(
            for: boundaryPeriod, rowsPerPage: 9,
            wrapping: { text, reserved in
                if reserved == 2 && text == "ABCDEFG" { return text.map(String.init) }
                return [text]
            })
        check(boundaryPages.count == 2 && boundaryPages[0].count == 8 &&
              boundaryPages[0].last?.style == .body &&
              boundaryPages[1].first?.text == "7层｜面档",
              "页尾只剩一行时，下一档口标题连同首条菜品移到下一页")

        let longTitle = "7层｜超级超级超级超级超级档口"
        let longTitlePeriod = MealPeriod(
            outlets: [MealOutlet(floor: "7层", name: "7层-超级超级超级超级超级档口",
                                 dishes: [String(repeating: "菜", count: 40)])],
            recommendedFloor: "", recommendation: "")
        let longTitlePages = MealMenuPagination.pages(
            for: longTitlePeriod, wrapping: { text, reserved in
                let width = reserved == 0 ? 6 : 4
                return stride(from: 0, to: text.count, by: width).map { start in
                    let from = text.index(text.startIndex, offsetBy: start)
                    let to = text.index(from, offsetBy: min(width, text.count - start))
                    return String(text[from..<to])
                }
            })
        let firstBody = longTitlePages[0].firstIndex { $0.style == .body }!
        let rebuiltTitle = longTitlePages[0][..<firstBody].map(\.text).joined()
        check(rebuiltTitle == longTitle && !rebuiltTitle.contains("…"),
              "长档口标题使用多行强调色完整显示")
        check(longTitlePages.filter { $0.first?.text.hasPrefix("续") == true }.allSatisfy {
            $0.last?.style == .body && !$0.contains { $0.text.contains("…") }
        }, "长续页标题完整换行，标题后至少保留一条正文")

        let longRecommendationFloor = "超级超级超级超级推荐楼层"
        let longRecommendation = MealPeriod(
            outlets: [], recommendedFloor: longRecommendationFloor,
            recommendation: "推荐菜")
        let longRecommendationPage = MealMenuPagination.pages(
            for: longRecommendation, wrapping: { text, _ in
                stride(from: 0, to: text.count, by: 5).map { start in
                    let from = text.index(text.startIndex, offsetBy: start)
                    let to = text.index(from, offsetBy: min(5, text.count - start))
                    return String(text[from..<to])
                }
            })[0]
        let recommendationBody = longRecommendationPage.firstIndex { $0.style == .body }!
        check(longRecommendationPage[..<recommendationBody].map(\.text).joined() ==
              "推荐｜\(longRecommendationFloor)",
              "长推荐标题也使用多行强调色完整显示")

        // ⚠ 回归:「装没装吃饭」必须按设备记。
        //
        // 这条 bug 的可怕之处是**用户什么都没做**:A 上装了吃饭正在用,把
        // 没装吃饭的 B 插上电,会话建立时 register() 会拿 B 自己的清单调
        // setInstalled(false) —— 共用那一位布尔当场被清掉,连接断开,A 的
        // 屏幕跳成"请先安装应用",这台电脑上排好的饭点提醒被一并删光。
        let suite = "test.meal.\(UUID().uuidString)"
        let mealDefaults = UserDefaults(suiteName: suite)!
        defer { mealDefaults.removePersistentDomain(forName: suite) }
        mealDefaults.set("   ", forKey: "meal.server")
        var storedTokens: [String] = []
        let shared = MealClient(defaults: mealDefaults, loadSharedToken: { "test-token" },
                                storeSharedToken: { storedTokens.append($0) })
        check(shared.currentConfiguration().token == "test-token",
              "从安全存储读取餐厅共享口令")
        check(mealDefaults.string(forKey: "meal.token") == nil,
              "餐厅共享口令不写入 UserDefaults")
        check(shared.currentConfiguration().server == "ws://127.0.0.1:8788/v1/meals/ws",
              "空白的已保存地址不覆盖有效默认地址")
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

        shared.configure(server: "203.0.113.8", token: "updated-token")
        shared.waitForPendingWork()
        check(storedTokens == ["updated-token"], "保存口令时只写安全存储")
        check(mealDefaults.string(forKey: "meal.token") == nil,
              "更新口令后 UserDefaults 仍不含明文")

        if failures == 0 {
            print("meal client: PASS")
            exit(0)
        }
        exit(1)
    }
}
