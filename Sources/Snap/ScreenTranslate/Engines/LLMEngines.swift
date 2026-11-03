import Foundation
import SnapOCRKit

// 大语言模型翻译：OpenAI 兼容接口（DeepSeek、通义千问、Kimi 等，可填 Base URL、模型名、API Key）和 Anthropic Claude API。
// 都用流式输出：译文一边生成一边显示。提示词要求只输出译文、保留格式和专有名词；可以在设置里自定义。

enum LLMTranslation {
    /// 默认提示词。{target} 换成目标语言，{source} 换成原文语言
    static let defaultPrompt = """
    你是专业的翻译。把用户发来的文本从{source}翻译成{target}。
    只输出译文本身：不要解释，不要加引号、标题或任何前后缀。
    保留原文的段落、换行、列表和标点格式；人名、品牌、产品名、代码、网址等专有名词保持原样或使用通行译法。
    """

    static func systemPrompt(source: TranslateLanguage?, target: TranslateLanguage, custom: String) -> String {
        let template = custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultPrompt : custom
        return template
            .replacingOccurrences(of: "{source}", with: source?.displayName ?? "原文语言")
            .replacingOccurrences(of: "{target}", with: target.displayName)
    }

    /// 流式请求：两次收到数据之间最多等 10 秒，整个回答最多 2 分钟
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 120
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        #if DEBUG
        if let mock = debugProtocol { configuration.protocolClasses = [mock] }
        #endif
        return URLSession(configuration: configuration)
    }()

    #if DEBUG
    /// 自测：用假的服务端（URLProtocol）代替网络，必须在第一次请求之前设置
    nonisolated(unsafe) static var debugProtocol: AnyClass?
    #endif

    /// 读取 Server-Sent Events：每行 `data: …` 交给 handle；返回 false 时停止
    static func streamEvents(_ request: URLRequest, provider: String,
                             handle: (_ event: String?, _ data: String) throws -> Bool) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw error.code == .timedOut ? EngineError.timeout : EngineError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw EngineError.network("没有收到响应") }
        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes.prefix(4096) { body.append(byte) }
            throw error(status: http.statusCode, body: body, provider: provider)
        }
        var event: String?
        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if line.hasPrefix("event:") {
                    event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard try handle(event, data) else { return }
                }
            }
        } catch let error as URLError {
            throw error.code == .timedOut ? EngineError.timeout : EngineError.network(error.localizedDescription)
        }
    }

    /// HTTP 错误 → 简短原因
    static func error(status: Int, body: Data, provider: String) -> EngineError {
        let json = EngineHTTP.json(body)
        let detail = (json?["error"] as? [String: Any])?["message"] as? String ?? json?["message"] as? String
        switch status {
        case 401, 403: return .invalidKey
        case 402: return .quotaExceeded
        case 429:
            // OpenAI 兼容接口额度用完也返回 429（insufficient_quota）
            let type = (json?["error"] as? [String: Any])?["code"] as? String ?? ""
            return type.contains("quota") ? .quotaExceeded : .rateLimited
        case 404: return .service("\(provider)：找不到这个模型或地址\(detail.map { "（\($0)）" } ?? "")")
        case 529, 503: return .service("\(provider) 暂时过载，请稍后再试")
        default: return .service("\(provider)：\(detail ?? "HTTP \(status)")")
        }
    }
}

// MARK: - OpenAI 兼容接口（/chat/completions）

enum OpenAICompatible {
    /// Base URL 末尾加上 /chat/completions（已经写全的不重复加）
    static func endpoint(_ base: String) -> URL? {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.hasSuffix("/chat/completions") { text += "/chat/completions" }
        guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    static func translate(_ q: String, _ source: TranslateLanguage?, _ target: TranslateLanguage, baseURL: String,
                          model: String, apiKey: String, prompt: String,
                          onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let url = endpoint(baseURL) else { throw EngineError.service("Base URL 无效") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system", "content": LLMTranslation.systemPrompt(source: source, target: target, custom: prompt)],
                ["role": "user", "content": q],
            ],
        ] as [String: Any])
        var output = ""
        try await LLMTranslation.streamEvents(request, provider: "大模型") { _, data in
            if data == "[DONE]" { return false }
            guard let json = EngineHTTP.json(Data(data.utf8)) else { return true }
            if let error = json["error"] as? [String: Any] {
                throw EngineError.service("大模型：\(error["message"] as? String ?? "出错了")")
            }
            let choices = json["choices"] as? [[String: Any]] ?? []
            if let piece = (choices.first?["delta"] as? [String: Any])?["content"] as? String, !piece.isEmpty {
                output += piece
                let snapshot = output
                Task { @MainActor in onPartial(snapshot) }
            }
            return true
        }
        return output
    }
}

// MARK: - Anthropic Claude API（/v1/messages，流式）

enum ClaudeAPI {
    static let defaultModel = "claude-opus-5-5"
    /// 支持服务端拒答回退（fallbacks: "default"）的模型
    private static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-fable-5-1", "claude-opus-5", "claude-sonnet-5-5"]

    static func translate(_ q: String, _ source: TranslateLanguage?, _ target: TranslateLanguage, apiKey: String,
                          model: String, prompt: String,
                          onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        let model = model.trimmingCharacters(in: .whitespaces).isEmpty ? defaultModel : model
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "stream": true,
            // 翻译是简单任务：低强度思考，出结果更快
            "output_config": ["effort": "low"],
            "system": LLMTranslation.systemPrompt(source: source, target: target, custom: prompt),
            "messages": [["role": "user", "content": q]],
        ]
        if fallbackModels.contains(model) {
            // 安全分类器拒答时，由服务端自动换模型重试（按拒答类别路由）
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var output = ""
        try await LLMTranslation.streamEvents(request, provider: "Claude") { event, data in
            guard let json = EngineHTTP.json(Data(data.utf8)) else { return true }
            switch json["type"] as? String ?? event {
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let piece = delta?["text"] as? String {
                    output += piece
                    let snapshot = output
                    Task { @MainActor in onPartial(snapshot) }
                }
            case "message_delta":
                if (json["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" {
                    throw EngineError.service("Claude 拒绝翻译这段内容")
                }
            case "error":
                let error = json["error"] as? [String: Any]
                switch error?["type"] as? String {
                case "overloaded_error": throw EngineError.service("Claude 暂时过载，请稍后再试")
                case "rate_limit_error": throw EngineError.rateLimited
                default: throw EngineError.service("Claude：\(error?["message"] as? String ?? "出错了")")
                }
            case "message_stop":
                return false
            default:
                break
            }
            return true
        }
        return output
    }
}
