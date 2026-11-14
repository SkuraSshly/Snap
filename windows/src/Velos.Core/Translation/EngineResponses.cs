using System.Text.Json;

namespace Velos.Core.Translation;

public static class EngineResponses
{
    internal static JsonElement Property(this JsonElement element, string name) => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) ? value : default;
    internal static string Text(this JsonElement element) => element.ValueKind == JsonValueKind.String ? element.GetString() ?? "" : element.ValueKind == JsonValueKind.Number ? element.GetRawText() : "";
    private static IEnumerable<JsonElement> Items(JsonElement element) => element.ValueKind == JsonValueKind.Array ? element.EnumerateArray() : [];
    public static string Parse(EngineId id, string body)
    {
        using var document = JsonDocument.Parse(body); var root = document.RootElement;
        var code = id switch { EngineId.Youdao => root.Property("errorCode").Text(), EngineId.Baidu => root.Property("error_code").Text(),
            EngineId.Tencent => root.Property("Response").Property("Error").Property("Code").Text(), EngineId.Volcengine => root.Property("ResponseMetadata").Property("Error").Property("Code").Text(), _ => "" };
        if (code.Length > 0 && code is not ("0" or "52000")) throw new InvalidOperationException(ProviderError(id, code));
        var output = id switch
        {
            EngineId.Youdao => string.Join('\n', Items(root.Property("translation")).Select(Text)),
            EngineId.Baidu => string.Join('\n', Items(root.Property("trans_result")).Select(v => v.Property("dst").Text())),
            EngineId.DeepL => string.Join('\n', Items(root.Property("translations")).Select(v => v.Property("text").Text())),
            EngineId.Azure => Items(Items(root).FirstOrDefault().Property("translations")).FirstOrDefault().Property("text").Text(),
            EngineId.Tencent => root.Property("Response").Property("TargetText").Text(),
            EngineId.Volcengine => string.Join('\n', Items(root.Property("TranslationList")).Select(v => v.Property("Translation").Text())),
            _ => ""
        };
        if (string.IsNullOrWhiteSpace(output)) throw new InvalidOperationException("服务没有返回译文。");
        return output.Trim();
    }
    public static string ProviderError(EngineId id, string code)
    {
        if (new[] { "108", "202", "110", "206", "52003", "54001", "90107", "58002" }.Contains(code) || new[] { "AuthFailure", "Signature", "AccessKey", "AccessDenied", "Unauthorized" }.Any(code.Contains)) return "Key 无效或没有开通服务。";
        if (code is "401" or "54004" || new[] { "NoFreeAmount", "ServiceIsolate", "Arrear", "Quota", "Balance" }.Any(code.Contains)) return "额度用完了或账户欠费。";
        if (code is "411" or "412" or "54003" or "54005" or "-429" || code.Contains("LimitExceeded")) return "请求太频繁，请稍后再试。";
        if (code is "102" or "58001" or "-415" || code.Contains("UnsupportedLanguage") || code.Contains("UnsupportedSourceLanguage")) return "不支持这对语言。";
        return $"{EngineDefinition.Get(id).Name} 返回错误 {code}。";
    }
    public static string HttpError(int status, string body)
    {
        var quota = false;
        try { using var json = JsonDocument.Parse(body); quota = json.RootElement.Property("error").Property("code").Text().Contains("quota"); } catch (JsonException) { }
        return status switch { 401 or 403 => "Key 无效或没有开通服务。", 402 or 456 => "额度用完了或账户欠费。", 429 => quota ? "额度用完了或账户欠费。" : "请求太频繁，请稍后再试。", 404 => "找不到这个模型或服务地址。", 503 or 529 => "服务暂时过载，请稍后再试。", _ => $"服务返回 HTTP {status}。" };
    }
    public static (string Piece, bool End) StreamPiece(EngineId engine, string data, string? eventName = null)
    {
        if (data == "[DONE]") return ("", true);
        JsonDocument document;
        try { document = JsonDocument.Parse(data); } catch (JsonException) { return ("", false); }
        using var documentLifetime = document; var root = document.RootElement;
        var type = root.Property("type").Text(); if (type.Length == 0) type = eventName ?? "";
        if (root.Property("error").ValueKind == JsonValueKind.Object || type == "error")
        {
            var error = root.Property("error"); var reason = error.Property("type").Text();
            throw new InvalidOperationException(reason switch {
                "overloaded_error" => "Claude 暂时过载，请稍后再试。", "rate_limit_error" => "请求太频繁，请稍后再试。",
                _ => (engine == EngineId.Claude ? "Claude：" : "大模型：") + (error.Property("message").Text() is { Length: > 0 } message ? message : "出错了") });
        }
        if (engine == EngineId.OpenAI)
            return (Items(root.Property("choices")).FirstOrDefault().Property("delta").Property("content").Text(), false);
        if (type == "message_delta" && root.Property("delta").Property("stop_reason").Text() == "refusal") throw new InvalidOperationException("Claude 拒绝翻译这段内容。");
        return (type == "content_block_delta" && root.Property("delta").Property("type").Text() == "text_delta" ? root.Property("delta").Property("text").Text() : "", type == "message_stop");
    }
}
