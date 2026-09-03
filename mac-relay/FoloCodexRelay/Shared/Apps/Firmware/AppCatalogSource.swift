import Foundation

// =====================================================================
// 应用目录来源:本地目录(开发用)+ 远程 HTTP 接口(社区服务器)。
//
// 两种来源产出同一种 AppCatalogEntry,安装路径完全一致 —— 区别只在"这个
// .bin 是本来就在磁盘上,还是要先下载下来"。
//
// 远程接口约定
// ────────────
//   GET <base>/catalog.json
//   → [ { "id", "name", "description", "version", "size", "sha256", "url" } ]
//
//   · url    可以是绝对地址,也可以是相对 catalog.json 的相对路径
//   · sha256 是 .bin 的十六进制摘要,**必须提供且必须校验**
//   · size   仅用于展示和下载前的粗略检查,不作为完整性依据
//
// 为什么 sha256 是必须的而不是可选的:这些固件是别人开发、要写进 appslot
// 分区并真的启动起来的。传输层本身已经保证了不错位(严格顺序 + 幂等重传),
// 设备端 esp_ota_end() 也会做镜像结构校验 —— 但那两道都只能证明"设备收到的
// 和这台电脑发出去的一致""收到的像个合法镜像",证明不了"这台电脑下载到的
// 就是作者发布的那一份"。中间的 CDN、代理、被截断的响应、服务器上被替换过
// 的文件,都只能靠内容摘要发现。而且必须在**安装之前**校验:等设备写完
// 才发现不对,用户已经白等了一分多钟,appslot 里还留着一份坏镜像。
// =====================================================================

struct RemoteCatalogEntry: Decodable {
    let id: String
    let name: String
    let description: String
    let version: String?
    let size: Int?
    let sha256: String
    let url: String
}

enum AppCatalogSourceError: LocalizedError {
    case badURL(String)
    case http(Int)
    case emptyBody
    case decode(String)
    case hashMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s):   return "目录地址无效: \(s)"
        case .http(let code):  return "服务器返回 HTTP \(code)"
        case .emptyBody:       return "服务器返回了空响应"
        case .decode(let m):   return "目录解析失败: \(m)"
        case .hashMismatch(let expected, let actual):
            return "固件校验失败(期望 \(expected.prefix(12))…,实际 \(actual.prefix(12))…),已中止安装"
        }
    }
}

/// 远程目录客户端。刻意做成无状态的纯函数集合 —— 下载下来的文件放进调用方
/// 指定的缓存目录,这个类型自己不持有任何东西,便于测试也便于将来换实现。
enum RemoteAppCatalog {

    /// 拉取并解析 catalog.json。`base` 是目录服务的根地址。
    static func fetchCatalog(base: URL,
                             session: URLSession = .shared,
                             completion: @escaping (Result<[RemoteCatalogEntry], Error>) -> Void) {
        let url = base.appendingPathComponent("catalog.json")
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData   // 目录就是要拿最新的
        session.dataTask(with: req) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completion(.failure(AppCatalogSourceError.http(http.statusCode)))
                return
            }
            guard let data = data, !data.isEmpty else {
                completion(.failure(AppCatalogSourceError.emptyBody))
                return
            }
            do {
                let entries = try JSONDecoder().decode([RemoteCatalogEntry].self, from: data)
                completion(.success(entries))
            } catch {
                completion(.failure(AppCatalogSourceError.decode(error.localizedDescription)))
            }
        }.resume()
    }

    /// 下载一个条目的 .bin 到 `cacheDir`,**校验 sha256 通过后**才回调成功。
    ///
    /// 缓存命中也要重新校验一遍,不是只看文件在不在:缓存文件可能被上一次
    /// 中断的下载写了一半,也可能被别的东西改过。校验一次的代价(读 2MB 算
    /// 摘要)远小于装一个坏固件的代价。
    static func downloadFirmware(entry: RemoteCatalogEntry,
                                 base: URL,
                                 cacheDir: URL,
                                 session: URLSession = .shared,
                                 completion: @escaping (Result<URL, Error>) -> Void) {
        guard let url = URL(string: entry.url, relativeTo: base) else {
            completion(.failure(AppCatalogSourceError.badURL(entry.url)))
            return
        }

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // 缓存文件名里带上摘要:内容变了摘要就变,自然是另一个文件,不会出现
        // "版本号没变但内容换了"导致一直用旧缓存的情况。
        let cached = cacheDir.appendingPathComponent("\(entry.id)-\(entry.sha256.prefix(16)).bin")

        if FileManager.default.fileExists(atPath: cached.path),
           let data = try? Data(contentsOf: cached),
           Digest.sha256Hex(data) == entry.sha256.lowercased() {
            completion(.success(cached))
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 120   // 固件有 MB 级,给足时间
        session.dataTask(with: req) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completion(.failure(AppCatalogSourceError.http(http.statusCode)))
                return
            }
            guard let data = data, !data.isEmpty else {
                completion(.failure(AppCatalogSourceError.emptyBody))
                return
            }

            let actual = Digest.sha256Hex(data)
            guard actual == entry.sha256.lowercased() else {
                completion(.failure(AppCatalogSourceError.hashMismatch(expected: entry.sha256.lowercased(),
                                                                       actual: actual)))
                return
            }
            do {
                try data.write(to: cached, options: .atomic)
                completion(.success(cached))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}
