import Foundation
import VelosOCRKit

/// 翻译引擎。Apple 翻译离线、免费、默认可用；其余是可选的在线引擎，全部使用官方开放平台 API，
/// 需要在设置里填写自己的 Key 才能启用（默认全部关闭）。
enum EngineID: String, CaseIterable, Identifiable, Sendable {
    case apple, youdao, deepl, azure, baidu, tencent, volcengine, openAI, claude

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
        case .openAI: "大模型（OpenAI 兼容）"
        case .claude: "Claude"
        }
    }

    /// 大语言模型翻译（流式输出、可自定义提示词）
    var isLLM: Bool { self == .openAI || self == .claude }

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
        case .openAI: [.init(key: "baseURL", label: "Base URL", placeholder: "例如 https://open.bigmodel.cn/api/paas/v4", secret: false),
                       .init(key: "model", label: "模型", placeholder: "例如 glm-4-flash、deepseek-chat、qwen-plus", secret: false),
                       .init(key: "apiKey", label: "API Key", placeholder: "sk-…", secret: true)]
        case .claude: [.init(key: "apiKey", label: "API Key", placeholder: "sk-ant-…", secret: true),
                       .init(key: "model", label: "模型", placeholder: "默认 \(ClaudeAPI.defaultModel)", secret: false)]
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
        case .openAI: nil
        case .claude: URL(string: "https://platform.claude.com/settings/keys")
        }
    }

    #if DEBUG
    @MainActor static var debugOnline: ((EngineID, String) async throws -> String)?
    #endif

    func credential(_ key: String) -> String { EngineKeychain.get("\(rawValue).\(key)") }
    func setCredential(_ value: String, for key: String) { EngineKeychain.set(value, for: "\(rawValue).\(key)") }

    /// 必填字段都填了（区域、地域、Claude 的模型可以不填）
    var hasCredentials: Bool {
        fields.filter { !($0.key == "region" || (self == .claude && $0.key == "model")) }
            .allSatisfy { !credential($0.key).isEmpty }
    }

    /// 在线翻译；source 为 nil 时让服务自动检测。大模型引擎一边生成一边通过 onPartial 回报（其他引擎一次返回）
    func translate(_ text: String, from source: TranslateLanguage?, to target: TranslateLanguage,
                   onPartial: @escaping @MainActor (String) -> Void = { _ in }) async throws -> String {
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
        case .openAI: try await OpenAICompatible.translate(text, source, target, baseURL: credential("baseURL"),
                                                           model: credential("model"), apiKey: credential("apiKey"),
                                                           prompt: await Preferences.shared.llmPrompt, onPartial: onPartial)
        case .claude: try await ClaudeAPI.translate(text, source, target, apiKey: credential("apiKey"), model: credential("model"),
                                                    prompt: await Preferences.shared.llmPrompt, onPartial: onPartial)
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
