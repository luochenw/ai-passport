import Foundation

// =====================================================================
// 从 GitHub 更新应用
//
// 拉的是**清单**,不是代码 —— Swift 是 AOT 编译的,iOS 也明令禁止下载并
// 执行代码(App Store 2.5.2)。清单是数据,由 ManifestApp 解释;能力(实时
// 音频、子进程、文件轮询)永远编在 app 里。
//
// 协议:
//   GET <base>/registry.json
//   → [ { "id", "name", "version", "url", "sha256" } ]
//
//   · url    可以是绝对地址,也可以是相对 registry.json 的相对路径
//   · sha256 是那份清单 JSON 的十六进制摘要,**必须提供且必须校验**
//
// 为什么 sha256 是必须的:这份 JSON 会被解释成设备上显示的每一行字和每一个
// 按键绑定。传输层能保证不错位,但证明不了"这台电脑下载到的就是作者发布的
// 那一份" —— 中间的 CDN、代理、被截断的响应、服务器上被替换过的文件,都
// 只能靠内容摘要发现。而且必须在**写进缓存之前**校验:写进去之后再发现不对,
// 下次启动就已经在用坏的那份了。
//
// 整条链路是**尽力而为**的:拉不到、校验不过、解析不了,都退回上一次缓存或
// 内置版本。一次断网不该让所有应用消失。
// =====================================================================

enum AppRegistry {

    /// registry.json 在哪儿。
    ///
    /// 放 UserDefaults 而不是写死:自己 fork 一份、或者内网镜像,不该要求
    /// 重新编译。改的办法:
    ///
    ///     defaults write com.folotoy.codexrelay manifests.registryBase \\
    ///         "https://raw.githubusercontent.com/<你的账号>/ai-passport/<分支>/mac-relay/AppManifests/"
    ///
    /// 默认值指向**这个仓库自己的 main**,而不是上游。
    ///
    /// 一开始写的是上游 FoloToy/ai-passport,理由是"源码里不该出现某个人的
    /// 账号名"。那个理由在这里不成立,而且代价是功能根本不工作:清单是这个
    /// 仓库的产物,上游没有也不会有,于是每次启动都是
    ///     [registry] 拉取失败 HTTP 404
    /// 一直在用 bundle 里那份内置副本 —— "从 GitHub 更新应用"从未真正跑通过。
    ///
    /// 而且这个仓库并不是上游的 fork(GitHub 上 fork=false,没有 parent),
    /// 它就是这些清单的发布地。分发地址指向发布地是本来就该有的样子。
    private static let baseKey = "manifests.registryBase"

    static var base: URL? {
        if let s = UserDefaults.standard.string(forKey: baseKey), let u = URL(string: s) {
            return u
        }
        return URL(string: "https://raw.githubusercontent.com/luochenw/ai-passport/main/mac-relay/AppManifests/")
    }

    static func setBase(_ urlString: String) {
        UserDefaults.standard.set(urlString, forKey: baseKey)
    }

    struct Entry: Decodable {
        let id: String
        let name: String?
        let version: String?
        let url: String
        let sha256: String
    }

    /// 拉一遍并更新缓存。
    ///
    /// ⚠ 生效时机要说清楚:应用是在**设备连上时**从 ManifestStore 建出来的。
    /// 这次拉取只更新缓存,已经建好的会话不会当场换掉屏幕 —— 下一台设备
    /// 连上、或者下次启动才用新的。这是刻意的:一个应用正在用户手里显示着
    /// 的时候,把它的屏幕定义换掉,按键含义会在他手底下变。
    static func refresh(completion: (() -> Void)? = nil) {
        guard let base else { completion?(); return }
        let registryURL = base.appendingPathComponent("registry.json")

        var request = URLRequest(url: registryURL)
        // 短超时:这是启动路径上的一次网络请求,拉不到就用缓存,不该让
        // 用户对着一个没有设备的窗口等半分钟。
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { completion?() }
            if let error {
                log("[registry] 拉取失败,继续用本地清单: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                log("[registry] 拉取失败 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            guard let data, let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
                log("[registry] registry.json 解析失败,继续用本地清单")
                return
            }
            log("[registry] 目录里有 \(entries.count) 份清单")
            for entry in entries {
                fetchManifest(entry, base: base)
            }
        }.resume()
    }

    private static func fetchManifest(_ entry: Entry, base: URL) {
        guard let url = URL(string: entry.url, relativeTo: base) else {
            log("[registry] \(entry.id) 的地址不合法,跳过")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data, error == nil else {
                log("[registry] \(entry.id) 下载失败,继续用本地那份")
                return
            }
            guard accept(data, for: entry) else { return }
            if ManifestStore.cache(data, id: entry.id) {
                log("[registry] \(entry.id) 已更新\(entry.version.map { "到 \($0)" } ?? "")")
            }
        }.resume()
    }

    /// 这份下载下来的字节,能不能进缓存。
    ///
    /// 从 `fetchManifest` 里单拎出来是为了**能测**:整个方案里唯一有安全后果
    /// 的判断就在这几行,而它原本埋在一个 URLSession 回调里 —— 要覆盖到,
    /// 就得起一个 HTTP 服务、伪造响应,那样的测试笨重到没人愿意维护,于是
    /// 这段最该被测的代码反而一行没测。这里是纯函数:给字节,给条目,给答案。
    static func accept(_ data: Data, for entry: Entry) -> Bool {
        // ⚠ 先校验再落盘。反过来的话,一次被截断的响应会永久地留在缓存里,
        // 而缓存排在查找顺序的第一位 —— 从此每次启动都先读到坏的那份。
        let actual = Digest.sha256Hex(data)
        guard actual == entry.sha256.lowercased() else {
            log("[registry] \(entry.id) 摘要不符,丢弃(期望 \(entry.sha256.prefix(12))…,实得 \(actual.prefix(12))…)")
            return false
        }
        // 校验过了也要能解析 —— 摘要只证明"没被改过",不证明"这个伴侣端
        // 看得懂"。一份用了更新行类型的清单摘要完全正确,但在这里解析
        // 不了,落盘只会让下次启动退回内置版本时多绕一圈。
        guard let manifest = try? AppManifest.decode(data) else {
            log("[registry] \(entry.id) 摘要对但解析不了(可能来自更新的版本),不缓存")
            return false
        }
        // 目录里的 id 和清单里的 id 必须是同一个。不一致的话缓存会以目录说的
        // 那个 id 落盘,而加载时按清单里的 id 找 —— 一份 id 写成 walkie 的
        // 清单被存成 codex.json,点开 Codex 出来的是对讲机的屏幕。目录是从
        // 网上来的,不能默认它跟内容对得上。
        guard manifest.id == entry.id else {
            log("[registry] \(entry.id) 的清单里写的 id 是 \(manifest.id),对不上,不缓存")
            return false
        }
        return true
    }
}
