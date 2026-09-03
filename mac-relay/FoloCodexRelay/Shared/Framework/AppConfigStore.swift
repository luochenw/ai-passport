import Foundation

// =====================================================================
// 应用配置:每个应用一个文件,只在本地
//
// 一条规矩:**配置永远不进仓库,也不进默认的构建产物。**
//
// 在这之前有两处违反它。一处是每个应用各写一遍"先看家目录、再看 bundle"
// 的查找逻辑(DashboardApp 和 MealClient 里各一份,逐字一样);另一处更要命
// —— build.sh 会把 `~/.folotoy/*.json` 无条件拷进 `.app/Contents/Resources/`,
// 于是口令躺在构建产物里,那个 .app 就再也不能发给别人了。脚本自己的注释
// 承认了这件事,但默认行为没变。
//
// 现在:查找逻辑收在这里一份;拷进 bundle 改成显式 opt-in
// (`FOLO_BUNDLE_CONFIG=1`),默认构建出来的产物不含任何配置。
// =====================================================================

enum AppConfigStore {

    /// 配置目录。macOS 是 `~/.folotoy/apps/`;iOS 沙盒里没有家目录,用应用
    /// 自己的 Application Support。
    static var directory: URL {
        #if os(macOS)
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".folotoy/apps", isDirectory: true)
        #else
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("FoloCodexRelay/apps", isDirectory: true)
        #endif
    }

    /// 界面上告诉用户"配置该放哪儿"时用这个,不要在各处硬编码路径字符串。
    static func displayPath(for appID: String) -> String {
        #if os(macOS)
        return "~/.folotoy/apps/\(appID).json"
        #else
        return directory.appendingPathComponent("\(appID).json").path
        #endif
    }

    /// 按顺序找,第一个命中的赢:
    ///
    ///  1. `<配置目录>/<id>.json` —— 每应用一份,新的标准位置
    ///  2. `~/.folotoy/<id>.json` —— 单文件时代的老位置(仅 macOS)。
    ///     留着是为了老用户升级上来配置不会突然消失;新写入一律去 1。
    ///  3. bundle 里的 `<id>.json` —— **只有** `FOLO_BUNDLE_CONFIG=1` 的
    ///     个人构建才有。默认产物里没有,所以这一条平时命不中。
    static func data(for appID: String) -> Data? {
        let fm = FileManager.default
        let primary = directory.appendingPathComponent("\(appID).json")
        if let data = fm.contents(atPath: primary.path) { return data }

        #if os(macOS)
        let legacy = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".folotoy/\(appID).json")
        if let data = fm.contents(atPath: legacy) { return data }
        #endif

        if let url = Bundle.main.url(forResource: appID, withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        return nil
    }

    static func load<T: Decodable>(_ type: T.Type, for appID: String) -> T? {
        guard let data = data(for: appID) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// 写回配置。权限 600 —— 这些文件里会有口令。
    ///
    /// 只写标准位置,不回写老位置也不碰 bundle:bundle 在 iOS 上是只读的,
    /// 而"两个位置都能被写"意味着以后必然有一次改了这份、读到那份。
    @discardableResult
    static func save(_ data: Data, for appID: String) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("\(appID).json")
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            // ⚠ 只记状态,不记内容 —— 这里面是口令。
            log("[config] 写入 \(appID) 配置失败: \(error.localizedDescription)")
            return false
        }
    }
}
