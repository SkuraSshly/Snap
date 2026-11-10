import Foundation
import VelosOCRKit

// MARK: - 有道智云（openapi.youdao.com，签名 v3）

enum Youdao {
    static func code(_ language: TranslateLanguage) -> String {
        switch language {
        case .simplifiedChinese: "zh-CHS"
        case .traditionalChinese: "zh-CHT"
        case .norwegian: "no"
        default: language.rawValue
        }
    }

    /// sign = sha256(appKey + input + salt + curtime + appSecret)；input：超过 20 个字符时取「前 10 个字符 + 长度 + 后 10 个字符」
    static func sign(_ q: String, appKey: String, salt: String, curtime: String, secret: String) -> String {
        let input = q.count > 20 ? String(q.prefix(10)) + "\(q.count)" + String(q.suffix(10)) : q
        return EngineCrypto.sha256Hex(appKey + input + salt + curtime + secret)
    }

    static func translate(_ q: String, _ source: TranslateLanguage?, _ target: TranslateLanguage,
                          appKey: String, secret: String) async throws -> String {
        let salt = UUID().uuidString
        let curtime = String(Int(Date().timeIntervalSince1970))
        var request = URLRequest(url: URL(string: "https://openapi.youdao.com/api")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = EngineHTTP.formEncoded([
            ("q", q), ("from", source.map(code) ?? "auto"), ("to", code(target)), ("appKey", appKey), ("salt", salt),
            ("sign", sign(q, appKey: appKey, salt: salt, curtime: curtime, secret: secret)), ("signType", "v3"),
            ("curtime", curtime), ("strict", "true"),
        ])
        let (data, _) = try await EngineHTTP.send(request)
        guard let json = EngineHTTP.json(data) else { throw EngineError.service("有道返回的内容无法解析") }
        let errorCode = json["errorCode"] as? String ?? "?"
        guard errorCode == "0" else {
            switch errorCode {
            case "108", "202", "110", "206": throw EngineError.invalidKey
            case "401": throw EngineError.quotaExceeded
            case "411", "412": throw EngineError.rateLimited
            case "102": throw EngineError.unsupportedLanguage
            default: throw EngineError.service("有道返回错误 \(errorCode)")
            }
        }
        return (json["translation"] as? [String] ?? []).joined(separator: "\n")
    }
}
