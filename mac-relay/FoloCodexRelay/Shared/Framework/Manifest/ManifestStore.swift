import Foundation

// =====================================================================
// 清单从哪儿来
//
// 三档,先命中先用:
//
//   1. 缓存 —— 上次从 GitHub 拉下来并校验过 sha256 的那份
//   2. 源码树旁边的 AppManifests/ —— 只在 macOS 开发时有,改完立刻生效
//
// ⚠ **没有 bundle 兜底**,这是刻意的。
//
// 原来有第三档"随 app 分发的内置副本",出发点是"一次断网不该让所有应用
// 消失"。但它的实际效果是**把失败藏起来**:默认地址曾经指错、连着几周
// 每次启动都 404,而界面上一切正常 —— 因为内置副本顶上了。等到发现的时候,
// "从 GitHub 更新应用"这个功能从来没有真正跑通过。
//
// 现在的规矩是:拉不到就没有这个应用,并且说出来。少一个图标是看得见的,
// 静默用着三个月前的旧清单不是。
// =====================================================================

enum ManifestStore {

    /// 从 GitHub 拉下来的清单缓存在哪儿。跟应用配置分开放 —— 配置是用户的
    /// (要备份、含口令),缓存是可以随时删掉重下的。
    static var cacheDirectory: URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("FoloCodexRelay/manifests", isDirectory: true)
    }

    /// 内置清单在源码树里的位置(开发时用)。
    ///
    /// ⚠ 用 `#filePath` 往上数目录层数 —— 这个文件在
    /// Shared/Framework/Manifest/ 下,所以要往上四层才到 mac-relay/。
    /// 层数写错不会报错,只会静默找不到,然后悄悄退到 bundle 那一档。
    private static var sourceDirectory: URL? {
        #if os(macOS)
        let here = URL(fileURLWithPath: #filePath)          // …/Shared/Framework/Manifest/ManifestStore.swift
        let macRelay = here
            .deletingLastPathComponent()                    // Manifest/
            .deletingLastPathComponent()                    // Framework/
            .deletingLastPathComponent()                    // Shared/
            .deletingLastPathComponent()                    // FoloCodexRelay/
            .deletingLastPathComponent()                    // mac-relay/
        let dir = macRelay.appendingPathComponent("AppManifests", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
        #else
        return nil
        #endif
    }

    /// 按顺序找一份清单。全都没有就返回 nil —— 调用方据此跳过这个应用,
    /// 而不是注册一个画不出东西的空壳。
    static func load(_ id: String) -> AppManifest? {
        let dirs = [cacheDirectory, sourceDirectory].compactMap { $0 }
        for dir in dirs {
            let url = dir.appendingPathComponent("\(id).json")
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            do {
                let manifest = try AppManifest.decode(data)
                warnIfShadowingSource(id: id, winner: dir, data: data)
                return manifest
            } catch {
                // ⚠ 解析失败要**继续往下找**,不能就此放弃。
                //
                // 最可能坏的恰恰是缓存那一份:它来自网上,可能是被截断的响应,
                // 也可能来自一个比这个伴侣端更新的版本、用了这里还不认识的
                // 行类型。这种时候退回内置版本,应用照常能用 —— 而不是因为
                // 一次坏下载就永久消失。
                log("[manifest] \(id) 从 \(dir.lastPathComponent) 解析失败,继续找下一档: \(error)")
                continue
            }
        }
        log("[manifest] 找不到 \(id) 的清单")
        return nil
    }

    /// 缓存盖住源码树里那份、而且两份内容不一样时,喊一声。
    ///
    /// 开发时踩这个坑代价很高:你改了 AppManifests/walkie.json,重启,
    /// 屏幕纹丝不动 —— 因为上一次从网上拉的那份还在缓存里,而缓存排在
    /// 查找顺序第一位。没有任何报错,看起来就像"我的改动没生效",于是
    /// 开始怀疑模板、怀疑解释器、怀疑设备。
    ///
    /// 不改查找顺序:缓存必须排第一,否则"从网上更新应用"在开发机上
    /// 永远测不到。所以是留一行日志,外加下面这行清缓存的命令。
    private static func warnIfShadowingSource(id: String, winner: URL, data: Data) {
        guard winner == cacheDirectory, let source = sourceDirectory else { return }
        let sourceURL = source.appendingPathComponent("\(id).json")
        guard let local = FileManager.default.contents(atPath: sourceURL.path),
              local != data else { return }
        log("[manifest] ⚠ \(id) 用的是缓存那份,源码树里的改动没生效。"
            + "清掉:rm -rf \(cacheDirectory.path)")
    }

    /// 现在手上有哪些清单。
    ///
    /// 这是"加一份 JSON 就多一个应用"的前提 —— 在此之前 DeviceSession 是把
    /// 三个 id 写死在代码里逐个 load 的,往目录里放第四份清单根本没有任何
    /// 代码会去找它。
    static func allIDs() -> [String] {
        var ids: Set<String> = []
        for dir in [cacheDirectory, sourceDirectory].compactMap({ $0 }) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where name.hasSuffix(".json") {
                let id = String(name.dropLast(5))
                // registry.json 是目录本身,不是清单。
                if id != "registry" { ids.insert(id) }
            }
        }
        return ids.sorted()
    }

    /// 把拉下来的清单写进缓存。**调用方必须已经校验过 sha256** —— 这里
    /// 不校验,因为校验必须发生在"决定要用它"之前,不是写盘之前。
    @discardableResult
    static func cache(_ data: Data, id: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory,
                                                    withIntermediateDirectories: true)
            try data.write(to: cacheDirectory.appendingPathComponent("\(id).json"),
                           options: .atomic)
            return true
        } catch {
            log("[manifest] 缓存 \(id) 失败: \(error.localizedDescription)")
            return false
        }
    }
}
