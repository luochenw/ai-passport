import Foundation

// =====================================================================
// 服务器面板 —— 第一个远程应用。
//
// 数据由这台电脑去拉(它本来就联着网、有完整的 TLS 栈和 JSON 解析),设备
// 只负责显示。所以设备不需要连 Wi-Fi、不需要 HTTP 客户端、不需要存这个接口
// 的地址和口令。
//
// 整个应用就是这一个文件,几百行 Swift,没有一行嵌入式代码。
// =====================================================================

final class DashboardApp: RemoteApp {
    let name = "服务器面板"
    // 服务器面板 —— 用硬盘/服务器那个图标。
    let defaultIcon = DeviceIcon.find("\u{F01C}").glyph
    let detail = "NAS 状态"
    var requestPush: (() -> Void)?
    var notify: ((String) -> Void)?

    private enum Page: Int, CaseIterable {
        case overview, download, media, network, containers
        var title: String {
            switch self {
            case .overview:   return "总览"
            case .download:   return "下载"
            case .media:      return "媒体库"
            case .network:    return "网络"
            case .containers: return "容器"
            }
        }
    }

    /// 刷新间隔。只在用户正看着这个应用时才走这个定时器(setActive 里起停),
    /// 所以 5 秒的频率不会在没人看的时候空转打接口。
    private static let refreshInterval: TimeInterval = 5

    private var page: Page = .overview
    private var data: DashboardData?
    private var status = "正在获取…"
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.folotoy.codexrelay.dashboard")

    // MARK: 这个应用自己的配置
    //
    // 接口地址和账号口令是**这个应用的内部实现**,不是设备的设置,所以不出现
    // 在通用「配置」页里 —— 那里只放真正属于硬件的东西(音量之类)。把它们
    // 摊成三个通用输入框,既暴露了这个应用的内部细节,也意味着换个应用就要
    // 换一套字段,通用页会越长越乱。
    //
    // 配置放在用户主目录下的一个文件里,不在仓库中,所以口令不可能被提交:
    //
    //   ~/.folotoy/dashboard.json
    //   { "url": "https://…/api/status", "username": "…", "password": "…" }
    //
    // 每次用到时重新读:改完文件立刻生效,不用重启这个 app。文件本身很小,
    // 而请求本来就是十几秒一次,这点读取开销无关紧要。
    private struct Config: Decodable {
        let url: String
        let username: String?
        let password: String?
    }

