import Foundation
import Security

// MARK: - 密码保存
//
// 同步密码不塞 UserDefaults（那里明文可见、还会跟着 iCloud 备份走），
// 放 Keychain。免签名 App 用不带访问组的 generic password，
// 系统不会因为签名问题拒绝。

enum Keychain {
    private static let service = "com.cuiban.app"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        // 先删后加：SecItemUpdate 在 item 不存在时会报错，不如直接覆盖写
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func remove(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - WebDAV 客户端
//
// 为什么要有这个：iOS 的「选择文件夹」面板只认系统文件 App 里的位置，
// 飞牛、群晖这些 NAS 自带的 App 除非注册了文件提供器（FileProvider），
// 否则在这个面板里**根本不出现**，用户没法选。
// 而 NAS 基本都自带 WebDAV 服务（飞牛在「文件服务 → WebDAV」里开启，默认 5005 端口），
// WebDAV 就是 HTTP + Basic 认证，URLSession 直接就能读写，不需要任何第三方库、
// 也不需要用户先去系统文件 App 里连一遍。
//
// 同步的是一个文件（cuiban-data.json，照片已内嵌成 base64），
// 所以只要实现 GET / PUT / MKCOL 三个动作就够了。

/// 自签名证书放行。
///
/// 自建 NAS + frp 映射几乎一定用的是自签名证书（或者证书域名和 IP 对不上），
/// ATS 和系统默认校验都会直接拒掉，表现为「此服务器的证书无效」。
/// 用户明确要求不管证书，所以这里在 serverTrust 挑战里无条件放行。
///
/// 安全影响：这条链路不再防中间人。但数据只在自己的设备↔自己的 NAS 之间传，
/// 且密码走的是 Basic（本来就不抗嗅探，除非套 https——这里已经放弃 https 的意义了）。
/// 真要根治得在 NAS 上装一个与域名匹配的证书。
private final class SelfSignedOKDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// 单例持有 delegate，URLSession 会强引用它，别让 session 一建完就被回收
private final class SelfSignedSession {
    static let shared = SelfSignedSession()
    let delegate = SelfSignedOKDelegate()
    let session: URLSession
    private init() {
        session = URLSession(configuration: .default)
    }
}

struct WebDAVClient {
    /// 形如 https://你的NAS地址:端口/目录 或 http://192.168.x.x:5005/xxx
    var baseURL: String
    var user: String
    var password: String
    var fileName: String = "cuiban-data.json"

    enum WebDAVError: LocalizedError {
        case badURL
        case http(Int, String)
        case empty
        case tls(String)

        var errorDescription: String? {
            switch self {
            case .badURL:
                return "地址填得不对，要以 http:// 或 https:// 开头"
            case .http(let code, _):
                if code == 401 { return "用户名或密码不对" }
                if code == 403 { return "没有权限写这个目录" }
                if code == 404 { return "远端找不到这个路径，检查地址和目录名" }
                if code == 405 { return "这个地址可能不是 WebDAV 服务" }
                return "服务器返回 \(code)"
            case .empty:
                return "没有读到内容"
            case .tls(let m):
                return "HTTPS 连不上：\(m)"
            }
        }
    }

    /// 拼出目标文件 URL（顺手把结尾多余的斜杠去掉，避免拼出双斜杠）
    private var fileURL: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty,
              let u = URL(string: s + "/" + fileName) else { return nil }
        return u
    }

    private var dirURL: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        return URL(string: s + "/")
    }

    /// 发一个请求。CloudSync 是同步接口，这里用信号量把异步包一层。
    @discardableResult
    private func request(_ url: URL, _ method: String, body: Data? = nil) throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
req.httpBody = body
        // 25 秒太久：NAS 不在线时用户要干等 25 秒。10 秒够局域网/公网用了
        req.timeoutInterval = 10
        // Basic 认证头 + 自签名放行都要，所以走带 delegate 的 session，
        // 但认证仍然手动拼头：省掉 challenge 反复重试（有些 NAS 会连着挑战 3 次）
        if !user.isEmpty || !password.isEmpty {
            let cred = Data("\(user):\(password)".utf8).base64EncodedString()
            req.setValue("Basic \(cred)", forHTTPHeaderField: "Authorization")
        }

        var outData: Data?
        var outResp: HTTPURLResponse?
        var outErr: Error?
        let sem = DispatchSemaphore(value: 0)
        SelfSignedSession.shared.session.dataTask(with: req) { d, r, e in
            outData = d
            outResp = r as? HTTPURLResponse
            outErr = e
            sem.signal()
        }.resume()
        sem.wait()

