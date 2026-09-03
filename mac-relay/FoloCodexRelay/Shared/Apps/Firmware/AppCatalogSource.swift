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
           sha256Hex(data) == entry.sha256.lowercased() {
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

            let actual = sha256Hex(data)
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

    /// 不引入 CryptoKit 依赖的纯 Swift SHA-256(这个可执行文件是 swiftc 直接
    /// 编译的,没有走 Xcode 工程,少一个 framework 依赖就少一处构建麻烦)。
    static func sha256Hex(_ data: Data) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }

        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let o = chunk + i * 4
                w[i] = (UInt32(msg[o]) << 24) | (UInt32(msg[o+1]) << 16)
                     | (UInt32(msg[o+2]) << 8) | UInt32(msg[o+3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1
                d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}
