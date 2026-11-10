import Foundation
import VelosOCRKit

// MARK: - 微软翻译（Azure Translator v3）

enum Azure {
    static func code(_ language: TranslateLanguage) -> String {
        language == .norwegian ? "nb" : language.rawValue   // zh-Hans、zh-Hant、en … 与 Azure 一致
    }

    static func translate(_ q: String, _ source: TranslateLanguage?, _ target: TranslateLanguage,
                          key: String, region: String) async throws -> String {
        var components = URLComponents(string: "https://api.cognitive.microsofttranslator.com/translate")!
        components.queryItems = [.init(name: "api-version", value: "3.0"), .init(name: "to", value: code(target))]
            + (source.map { [URLQueryItem(name: "from", value: code($0))] } ?? [])
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        if !region.isEmpty { request.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region") }
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [["Text": q]])
        let (data, http) = try await EngineHTTP.send(request)
        switch http.statusCode {
        case 200: break
        case 401: throw EngineError.invalidKey
        case 403: throw EngineError.quotaExceeded
        case 429: throw EngineError.rateLimited
        default:
            let error = EngineHTTP.json(data)?["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "HTTP \(http.statusCode)"
            throw EngineError.service("微软翻译：\(message)")
        }
        let results = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        let translations = results.first?["translations"] as? [[String: Any]] ?? []
        return translations.first?["text"] as? String ?? ""
    }
}
