import Foundation
import VelosOCRKit

// MARK: - 火山翻译（translate.volcengineapi.com，签名 HMAC-SHA256）

enum Volcengine {
    static let host = "translate.volcengineapi.com"
    static let query = "Action=TranslateText&Version=2020-06-01"

    static func code(_ language: TranslateLanguage) -> String? {
        switch language {
        case .simplifiedChinese: "zh"
        case .traditionalChinese: "zh-Hant"
        case .english, .japanese, .korean, .french, .german, .spanish, .russian, .portuguese, .italian, .arabic,
             .thai, .vietnamese, .indonesian, .hindi, .turkish, .dutch, .polish, .ukrainian: language.rawValue
        default: nil
        }
    }

    /// 规范请求：签名 content-type、host、x-content-sha256、x-date（与官方 SDK 一致）
    static func canonicalRequest(payloadHash: String, xDate: String) -> String {
        let headers = "content-type:application/json\nhost:\(host)\nx-content-sha256:\(payloadHash)\nx-date:\(xDate)\n"
        return ["POST", "/", query, headers, "content-type;host;x-content-sha256;x-date", payloadHash].joined(separator: "\n")
    }

    static func authorization(accessKey: String, secretKey: String, payloadHash: String, xDate: String) -> String {
        let date = String(xDate.prefix(8))
        let scope = "\(date)/cn-north-1/translate/request"
        let stringToSign = ["HMAC-SHA256", xDate, scope,
                            EngineCrypto.sha256Hex(canonicalRequest(payloadHash: payloadHash, xDate: xDate))].joined(separator: "\n")
        let kDate = EngineCrypto.hmac(Data(secretKey.utf8), date)
        let kRegion = EngineCrypto.hmac(kDate, "cn-north-1")
        let kService = EngineCrypto.hmac(kRegion, "translate")
        let kSigning = EngineCrypto.hmac(kService, "request")
        let signature = EngineCrypto.hex(EngineCrypto.hmac(kSigning, stringToSign))
        return "HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=content-type;host;x-content-sha256;x-date, Signature=\(signature)"
    }

    static func translate(_ q: String, _ source: TranslateLanguage?, _ target: TranslateLanguage,
                          accessKey: String, secretKey: String) async throws -> String {
        guard let to = code(target) else { throw EngineError.unsupportedLanguage }
        var body: [String: Any] = ["TargetLanguage": to, "TextList": [q]]
        if let from = source.flatMap(code) { body["SourceLanguage"] = from }
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let payloadHash = EngineCrypto.sha256Hex(payload)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let xDate = formatter.string(from: Date())

        var request = URLRequest(url: URL(string: "https://\(host)/?\(query)")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Content-Sha256")
        request.setValue(xDate, forHTTPHeaderField: "X-Date")
        request.setValue(authorization(accessKey: accessKey, secretKey: secretKey, payloadHash: payloadHash, xDate: xDate),
                         forHTTPHeaderField: "Authorization")
        let (data, _) = try await EngineHTTP.send(request)
        guard let json = EngineHTTP.json(data) else { throw EngineError.service("火山返回的内容无法解析") }
        if let error = (json["ResponseMetadata"] as? [String: Any])?["Error"] as? [String: Any] {
            let code = "\(error["Code"] ?? "")"
            let message = error["Message"] as? String ?? code
            if code.contains("Signature") || code.contains("AccessKey") || code.contains("AccessDenied") || code.contains("Unauthorized") {
                throw EngineError.invalidKey
            }
            if code.contains("Quota") || code.contains("Arrear") || code.contains("Balance") { throw EngineError.quotaExceeded }
            if code == "-429" || code.contains("LimitExceeded") { throw EngineError.rateLimited }
            if code == "-415" { throw EngineError.unsupportedLanguage }
            throw EngineError.service("火山：\(message)")
        }
        let list = json["TranslationList"] as? [[String: Any]] ?? []
        return list.compactMap { $0["Translation"] as? String }.joined(separator: "\n")
    }
}
