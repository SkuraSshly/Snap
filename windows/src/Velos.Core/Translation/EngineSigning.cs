using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace Velos.Core.Translation;

/// <summary>逐项移植 Mac 端签名与规范请求；不保存任何凭据。</summary>
public static class EngineSigning
{
    public static string Hex(byte[] data) => Convert.ToHexStringLower(data);
    public static string Sha256(string text) => Hex(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    public static byte[] Hmac(byte[] key, string text) => HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(text));
    public static string Baidu(string text, string appId, string salt, string secret) => Hex(MD5.HashData(Encoding.UTF8.GetBytes(appId + text + salt + secret)));
    public static string Youdao(string text, string appKey, string salt, string time, string secret)
    {
        var clusters = StringInfo.ParseCombiningCharacters(text);
        var input = clusters.Length > 20 ? text[..clusters[10]] + clusters.Length + text[clusters[^10]..] : text;
        return Sha256(appKey + input + salt + time + secret);
    }
    public static string TencentCanonical(string host, string action, string payload) =>
        string.Join('\n', "POST", "/", "", $"content-type:application/json; charset=utf-8\nhost:{host}\nx-tc-action:{action.ToLowerInvariant()}\n", "content-type;host;x-tc-action", Sha256(payload));
    public static string Tencent(string id, string key, string service, string host, string action, string payload, long timestamp, string date)
    {
        var scope = $"{date}/{service}/tc3_request";
        var signed = string.Join('\n', "TC3-HMAC-SHA256", timestamp.ToString(CultureInfo.InvariantCulture), scope, Sha256(TencentCanonical(host, action, payload)));
        var signing = Hmac(Hmac(Hmac(Encoding.UTF8.GetBytes("TC3" + key), date), service), "tc3_request");
        return $"TC3-HMAC-SHA256 Credential={id}/{scope}, SignedHeaders=content-type;host;x-tc-action, Signature={Hex(Hmac(signing, signed))}";
    }
    public const string VolcengineHost = "translate.volcengineapi.com", VolcengineQuery = "Action=TranslateText&Version=2020-06-01";
    public static string VolcengineCanonical(string hash, string date) => string.Join('\n', "POST", "/", VolcengineQuery,
        $"content-type:application/json\nhost:{VolcengineHost}\nx-content-sha256:{hash}\nx-date:{date}\n", "content-type;host;x-content-sha256;x-date", hash);
    public static string Volcengine(string id, string key, string hash, string date)
    {
        var scope = $"{date[..8]}/cn-north-1/translate/request";
        var signed = string.Join('\n', "HMAC-SHA256", date, scope, Sha256(VolcengineCanonical(hash, date)));
        var signing = Hmac(Hmac(Hmac(Hmac(Encoding.UTF8.GetBytes(key), date[..8]), "cn-north-1"), "translate"), "request");
        return $"HMAC-SHA256 Credential={id}/{scope}, SignedHeaders=content-type;host;x-content-sha256;x-date, Signature={Hex(Hmac(signing, signed))}";
    }
    public static Uri DeepL(string key) => new(key.EndsWith(":fx", StringComparison.Ordinal) ? "https://api-free.deepl.com/v2/translate" : "https://api.deepl.com/v2/translate");
    public static Uri? OpenAIEndpoint(string url)
    {
        var text = url.Trim().TrimEnd('/');
        if (!text.EndsWith("/chat/completions", StringComparison.Ordinal)) text += "/chat/completions";
        return Uri.TryCreate(text, UriKind.Absolute, out var uri) && uri.Scheme is "https" or "http" && !string.IsNullOrWhiteSpace(uri.Host) ? uri : null;
    }
    public const string DefaultPrompt = "你是专业的翻译。把用户发来的文本从{source}翻译成{target}。\n只输出译文本身：不要解释，不要加引号、标题或任何前后缀。\n保留原文的段落、换行、列表和标点格式；人名、品牌、产品名、代码、网址等专有名词保持原样或使用通行译法。";
    public static string Prompt(TranslateLanguage? source, TranslateLanguage target, string? custom) =>
        (string.IsNullOrWhiteSpace(custom) ? DefaultPrompt : custom).Replace("{source}", source?.Name ?? "原文语言").Replace("{target}", target.Name);
}
