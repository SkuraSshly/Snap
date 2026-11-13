import CryptoKit
import Foundation
import Security
import Synchronization

// 在线翻译引擎的公共部分：错误、网络请求、签名、钥匙串。
// 只有用户在设置里启用并填写了 Key 的引擎才会联网；原文只发送给所选的服务商，Velos 不发送任何别的数据。

/// 引擎失败的原因（显示给用户的简短说明）
enum EngineError: LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case quotaExceeded
    case rateLimited
    case unsupportedLanguage
    case timeout
    case network(String)
    case service(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "没有填写 Key"
        case .invalidKey: "Key 无效或没有开通服务"
        case .quotaExceeded: "额度用完了或账户欠费"
        case .rateLimited: "请求太频繁，请稍后再试"
        case .unsupportedLanguage: "不支持这对语言"
        case .timeout: "网络超时（10 秒）"
        case .network(let message): "网络错误：\(message)"
        case .service(let message): message
        }
    }
}

/// 网络请求：不存 Cookie、不用缓存，超时 10 秒
enum EngineHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw EngineError.network("没有收到响应") }
            return (data, http)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw EngineError.timeout
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet: throw EngineError.network("没有连接网络")
            default: throw EngineError.network(error.localizedDescription)
            }
        }
    }

    static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// application/x-www-form-urlencoded 编码（只保留 RFC 3986 的不保留字符）
    static func formEncoded(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }
}

/// 签名用的哈希
enum EngineCrypto {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ string: String) -> String { sha256Hex(Data(string.utf8)) }

    static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 引擎的 Key 存在钥匙串里（不写进设置文件）。条目：服务 local.velos.Velos.engines，账户「引擎.字段」
///
/// 少弹密码框：Velos 没有开发者证书，每次更新签名都不同，钥匙串把新版本当成另一个 App——
/// 读 Key 的内容要弹密码框问一次（点「始终允许」后，直到下次更新都不再问）。所以：
/// - 只想知道「填了没有」时，只查条目在不在（不解密内容，不弹框）
/// - 读过的内容在这次运行里记住，不反复去钥匙串取
enum EngineKeychain {
    #if DEBUG
    /// 调试版用单独的条目：不读正式版存的 Key（签名不同，读的时候系统会弹窗要求允许），自测写入的测试 Key 也不会碰到正式版的
    static let service = "local.velos.Velos.debug.engines"
    #else
    static let service = "local.velos.Velos.engines"
    #endif

    /// 这次运行里读过、写过的内容（"" 表示没有这个条目）
    private static let cache = Mutex<[String: String]>([:])

    static func get(_ account: String) -> String {
        if let cached = cache.withLock({ $0[account] }) { return cached }
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value = (result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        // 用户在密码框点了「拒绝」之类的失败不记住：下次用到时再问
        if status == errSecSuccess || status == errSecItemNotFound {
            cache.withLock { $0[account] = value }
        }
        return value
    }

    #if DEBUG
    /// 自测：忘掉这次运行里记住的内容，之后的读取直接查钥匙串（检查「真的存进去了、真的删掉了」）
    static func debugForget() { cache.withLock { $0.removeAll() } }
    #endif

    /// 有没有填（空值不会存进钥匙串，所以「条目在」就是「填了」）。只查属性、不读内容，不弹密码框
    static func exists(_ account: String) -> Bool {
        if let cached = cache.withLock({ $0[account] }) { return !cached.isEmpty }
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// 写入；空字符串表示删除
    static func set(_ value: String, for account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        cache.withLock { $0[account] = trimmed }
        if trimmed.isEmpty {
            SecItemDelete(baseQuery(account) as CFDictionary)
            return
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "Velos 翻译引擎 \(account)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
