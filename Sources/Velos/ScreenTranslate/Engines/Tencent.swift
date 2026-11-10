import Foundation
import VelosOCRKit

// MARK: - 腾讯翻译君（tmt.tencentcloudapi.com，签名 TC3-HMAC-SHA256）

enum Tencent {
    static let host = "tmt.tencentcloudapi.com"

    static func code(_ language: TranslateLanguage) -> String? {
        switch language {
        case .simplifiedChinese: "zh"
        case .traditionalChinese: "zh-TW"
        case .english, .japanese, .korean, .french, .spanish, .italian, .german, .turkish, .russian, .portuguese,
             .vietnamese, .indonesian, .thai, .malay, .arabic, .hindi: language.rawValue
        default: nil
        }
    }

    /// 规范请求（POST、URI「/」、空查询串、签名 content-type / host / x-tc-action）
    static func canonicalRequest(host: String, action: String, payload: String) -> String {
        let headers = "content-type:application/json; charset=utf-8\nhost:\(host)\nx-tc-action:\(action.lowercased())\n"
        return ["POST", "/", "", headers, "content-type;host;x-tc-action", EngineCrypto.sha256Hex(payload)]
            .joined(separator: "\n")
    }

    /// Authorization 头。date 是时间戳对应的 UTC 日期（yyyy-MM-dd）
    static func authorization(secretId: String, secretKey: String, service: String, host: String, action: String,
                              payload: String, timestamp: Int, date: String) -> String {
        let scope = "\(date)/\(service)/tc3_request"
        let stringToSign = ["TC3-HMAC-SHA256", "\(timestamp)", scope,
                            EngineCrypto.sha256Hex(canonicalRequest(host: host, action: action, payload: payload))]
            .joined(separator: "\n")
        let secretDate = EngineCrypto.hmac(Data(("TC3" + secretKey).utf8), date)
        let secretService = EngineCrypto.hmac(secretDate, service)
        let secretSigning = EngineCrypto.hmac(secretService, "tc3_request")
        let signature = EngineCrypto.hex(EngineCrypto.hmac(secretSigning, stringToSign))
        return "TC3-HMAC-SHA256 Credential=\(secretId)/\(scope), SignedHeaders=content-type;host;x-tc-action, Signature=\(signature)"
    }

    static func translate(_ q: String, _ source: TranslateLanguage?, _ target: TranslateLanguage,
                          secretId: String, secretKey: String, region: String) async throws -> String {
        guard let to = code(target) else { throw EngineError.unsupportedLanguage }
        let body: [String: Any] = ["SourceText": q, "Source": source.flatMap(code) ?? "auto", "Target": to, "ProjectId": 0]
        let payloadData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let payload = String(decoding: payloadData, as: UTF8.self)
        let timestamp = Int(Date().timeIntervalSince1970)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))

        var request = URLRequest(url: URL(string: "https://\(host)/")!)
        request.httpMethod = "POST"
        request.httpBody = payloadData
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue("TextTranslate", forHTTPHeaderField: "X-TC-Action")
        request.setValue("\(timestamp)", forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue("2018-03-21", forHTTPHeaderField: "X-TC-Version")
        request.setValue(region.isEmpty ? "ap-guangzhou" : region, forHTTPHeaderField: "X-TC-Region")
        request.setValue(authorization(secretId: secretId, secretKey: secretKey, service: "tmt", host: host,
                                       action: "TextTranslate", payload: payload, timestamp: timestamp, date: date),
                         forHTTPHeaderField: "Authorization")
        let (data, _) = try await EngineHTTP.send(request)
        guard let response = EngineHTTP.json(data)?["Response"] as? [String: Any] else {
            throw EngineError.service("腾讯返回的内容无法解析")
        }
        if let error = response["Error"] as? [String: Any] {
            let code = error["Code"] as? String ?? ""
            if code.hasPrefix("AuthFailure") { throw EngineError.invalidKey }
            if code.contains("NoFreeAmount") || code.contains("ServiceIsolate") || code.contains("Arrear") {
                throw EngineError.quotaExceeded
            }
            if code.contains("LimitExceeded") { throw EngineError.rateLimited }
            if code.contains("UnsupportedLanguage") || code.contains("UnsupportedSourceLanguage") {
                throw EngineError.unsupportedLanguage
            }
            throw EngineError.service("腾讯：\(error["Message"] as? String ?? code)")
        }
        return response["TargetText"] as? String ?? ""
    }
}