    /// 这个应用的接口地址和账号口令是**固定的**,不是给用户调的参数 ——
    /// 它就是接我自己那台 NAS。所以没有设置界面,配套 app 里也不出现任何
    /// 输入框:那些是这个应用的内部实现,不该抬到界面上。
    ///
    /// 配置从两个地方找,按顺序:
    ///
    ///  1. `~/.folotoy/dashboard.json`(只有 macOS 有家目录这个概念)
    ///     开发时改完立刻生效,不用重新构建。
    ///  2. app bundle 里的 `dashboard.json` —— 由 build.sh / build-ios.sh
    ///     在构建时从上面那个文件拷进去。
    ///
    /// 第 2 条是 iOS 能跑起来的原因:沙盒里没有家目录,但 bundle 一定在。
    /// `Bundle.main.url(forResource:)` 两端都成立,不需要任何平台判断。
    ///
    /// ⚠ 代价要说清楚:口令因此会躺在构建产物里。在自己机器上、自己手机上
    /// 用没问题(跟原来那个 600 文件是同一个安全水位),但**这个 .app 就
    /// 不能随便发给别人了** —— 谁拿到它就拿到了 NAS 口令。仓库里始终没有
    /// 这个文件,这一点没变。
    private var config: Config? {
        #if os(macOS)
        if let data = FileManager.default.contents(
            atPath: (NSHomeDirectory() as NSString).appendingPathComponent(".folotoy/dashboard.json")),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        #endif
        guard let url = Bundle.main.url(forResource: "dashboard", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    func setActive(_ active: Bool) {
        queue.async {
            if active {
                self.page = .overview
                self.fetch()
                // 用户在看的时候才轮询。走开就停 —— 没人看还定期打接口纯属浪费。
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now() + Self.refreshInterval,
                           repeating: Self.refreshInterval)
                t.setEventHandler { [weak self] in self?.fetch() }
                t.resume()
                self.timer = t
            } else {
                self.timer?.cancel()
                self.timer = nil
            }
        }
    }

    func handleKey(_ button: RemoteButton, _ event: RemoteButtonEvent) -> Bool {
        guard event == .click || event == .hold else { return false }
        switch button {
        case .up:
            let all = Page.allCases
            let i = (page.rawValue - 1 + all.count) % all.count
            page = all[i]
            return true
        case .down:
            let all = Page.allCases
            page = all[(page.rawValue + 1) % all.count]
            return true
        case .ok:
            status = "正在刷新…"
            queue.async { self.fetch() }
            return true
        }
    }

    func render() -> Screen {
        var s = Screen()
        s.title = "\(page.title)  \(page.rawValue + 1)/\(Page.allCases.count)"

        guard let d = data else {
            if config == nil {
                s.text("未配置")
                s.spacer()
                s.text("~/.folotoy/dashboard.json")
                s.text("缺失或格式不对")
            } else {
                s.text(status)
            }
            s.footer = "双击确定返回列表"
            return s
        }

        switch page {
        case .overview:
            s.bar("CPU", percent: d.cpuPercent)
            s.bar("内存 \(d.memUsed)/\(d.memTotal)", percent: d.memPercent)
            for disk in d.disks {
                s.bar("\(disk.label) \(disk.used)/\(disk.total)", percent: disk.usedPercent)
            }
            s.spacer()
            s.text(String(format: "负载 %.2f / %.2f / %.2f", d.load1, d.load5, d.load15))

        case .download:
            if d.aria2OK {
                s.text("下行  \(d.downSpeed)")
                s.text("上行  \(d.upSpeed)")
                s.spacer()
                s.text("进行中   \(d.active)")
                s.text("等待中   \(d.waiting)")
                s.text("已完成   \(d.stopped)")
            } else {
                s.text("下载器未运行")
            }

        case .media:
            if d.mediaOK {
                s.text("电影   \(d.movies)")
                s.text("剧集   \(d.series)")
                s.text("集数   \(d.episodes)")
                s.spacer()
                s.text("正在播放   \(d.nowPlaying)")
            } else {
                s.text("媒体库未运行")
            }

        case .network:
            s.text("节点")
            s.text(d.node.isEmpty ? "-" : d.node)
            s.spacer()
            s.text("连接数   \(d.connections)")
            s.text(String(format: "累计上行 %.1f GB", d.upTotalGB))
            s.text(String(format: "累计下行 %.1f GB", d.downTotalGB))
            s.spacer()
            s.text("Tailscale  \(d.tailscaleOK ? "在线" : "离线")")
            s.text("frp        \(d.frpOK ? "已连接" : "断开")")

        case .containers:
            if d.containers.isEmpty {
                s.text("没有容器")
            } else {
                for c in d.containers.prefix(10) {
                    s.text("\(c.healthy ? "+" : "x") \(c.name)")
                }
            }
        }

        if page == .containers {
            let running = d.containers.filter { $0.running }.count
            s.footer = "运行 \(running)/\(d.containers.count)  上/下翻页"
        } else {
            s.footer = "上/下翻页  确定刷新"
        }
        return s
    }

    // MARK: 取数据

    private func fetch() {
        guard let cfg = config, let url = URL(string: cfg.url) else { return }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let user = cfg.username, !user.isEmpty {
            let cred = "\(user):\(cfg.password ?? "")"
            if let d = cred.data(using: .utf8) {
                req.setValue("Basic \(d.base64EncodedString())", forHTTPHeaderField: "Authorization")
            }
        }

        // 私有服务通常是自签名证书 + IP 直连,系统的证书校验必然过不去。
        // 由 InsecureTLSDelegate 放行 —— 取舍和风险见那个类的注释。
        let session = URLSession(configuration: .ephemeral,
                                 delegate: InsecureTLSDelegate.shared,
                                 delegateQueue: nil)
        session.dataTask(with: req) { [weak self] body, response, error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    self.status = "请求失败:\(error.localizedDescription)"
                    self.requestPush?()
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    self.status = "服务器返回 HTTP \(http.statusCode)"
                    self.requestPush?()
                    return
                }
                guard let body = body,
                      let parsed = DashboardData(json: body) else {
                    self.status = "返回的不是预期的 JSON"
                    self.requestPush?()
                    return
                }
                self.data = parsed
                self.status = ""
                self.requestPush?()
            }
        }.resume()
    }
}

/// 放行自签名证书。
///
/// ⚠ 这条连接因此挡不住中间人:能劫持它的人可以看到 Basic 认证的口令,也能
/// 伪造面板数据。之所以接受:目标是自家内网、用 IP 直连的私有服务,公共 CA
/// 不可能给它签发证书,校验必然失败,功能就没法用;而这些数据是只读展示,
/// 设备不会因为它们做任何有副作用的事。
///
/// 如果要拿它访问公网上的重要服务,应该改成固定那张自签名证书(把它的
/// SHA-256 存下来逐次比对),而不是继续无条件放行。
final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    static let shared = InsecureTLSDelegate()

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - 数据模型

