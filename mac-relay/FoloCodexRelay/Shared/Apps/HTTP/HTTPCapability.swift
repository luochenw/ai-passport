import Foundation

// =====================================================================
// 通用能力:定时拉一个 JSON
//
// 这是清单体系里缺掉的那块拼图。
//
// 之前三个能力(walkie / meal / codex)都是"某个应用的后半截",不是通用
// 原语:`meal` 暴露的是"本周菜单",不是"定时拉一个 JSON"。结果就是,哪怕
// 把注册表做好,拿现有能力也拼不出真正的新应用 —— 只能拼出同一个应用的
// 另一个视图。所以"加一份清单就多一个应用"当时是句空话。
//
// 这个能力不认识任何业务:它按配置去 GET 一个 JSON,把**整棵响应树**放进
// `data` 交给模板。天气、CI 状态、家里的传感器、自建 API、被删掉的那个 NAS
// 面板 —— 都是同一个形状,区别只在清单怎么画和配置里的 URL。
//
// 每份清单一个实例、一份配置:配置在 `~/.folotoy/apps/<清单id>.json`,
// 不在仓库里(所以私有服务的地址和凭据不会被公开)。
//
//     {
//       "url": "https://example.invalid/api/status",
//       "intervalSeconds": 30,
//       "headers": { "Authorization": "Bearer …" },
//       "certificateSHA256": "服务器叶子证书的 SHA-256(自签名时才需要)"
//     }
//
// 清单里就这么用:
//
//     { "text": "CPU  {{data.cpu.percent|fixed:1}}%" }
//     { "each": { "path": "data.disks", "body": [ { "text": "{{item.name}}" } ] } }
// =====================================================================

final class HTTPCapability: NSObject, AppCapability {
    static let id = "http"

    struct Config: Decodable {
        let url: String
        /// 多久拉一次。不写默认 30 秒;低于 5 秒会被抬到 5 秒 ——
        /// 一个手表大小的屏幕不需要更快,而更快很容易把对端打疼。
        let intervalSeconds: Double?
        let headers: [String: String]?
        /// 自签名证书的指纹。私有部署常见:IP 直连 + 自签名,系统校验必然
        /// 过不去。填了就只信这一张证书 —— 比"关掉校验"强得多,后者等于
        /// 对任何中间人敞开。
        let certificateSHA256: String?
    }

    /// 配置和清单同名:一份清单一份配置,互不干扰。
    private let configID: String
    private var config: Config? { AppConfigStore.load(Config.self, for: configID) }

    var onChange: (() -> Void)?
    var notify: ((String) -> Void)?

    private var payload: JSONValue = .null
    private var lastError: String?
    private var loaded = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.folotoy.codexrelay.http")

    init(configID: String) {
        self.configID = configID
    }

    // MARK: 状态

    func state() -> JSONValue {
        .object([
            "connected": .bool(loaded && lastError == nil),
            "status": .string(lastError ?? (loaded ? "已更新" : "读取中…")),
            "data": payload,
        ])
    }

    var overlay: AppOverlay? {
        guard config != nil else {
            return .notConfigured(what: configID,
                                  path: AppConfigStore.displayPath(for: configID))
        }
        if let lastError, !loaded { return .error(lastError) }
        if !loaded { return .loading(configID) }
        return nil
    }

    func dismissOverlayError() -> Bool {
        guard lastError != nil, !loaded else { return false }
        lastError = nil
        onChange?()
        return true
    }

    // MARK: 生命周期

    func setActive(_ active: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            guard active else { return }
            // ⚠ 只在用户真的在看这个应用时才轮询。设备上一次只显示一屏,
            // 后台替所有 http 应用一直拉,是白烧对端的配额和这台机器的电。
            let interval = max(5, self.config?.intervalSeconds ?? 30)
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: interval)
            t.setEventHandler { [weak self] in self?.fetch() }
            t.resume()
            self.timer = t
        }
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        guard action == "refresh" else { return false }
        queue.async { [weak self] in self?.fetch() }
        return true
    }

    // MARK: 拉取

    private func fetch() {
        guard let cfg = config, let url = URL(string: cfg.url) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in cfg.headers ?? [:] { request.setValue(v, forHTTPHeaderField: k) }

        let delegate = PinnedCertificateDelegate(allowedHost: url.host,
                                                 certificateSHA256: cfg.certificateSHA256)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                // ⚠ 日志里只写主机名,不写 URL 全文、不写响应体、更不写任何
                // 请求头 —— 凭据就在那些地方。
                let host = url.host ?? "-"
                if let error {
                    self.finish(error: "请求失败 \(host): \(error.localizedDescription)")
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    self.finish(error: "HTTP \(code) \(host)")
                    return
                }
                guard let data,
                      let any = try? JSONSerialization.jsonObject(with: data) else {
                    self.finish(error: "返回的内容不是 JSON \(host)")
                    return
                }
                self.payload = JSONValue(any: any)
                self.loaded = true
                self.lastError = nil
                log("[http:\(self.configID)] 获取成功 host=\(host) bytes=\(data.count)")
                self.onChange?()
            }
            session.finishTasksAndInvalidate()
        }.resume()
    }

    private func finish(error: String) {
        lastError = error
        log("[http:\(configID)] \(error)")
        onChange?()
    }
}

/// 只信一张指定证书。
///
/// 没填指纹就走系统默认校验 —— 公网上的正规证书本来就该这么校。填了才切到
/// 固定模式,这样"要连自签名的私有服务"不会变成"对所有主机都不校验"。
private final class PinnedCertificateDelegate: NSObject, URLSessionDelegate {
    private let allowedHost: String?
    private let expected: String?

    init(allowedHost: String?, certificateSHA256: String?) {
        self.allowedHost = allowedHost?.lowercased()
        self.expected = certificateSHA256?.lowercased()
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        guard let expected,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == allowedHost,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let actual = Digest.sha256Hex(SecCertificateCopyData(leaf) as Data)
        if actual == expected {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            log("[http] 证书指纹不符,拒绝连接 host=\(challenge.protectionSpace.host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
