import Foundation
import VelosOCRKit

// MARK: - 百度翻译（fanyi-api.baidu.com 通用翻译）

enum Baidu {
    static func code(_ language: TranslateLanguage) -> String? {
        switch language {
        case .simplifiedChinese: "zh"
        case .traditionalChinese: "cht"
        case .english: "en"
        case .japanese: "jp"
        case .korean: "kor"
        case .french: "fra"
        case .spanish: "spa"
        case .german: "de"
        case .russian: "ru"
        case .portuguese: "pt"
        case .italian: "it"
        case .arabic: "ara"
        case .thai: "th"
        case .vietnamese: "vie"
        case .indonesian: "id"
        case .hindi: "hi"
        case .turkish: "tr"
        case .dutch: "nl"
        case .polish: "pl"
        case .ukrainian: "ukr"
        case .czech: "cs"
        case .danish: "dan"
        case .romanian: "rom"
        case .swedish: "swe"
        case .finnish: "fin"
        case .greek: "el"
        case .hungarian: "hu"
        default: nil
        }
    }

    /// sign = md5(appid + q + salt + 密钥)（q 用原文，不做 URL 编码）
    static func sign(_ q: String, appid: String, salt: String, secret: String) -> String {
        EngineCrypto.md5Hex(appid + q + salt + secret)
    }

    static func translate(_ q: String, _ source: TranslateLanguage?, _ target: TranslateLanguage,
                          appid: String, secret: String) async throws -> String {
        guard let to = code(target) else { throw EngineError.unsupportedLanguage }
        let from = source.flatMap(code) ?? "auto"
        let salt = String(Int.random(in: 10_000...99_999_999))
        var request = URLRequest(url: URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = EngineHTTP.formEncoded([
            ("q", q), ("from", from), ("to", to), ("appid", appid), ("salt", salt),
            ("sign", sign(q, appid: appid, salt: salt, secret: secret)),
        ])
        let (data, _) = try await EngineHTTP.send(request)
        guard let json = EngineHTTP.json(data) else { throw EngineError.service("百度返回的内容无法解析") }
        if let errorCode = json["error_code"].map({ "\($0)" }), errorCode != "52000" {
            switch errorCode {
            case "52003", "54001", "90107", "58002": throw EngineError.invalidKey
            case "54004": throw EngineError.quotaExceeded
            case "54003", "54005": throw EngineError.rateLimited
            case "58001": throw EngineError.unsupportedLanguage
            default: throw EngineError.service("百度返回错误 \(errorCode)：\(json["error_msg"] as? String ?? "")")
            }
        }
        let results = json["trans_result"] as? [[String: Any]] ?? []
        return results.compactMap { $0["dst"] as? String }.joined(separator: "\n")
    }
}