struct DashboardData {
    struct Disk { let label: String; let usedPercent: Double; let used: String; let total: String }
    struct Container { let name: String; let running: Bool; let healthy: Bool }

    var aria2OK = false
    var downSpeed = "-", upSpeed = "-"
    var active = 0, waiting = 0, stopped = 0

    var mediaOK = false
    var movies = 0, series = 0, episodes = 0, nowPlaying = 0

    var cpuPercent = 0.0, memPercent = 0.0
    var memUsed = "-", memTotal = "-"
    var load1 = 0.0, load5 = 0.0, load15 = 0.0
    var disks: [Disk] = []
    var containers: [Container] = []

    var node = "", connections = 0
    var upTotalGB = 0.0, downTotalGB = 0.0
    var tailscaleOK = false, frpOK = false

    /// 同一个含义的字段在这个接口里有时是字符串有时是数字(nastool 的
    /// movie_count 是 "303",jellyfin 的是 303),所以两种都要认。
    private static func num(_ o: [String: Any]?, _ key: String) -> Double {
        guard let v = o?[key] else { return 0 }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    private static func str(_ o: [String: Any]?, _ key: String, _ fallback: String = "-") -> String {
        guard let v = o?[key] else { return fallback }
        if let s = v as? String { return s }
        if let d = v as? Double { return String(format: "%.0f", d) }
        if let i = v as? Int { return String(i) }
        return fallback
    }

    private static func ok(_ o: [String: Any]?) -> Bool { (o?["ok"] as? Bool) ?? false }

    init?(json: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            return nil
        }

        let aria2 = root["aria2"] as? [String: Any]
        if Self.ok(aria2) {
            aria2OK = true
            downSpeed = Self.str(aria2, "download_speed")
            upSpeed   = Self.str(aria2, "upload_speed")
            active    = Int(Self.num(aria2, "num_active"))
            waiting   = Int(Self.num(aria2, "num_waiting"))
            stopped   = Int(Self.num(aria2, "num_stopped"))
        }

        // 媒体库优先取 jellyfin(字段是规整的数字),没有再退回 nastool。
        let jelly = root["jellyfin"] as? [String: Any]
        let nas   = root["nastool"] as? [String: Any]
        if let src = Self.ok(jelly) ? jelly : (Self.ok(nas) ? nas : nil) {
            mediaOK  = true
            movies   = Int(Self.num(src, "movie_count"))
            series   = Int(Self.num(src, "series_count"))
            episodes = Int(Self.num(src, "episode_count"))
            nowPlaying = (src["now_playing"] as? [Any])?.count ?? 0
        }

        let sys = root["system"] as? [String: Any]
        if Self.ok(sys) {
            cpuPercent = Self.num(sys, "cpu_percent")
            memPercent = Self.num(sys, "mem_percent")
            memUsed    = Self.str(sys, "mem_used")
            memTotal   = Self.str(sys, "mem_total")
            if let la = sys?["load_avg"] as? [Any], la.count >= 3 {
                load1  = (la[0] as? Double) ?? 0
                load5  = (la[1] as? Double) ?? 0
                load15 = (la[2] as? Double) ?? 0
            }
            for d in (sys?["disks"] as? [[String: Any]]) ?? [] {
                disks.append(Disk(label: Self.str(d, "label", "磁盘"),
                                  usedPercent: Self.num(d, "used_percent"),
                                  used: Self.str(d, "used"),
                                  total: Self.str(d, "total")))
            }
            for c in (sys?["containers"] as? [[String: Any]]) ?? [] {
                let running = Self.str(c, "status", "") == "running"
                let health = c["health"] as? String
                // health 为 null 不代表不健康 —— 大量镜像根本没配 healthcheck,
                // 一律判红会让整屏都是红叉。这时跟随 running。
                containers.append(Container(name: Self.str(c, "name", "?"),
                                            running: running,
                                            healthy: health.map { $0 == "healthy" } ?? running))
            }
        }

        if let net = root["network"] as? [String: Any] {
            let mi = net["mihomo"] as? [String: Any]
            node        = Self.str(mi, "current_node", "")
            connections = Int(Self.num(mi, "active_connections"))
            // 累计流量是字节,屏幕上放不下 11 位数字,折算成 GB。
            upTotalGB   = Self.num(mi, "upload_total") / 1_073_741_824
            downTotalGB = Self.num(mi, "download_total") / 1_073_741_824
            tailscaleOK = ((net["tailscale"] as? [String: Any])?["self_online"] as? Bool) ?? false
            frpOK       = ((net["frp"] as? [String: Any])?["connected"] as? Bool) ?? false
        }
    }
}
