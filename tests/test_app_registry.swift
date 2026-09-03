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

private func entry(id: String, sha256: String) -> AppRegistry.Entry {
    AppRegistry.Entry(id: id, name: nil, version: nil, url: "\(id).json", sha256: sha256)
}

/// 一份最小的合法清单。
private let goodJSON = """
{"id":"demo","name":"演示","capability":"demo","screens":[{"title":"标题","rows":[{"text":"一行"}]}]}
"""
private let goodData = Data(goodJSON.utf8)
private let goodHash = Digest.sha256Hex(goodData)

// =====================================================================
// 收下这份字节之前问的三个问题
//
// 这几行是整套"从 GitHub 更新应用"里唯一有安全后果的判断:清单会被解释成
// 设备上显示的每一行字和每一个按键绑定。校验放松一点,后果不是崩溃,是
// **设备安静地按别人写的剧本工作**。
// =====================================================================

@main
struct TestAppRegistry {
    static func main() {
        print("app registry:")

        check(AppRegistry.accept(goodData, for: entry(id: "demo", sha256: goodHash)),
              "摘要对、能解析、id 一致 → 收下")

        check(AppRegistry.accept(goodData, for: entry(id: "demo", sha256: goodHash.uppercased())),
              "目录里的摘要写成大写也认(十六进制没有大小写之分)")

        check(!AppRegistry.accept(goodData, for: entry(id: "demo", sha256: String(repeating: "0", count: 64))),
              "摘要不符 → 丢弃")

        // 被截断的响应是最现实的一种坏数据:HTTP 200、内容看着像 JSON 的开头,
        // 只是少了后半截。它必须被摘要拦下 —— 而不是靠"能不能解析"碰运气。
        check(!AppRegistry.accept(goodData.prefix(40), for: entry(id: "demo", sha256: goodHash)),
              "响应被截断 → 丢弃")

        check(!AppRegistry.accept(Data(), for: entry(id: "demo", sha256: goodHash)),
              "空响应 → 丢弃")

        // 摘要对不代表这边看得懂。来自更新版本、用了这里还不认识的行类型的清单,
        // 摘要完全正确,但不该落盘 —— 落进去只会让下次启动多绕一圈才退回内置版本。
        let notAManifest = Data(#"{"hello":"world"}"#.utf8)
        check(!AppRegistry.accept(notAManifest,
                                  for: entry(id: "demo", sha256: Digest.sha256Hex(notAManifest))),
              "摘要对但解析不了 → 不缓存")

        // 目录说这是 demo,清单里写的是 walkie。缓存按目录说的 id 落盘,加载按
        // 清单里的 id 找 —— 不拦下来,点开一个应用会出来另一个应用的屏幕。
        let mismatched = Data(goodJSON.replacingOccurrences(of: "\"id\":\"demo\"", with: "\"id\":\"walkie\"").utf8)
        check(!AppRegistry.accept(mismatched,
                                  for: entry(id: "demo", sha256: Digest.sha256Hex(mismatched))),
              "清单里的 id 和目录对不上 → 不缓存")

        // =====================================================================
        // 仓库里那份 registry.json 必须真的能通过校验
        //
        // 这一条把 Python 那边的生成器和 Swift 这边的验证器接在了一起。两边只要有
        // 一边动了字节(重新序列化、改缩进、加 BOM、换行尾),摘要立刻对不上,而
        // 线上的表现是**所有清单被静默丢弃、悄悄退回内置版本** —— 没有报错,屏幕
        // 一切正常,只是"从网上更新应用"不工作了。这种失败没有人会发现。
        // =====================================================================

        let manifestDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // tests/
            .deletingLastPathComponent()        // 仓库根
            .appendingPathComponent("mac-relay/AppManifests", isDirectory: true)

        if let registryData = FileManager.default.contents(
                atPath: manifestDir.appendingPathComponent("registry.json").path),
           let entries = try? JSONDecoder().decode([AppRegistry.Entry].self, from: registryData) {

            check(!entries.isEmpty, "registry.json 里有清单")

            var allAccepted = true
            for e in entries {
                guard let data = FileManager.default.contents(
                        atPath: manifestDir.appendingPathComponent(e.url).path) else {
                    print("  ✗ registry.json 指向的 \(e.url) 不存在")
                    allAccepted = false
                    continue
                }
                if !AppRegistry.accept(data, for: e) {
                    print("  ✗ \(e.id): 仓库里的清单通不过自己目录里的校验")
                    allAccepted = false
                }
            }
            check(allAccepted, "registry.json 里每一份清单都通过校验(\(entries.count) 份)")

            let ids = Set(entries.map(\.id))
            check(ids.count == entries.count, "目录里没有重复 id")
        } else {
            check(false, "读得到 registry.json")
        }

        if failures > 0 {
            print("app registry: FAIL (\(failures))")
            exit(1)
        }
        print("app registry: PASS")
    }
}
