using System.Globalization;
using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace Velos.Core.Translation;

public static class EngineRequests
{
    public static HttpRequestMessage Create(EngineId engine, string text, TranslateLanguage? source, TranslateLanguage target,
        Func<string, string> credential, string prompt, DateTimeOffset now, string nonce)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, "https://localhost/");
        string Key(string field) => credential(field);
        void Url(string url) => request.RequestUri = new Uri(url);
        void Header(string key, string value) => request.Headers.TryAddWithoutValidation(key, value);
        void Json(object body, bool charset = false) { request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
            if (!charset) request.Content.Headers.ContentType!.CharSet = null; }
        void Form(params (string, string)[] fields) { request.Content = new StringContent(string.Join('&', fields.Select(f => Uri.EscapeDataString(f.Item1) + "=" + Uri.EscapeDataString(f.Item2))), Encoding.UTF8, "application/x-www-form-urlencoded"); request.Content.Headers.ContentType!.CharSet = null; }
        var time = now.ToUnixTimeSeconds();
        string? sourceCode = null;
        if (source is not null) try { sourceCode = LanguageCode(engine, source, false); } catch (InvalidOperationException) { }
        var from = sourceCode ?? "auto";
        var to = LanguageCode(engine, target, true);
        switch (engine)
        {
            case EngineId.Youdao:
                Url("https://openapi.youdao.com/api");
                Form(("q", text), ("from", from), ("to", to), ("appKey", Key("appKey")), ("salt", nonce),
                    ("sign", EngineSigning.Youdao(text, Key("appKey"), nonce, time.ToString(CultureInfo.InvariantCulture), Key("appSecret"))), ("signType", "v3"), ("curtime", time.ToString(CultureInfo.InvariantCulture)), ("strict", "true")); break;
            case EngineId.Baidu:
                Url("https://fanyi-api.baidu.com/api/trans/vip/translate");
                Form(("q", text), ("from", from), ("to", to), ("appid", Key("appid")), ("salt", nonce), ("sign", EngineSigning.Baidu(text, Key("appid"), nonce, Key("secret")))); break;
            case EngineId.DeepL:
                request.RequestUri = EngineSigning.DeepL(Key("authKey")); Header("Authorization", "DeepL-Auth-Key " + Key("authKey"));
                var deepl = new Dictionary<string, object> { ["text"] = new[] { text }, ["target_lang"] = to };
                if (source is not null) deepl["source_lang"] = from; Json(deepl); break;
            case EngineId.Azure:
                Url("https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=" + Uri.EscapeDataString(to) + (source is null ? "" : "&from=" + Uri.EscapeDataString(from)));
                Header("Ocp-Apim-Subscription-Key", Key("key")); if (Key("region").Length > 0) Header("Ocp-Apim-Subscription-Region", Key("region")); Json(new[] { new { Text = text } }, true); break;
            case EngineId.Tencent:
                const string host = "tmt.tencentcloudapi.com";
                Url("https://" + host + "/");
                var tencent = new SortedDictionary<string, object>(StringComparer.Ordinal) { ["SourceText"] = text, ["Source"] = from, ["Target"] = to, ["ProjectId"] = 0 };
                var payload = JsonSerializer.Serialize(tencent);
                request.Content = new StringContent(payload, Encoding.UTF8, "application/json");
                Header("Host", host); Header("X-TC-Action", "TextTranslate"); Header("X-TC-Timestamp", time.ToString(CultureInfo.InvariantCulture)); Header("X-TC-Version", "2018-03-21");
                Header("X-TC-Region", string.IsNullOrEmpty(Key("region")) ? "ap-guangzhou" : Key("region"));
                Header("Authorization", EngineSigning.Tencent(Key("secretId"), Key("secretKey"), "tmt", host, "TextTranslate", payload, time, now.UtcDateTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture))); break;
            case EngineId.Volcengine:
                Url("https://" + EngineSigning.VolcengineHost + "/?" + EngineSigning.VolcengineQuery);
                var body = new SortedDictionary<string, object>(StringComparer.Ordinal) { ["TargetLanguage"] = to, ["TextList"] = new[] { text } };
                if (sourceCode is not null) body["SourceLanguage"] = sourceCode; var volc = JsonSerializer.Serialize(body); var hash = EngineSigning.Sha256(volc);
                request.Content = new StringContent(volc, Encoding.UTF8, "application/json"); request.Content.Headers.ContentType!.CharSet = null;
                var date = now.UtcDateTime.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
                Header("Host", EngineSigning.VolcengineHost); Header("X-Date", date); Header("X-Content-Sha256", hash);
                Header("Authorization", EngineSigning.Volcengine(Key("accessKeyId"), Key("secretAccessKey"), hash, date)); break;
            case EngineId.OpenAI:
                request.RequestUri = EngineSigning.OpenAIEndpoint(Key("baseURL")) ?? throw new InvalidOperationException("Base URL 无效。");
                Header("Authorization", "Bearer " + Key("apiKey"));
                Json(new { model = Key("model"), stream = true, messages = new[] { new { role = "system", content = EngineSigning.Prompt(source, target, prompt) }, new { role = "user", content = text } } }); break;
            case EngineId.Claude:
                Url("https://api.anthropic.com/v1/messages"); Header("x-api-key", Key("apiKey")); Header("anthropic-version", "2026-10-21");
                var model = string.IsNullOrWhiteSpace(Key("model")) ? "claude-opus-5-5" : Key("model");
                var claude = new Dictionary<string, object> { ["model"] = model, ["max_tokens"] = 16000, ["stream"] = true, ["output_config"] = new { effort = "low" },
                    ["system"] = EngineSigning.Prompt(source, target, prompt), ["messages"] = new[] { new { role = "user", content = text } } };
                if (new[] { "claude-opus-5-5", "claude-fable-5-1", "claude-opus-5", "claude-sonnet-5-5" }.Contains(model))
                { claude["fallbacks"] = "default"; Header("anthropic-beta", "server-side-fallback-2026-07-01"); }
                Json(claude); break;
            default: request.Dispose(); throw new ArgumentOutOfRangeException(nameof(engine));
        }
        return request;
    }

    public static string LanguageCode(EngineId engine, TranslateLanguage language, bool target)
    {
        var code = language.Code;
        return engine switch
        {
            EngineId.Youdao => code switch { "zh-Hans" => "zh-CHS", "zh-Hant" => "zh-CHT", "nb" => "no", _ => code },
            EngineId.DeepL => code switch { "zh-Hans" => target ? "ZH-HANS" : "ZH", "zh-Hant" => target ? "ZH-HANT" : "ZH", "en" => target ? "EN-US" : "EN", "pt" => target ? "PT-BR" : "PT", _ => code.ToUpperInvariant() },
            EngineId.Baidu => code switch { "zh-Hans" => "zh", "zh-Hant" => "cht", "en" => "en", "ja" => "jp", "ko" => "kor", "fr" => "fra", "es" => "spa", "ar" => "ara", "vi" => "vie", "uk" => "ukr", "da" => "dan", "ro" => "rom", "sv" => "swe", "el" => "el",
                "de" or "ru" or "pt" or "it" or "th" or "id" or "hi" or "tr" or "nl" or "pl" or "cs" or "fi" or "hu" => code, _ => throw new InvalidOperationException("百度不支持这对语言。") },
            EngineId.Tencent => code switch { "zh-Hans" => "zh", "zh-Hant" => "zh-TW", "en" or "ja" or "ko" or "fr" or "es" or "it" or "de" or "tr" or "ru" or "pt" or "vi" or "id" or "th" or "ms" or "ar" or "hi" => code, _ => throw new InvalidOperationException("腾讯不支持这对语言。") },
            EngineId.Volcengine => code switch { "zh-Hans" => "zh", "zh-Hant" => "zh-Hant", "en" or "ja" or "ko" or "fr" or "de" or "es" or "ru" or "pt" or "it" or "ar" or "th" or "vi" or "id" or "hi" or "tr" or "nl" or "pl" or "uk" => code, _ => throw new InvalidOperationException("火山不支持这对语言。") },
            _ => code
        };
    }
}
