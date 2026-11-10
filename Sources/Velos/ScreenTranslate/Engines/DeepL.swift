import Foundation
import VelosOCRKit

// MARK: - DeepL（官方 API：Free / Pro）

enum DeepL {
    static func targetCode(_ language: TranslateLanguage) -> String {
        switch language {
        case .simplifiedChinese: "ZH-HANS"
        case .traditionalChinese: "ZH-HANT"
        case .english: "EN-US"
        case .portuguese: "PT-BR"
        case .norwegian: "NB"
        default: language.rawValue.uppercased()
        }
    }

    static func sourceCode(_ language: TranslateLanguage) -> String {
        language.isChinese ? "ZH" : (language == .norwegian ? "NB" : language.rawValue.uppercased())
    }

    /// Free 版的 Key 以 ":fx" 结尾，用 api-free.deepl.com；否则是 Pro 版 api.deepl.com
    static func endpoint(for key: String) -> URL {
        URL(string: key.hasSuffix(":fx") ? "https://api-free.deepl.com/v2/translate" : "https://api.deepl.com/v2/translate")!
    }

    static func translate(_ q: String, _ source: TranslateLanguage?, _ target: TranslateLanguage, key: String) async throws -> String {
        var request = URLRequest(url: endpoint(for: key))
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": [q], "target_lang": targetCode(target)]
        if let source { body["source_lang"] = sourceCode(source) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await EngineHTTP.send(request)
        switch http.statusCode {
        case 200: break
        case 401, 403: throw EngineError.invalidKey
        case 456: throw EngineError.quotaExceeded
        case 429, 529: throw EngineError.rateLimited
        default:
            let message = EngineHTTP.json(data)?["message"] as? String ?? "HTTP \(http.statusCode)"
            throw message.localizedCaseInsensitiveContains("language") ? EngineError.unsupportedLanguage
                                                                        : EngineError.service("DeepL：\(message)")
        }
        let translations = EngineHTTP.json(data)?["translations"] as? [[String: Any]] ?? []
        return translations.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
