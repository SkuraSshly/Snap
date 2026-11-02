import Foundation
import SnapOCRKit

/// 翻译引擎。Apple 翻译离线、免费、默认可用；其余是可选的在线引擎，全部使用官方开放平台 API，
/// 需要在设置里填写自己的 Key 才能启用（默认全部关闭）。
enum EngineID: String, CaseIterable, Identifiable, Sendable {
    case apple, youdao, deepl, azure, baidu, tencent, volcengine

    var id: Self { self }

    var displayName: String {
        switch self {
        case .apple: "Apple 翻译"
        case .youdao: "有道智云"
        case .deepl: "DeepL"
        case .azure: "微软翻译"
        case .baidu: "百度翻译"
        case .tencent: "腾讯翻译君"
        case .volcengine: "火山翻译"
        }
    }

    /// 需要填写的字段（存在钥匙串里）
    struct Field: Sendable {
        let key: String
        let label: String
        let placeholder: String
        let secret: Bool
    }

    var fields: [Field] {
        switch self {
        case .apple: []
        case .youdao: [.init(key: "appKey", label: "应用 ID", placeholder: "appKey", secret: false),
                       .init(key: "appSecret", label: "应用密钥", placeholder: "appSecret", secret: true)]
        case .deepl: [.init(key: "authKey", label: "API Key", placeholder: "Free 版的 Key 以 :fx 结尾", secret: true)]
        case .azure: [.init(key: "key", label: "密钥", placeholder: "Ocp-Apim-Subscription-Key", secret: true),
                      .init(key: "region", label: "区域", placeholder: "例如 eastasia（全局资源留空）", secret: false)]
        case .baidu: [.init(key: "appid", label: "APP ID", placeholder: "appid", secret: false),
                      .init(key: "secret", label: "密钥", placeholder: "secret", secret: true)]
        case .tencent: [.init(key: "secretId", label: "SecretId", placeholder: "AKID…", secret: false),
                        .init(key: "secretKey", label: "SecretKey", placeholder: "SecretKey", secret: true),
                        .init(key: "region", label: "地域", placeholder: "默认 ap-guangzhou", secret: false)]
        case .volcengine: [.init(key: "accessKeyId", label: "Access Key ID", placeholder: "AKLT…", secret: false),
                           .init(key: "secretAccessKey", label: "Secret Access Key", placeholder: "Secret Access Key", secret: true)]
        }
    }

    /// 开放平台的地址（设置里「申请 Key」链接）
    var consoleURL: URL? {
        switch self {
        case .apple: nil
        case .youdao: URL(string: "https://ai.youdao.com/console/")
        case .deepl: URL(string: "https://www.deepl.com/your-account/keys")
        case .azure: URL(string: "https://portal.azure.com/")
        case .baidu: URL(string: "https://fanyi-api.baidu.com/manage/developer")
        case .tencent: URL(string: "https://console.cloud.tencent.com/cam/capi")
        case .volcengine: URL(string: "https://console.volcengine.com/iam/keymanage/")
        }
    }

    #if DEBUG
    @MainActor static var debugOnline: ((EngineID, String) async throws -> String)?
    #endif

    func credential(_ key: String) -> String { EngineKeychain.get("\(rawValue).\(key)") }
    func setCredential(_ value: String, for key: String) { EngineKeychain.set(value, for: "\(rawValue).\(key)") }

    /// 必填字段都填了（区域、地域可以不填）
    var hasCredentials: Bool {
        fields.filter { $0.key != "region" }.allSatisfy { !credential($0.key).isEmpty }
    }

    /// 在线翻译；source 为 nil 时让服务自动检测
    func translate(_ text: String, from source: TranslateLanguage?, to target: TranslateLanguage) async throws -> String {
        guard self != .apple else { throw EngineError.service("Apple 翻译不走这里") }
        #if DEBUG
        // 自测：用假的在线引擎，不发网络请求
        if let stub = await EngineID.debugOnline { return try await stub(self, text) }
        #endif
        guard hasCredentials else { throw EngineError.missingKey }
        let output: String = switch self {
        case .youdao: try await Youdao.translate(text, source, target, appKey: credential("appKey"), secret: credential("appSecret"))
        case .deepl: try await DeepL.translate(text, source, target, key: credential("authKey"))
        case .azure: try await Azure.translate(text, source, target, key: credential("key"), region: credential("region"))
        case .baidu: try await Baidu.translate(text, source, target, appid: credential("appid"), secret: credential("secret"))
        case .tencent: try await Tencent.translate(text, source, target, secretId: credential("secretId"),
                                                   secretKey: credential("secretKey"), region: credential("region"))
        case .volcengine: try await Volcengine.translate(text, source, target, accessKey: credential("accessKeyId"),
                                                         secretKey: credential("secretAccessKey"))
        case .apple: ""
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EngineError.service("\(displayName) 没有返回译文") }
        return LanguageRules.normalizedChinese(trimmed, target: target)
    }
}

/// 哪些引擎可用、默认用哪个
@MainActor
enum EngineRouting {
    /// 可用的引擎：Apple 翻译 + 已启用并填了 Key 的在线引擎
    static var available: [EngineID] {
        let enabled = Set(Preferences.shared.enabledEngines)
        return EngineID.allCases.filter { $0 == .apple || (enabled.contains($0.rawValue) && $0.hasCredentials) }
    }

    /// 默认引擎（设置里选的；它不可用时用 Apple 翻译）
    static var preferred: EngineID {
        let chosen = EngineID(rawValue: Preferences.shared.defaultEngine) ?? .apple
        return available.contains(chosen) ? chosen : .apple
    }
}

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