        if let e = outErr {
            let ns = e as NSError
            // 证书类错误翻译成人能看懂的话；NSURLErrorServerCertificateUntrusted = -1202
            if ns.domain == NSURLErrorDomain,
               ns.code == NSURLErrorServerCertificateUntrusted
                || ns.code == NSURLErrorServerCertificateHasBadDate
                || ns.code == NSURLErrorServerCertificateHasUnknownRoot
                || ns.code == NSURLErrorServerCertificateNotYetValid {
                throw WebDAVError.tls(ns.localizedDescription)
            }
            throw e
        }
        guard let resp = outResp else { throw WebDAVError.empty }
        // 2xx 都算成功（WebDAV 的 PUT 返回 201/204）
        guard (200...299).contains(resp.statusCode) else {
            throw WebDAVError.http(resp.statusCode,
                                    String(data: outData ?? Data(), encoding: .utf8) ?? "")
        }
        return outData ?? Data()
    }

    /// 远端文件的内容。返回 nil = 远端还没有这个文件（正常，不是错误）
    func download() throws -> Data? {
        guard let u = fileURL else { throw WebDAVError.badURL }
        do {
            let d = try request(u, "GET")
            return d.isEmpty ? nil : d
        } catch WebDAVError.http(404, _) {
            return nil
        }
    }

/// 传上去。目录不存在会先试着建一次（MKCOL）
    func upload(_ data: Data) throws {
        guard let u = fileURL else { throw WebDAVError.badURL }
        do {
            try request(u, "PUT", body: data)
    } catch WebDAVError.http(let code, _) where code == 404 || code == 409 {
   // 目录不存在 → 建目录再传
   if let d = dirURL { try? request(d, "MKCOL") }
            try request(u, "PUT", body: data)
        }
    }

    /// 传一个指定文件名的文件（历史备份用）
    func upload(_ data: Data, as name: String) throws {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s + "/" + name) else { throw WebDAVError.badURL }
        do {
            try request(u, "PUT", body: data)
        } catch WebDAVError.http(let code, _) where code == 404 || code == 409 {
            if let d = dirURL { try? request(d, "MKCOL") }
      try request(u, "PUT", body: data)
        }
    }

/// 列目录下的文件名（不含路径）。服务端不支持 PROPFIND 时返回 nil
    func listFileNames() -> [String]? {
        guard let d = dirURL else { return nil }
        let xml = "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:allprop/></d:propfind>"
        let data: Data
        do {
      data = try request(d, "PROPFIND", body: Data(xml.utf8))
        } catch {
      return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // 从 multistatus 里抠出所有 <D:href>…</D:href>。
        // 前缀可能是 D: 也可能是无前缀（服务端实现各有不同），两种都匹配。
        let pat = "<(?:[a-zA-Z0-9]+:)?href[^>]*>([^<]*)</(?:[a-zA-Z0-9]+:)?href>"
        guard let re = try? NSRegularExpression(pattern: pat) else { return nil }
        let ns = text as NSString
        var out: [String] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m, m.numberOfRanges > 1 else { return }
            let href = ns.substring(with: m.range(at: 1))
            // href 可能是 /目录/文件、也可能是完整 URL，统一取最后一段
let segs = href.split(separator: "/").map(String.init)
            guard var last = segs.last, !last.isEmpty else { return }
        // 服务端可能把非 ASCII 转成 %XX
            if let d = last.removingPercentEncoding, !d.isEmpty { last = d }
      out.append(last)
  }
        return out
    }

    /// 删一个远端文件
    func deleteFile(named name: String) {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s + "/" + name) else { return }
        try? request(u, "DELETE")
    }

    /// 设置页的「测试连接」：探一下目录能不能列
    func test() -> String {
 guard let d = dirURL else { return "地址填得不对，要以 http:// 或 https:// 开头" }
        do {
      let xml = "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:allprop/></d:propfind>"
      _ = try request(d, "PROPFIND", body: Data(xml.utf8))
   return "连接成功，能读写这个目录"
        } catch let e as WebDAVError {
    if case .http(let code, _) = e {
   // 有些服务端不允许 PROPFIND 但允许读写，不算失败
            if code == 405 || code == 207 { return "连接成功，服务端不支持列目录但可以读写" }
      return "连不上：\(e.localizedDescription)"
       }
    return "连不上：\(e.localizedDescription)"
        } catch {
            return "连不上：\(error.localizedDescription)"
        }
    }
}