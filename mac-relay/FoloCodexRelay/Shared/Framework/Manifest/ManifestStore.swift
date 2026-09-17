import Foundation

// =====================================================================
// 清单从哪儿来
//
// 三档,先命中先用:
//
//   1. 缓存 —— 上次从 GitHub 拉下来并校验过 sha256 的那份
//   2. 源码树旁边的 AppManifests/ —— 开发时改完立刻生效,不用重新构建
//   3. bundle 里的 AppManifests/ —— 随 app 分发的内置版本
//
// 第 3 档是**兜底**,不是可选项:第一次装、没网、GitHub 打不开的时候,应用
// 必须照常能用。"从网上更新应用"是锦上添花,不能是运行的前提 —— 否则一次
// 断网就等于所有应用消失。
//
// 顺序里缓存在最前面:拉到新版本之后立刻生效,不用等下一次构建。
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

    /// bundle 里那份。
    private static var bundleDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("AppManifests", isDirectory: true)
    }

    /// 按顺序找一份清单。全都没有就返回 nil —— 调用方据此跳过这个应用,
    /// 而不是注册一个画不出东西的空壳。
    static func load(_ id: String) -> AppManifest? {
        let dirs = [cacheDirectory, sourceDirectory, bundleDirectory].compactMap { $0 }
        for dir in dirs {
            let url = dir.appendingPathComponent("\(id).json")
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            do {
                var manifest = try AppManifest.decode(data)
                // A previously downloaded manifest can outlive an app update.
                // Keep product renames authoritative even while that old cache
                // remains the selected source.
                if manifest.id == "meal", manifest.name == "吃饭" {
                    manifest.name = "字节餐厅"
                    for index in manifest.screens.indices {
                        manifest.screens[index].title = manifest.screens[index].title
                            .replacingOccurrences(of: "default:吃饭", with: "default:字节餐厅")
                    }
                }
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
