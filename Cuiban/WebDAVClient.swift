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

struct WebDAVClient {
    /// 形如 http://192.168.1.10:5005/cuiban-sync （结尾有没有斜杠都行）
    var baseURL: String
    var user: String
    var password: String
    var fileName: String = "cuiban-data.json"

    enum WebDAVError: LocalizedError {
        case badURL
        case http(Int, String)
        case empty

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
        req.timeoutInterval = 25
        // 手动拼 Basic 认证头：不去碰 URLSession 的认证 challenge delegate，
        // 少一层和后台 session 冲突的坑
        let cred = Data("\(user):\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(cred)", forHTTPHeaderField: "Authorization")

        var outData: Data?
        var outResp: HTTPURLResponse?
        var outErr: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, e in
            outData = d
            outResp = r as? HTTPURLResponse
            outErr = e
            sem.signal()
        }.resume()
        sem.wait()

        if let e = outErr { throw e }
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