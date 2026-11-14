using System.Globalization;

namespace Velos.Core.Translation;

public sealed record TranslateLanguage(string Code, string Name)
{
    public bool IsChinese => Code is "zh-Hans" or "zh-Hant";
    public bool NeedsWordSpacing => Code is not ("zh-Hans" or "zh-Hant" or "ja" or "ko" or "th");
    public static IReadOnlyList<TranslateLanguage> All { get; } = Array.AsReadOnly(new[] {
        new TranslateLanguage("zh-Hans", "简体中文"), new("zh-Hant", "繁体中文"), new("en", "英语"), new("ja", "日语"), new("ko", "韩语"),
        new("fr", "法语"), new("es", "西班牙语"), new("pt", "葡萄牙语"), new("it", "意大利语"), new("de", "德语"), new("ru", "俄语"),
        new("uk", "乌克兰语"), new("th", "泰语"), new("vi", "越南语"), new("ar", "阿拉伯语"), new("tr", "土耳其语"), new("id", "印尼语"),
        new("cs", "捷克语"), new("da", "丹麦语"), new("nl", "荷兰语"), new("nb", "挪威语"), new("ms", "马来语"), new("pl", "波兰语"),
        new("ro", "罗马尼亚语"), new("sv", "瑞典语"), new("fi", "芬兰语"), new("el", "希腊语"), new("he", "希伯来语"), new("hi", "印地语"),
        new("hu", "匈牙利语"), new("fa", "波斯语"), new("ca", "加泰罗尼亚语") });
    public static TranslateLanguage Chinese => All[0];
    public static TranslateLanguage English => All[2];
    public static TranslateLanguage? FromLocale(string? identifier)
    {
        if (string.IsNullOrWhiteSpace(identifier)) return null;
        var parts = identifier.Replace('_', '-').Split('-');
        if (parts[0].Equals("zh", StringComparison.OrdinalIgnoreCase))
            return parts.Contains("Hant", StringComparer.OrdinalIgnoreCase) || !parts.Contains("Hans", StringComparer.OrdinalIgnoreCase) && parts.Any(p => p.ToUpperInvariant() is "TW" or "HK" or "MO") ? All[1] : All[0];
        var code = parts[0].ToLowerInvariant(); if (code is "no" or "nn") code = "nb";
        return All.FirstOrDefault(l => l.Code == code);
    }
    public override string ToString() => Name;
}

public static class LanguageRules
{
    public static IReadOnlyList<TranslateLanguage> MenuLanguages { get; } = Array.AsReadOnly(new[]
    { "zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "pt", "it", "ru", "uk", "ar", "hi", "id", "vi", "th", "tr", "nl", "pl" }
        .Select(code => TranslateLanguage.All.First(language => language.Code == code)).ToArray());
    public static TranslateLanguage DefaultTarget(TranslateLanguage? source) => source?.IsChinese == true ? TranslateLanguage.English : TranslateLanguage.Chinese;
    public static TranslateLanguage ResolvedTarget(TranslateLanguage target, TranslateLanguage source) => target == source ? DefaultTarget(source) : target;
    public static TranslateLanguage? DetectScript(string text)
    {
        var chars = text.EnumerateRunes().Select(r => r.Value).ToArray();
        string? code = chars.Any(c => c is >= 0x3040 and <= 0x30ff) ? "ja" : chars.Any(c => c is >= 0xac00 and <= 0xd7af) ? "ko" :
            chars.Any(c => c is >= 0x3400 and <= 0x9fff) ? (text.Any(c => "體傳統與這個們時畫譯語國學聲麥風錄簡繁".Contains(c)) ? "zh-Hant" : "zh-Hans") :
            chars.Any(c => c is >= 0x400 and <= 0x52f) ? (text.Any(c => "іїєґІЇЄҐ".Contains(c)) ? "uk" : "ru") :
            chars.Any(c => c is >= 0xe00 and <= 0xe7f) ? "th" : chars.Any(c => c is >= 0x590 and <= 0x5ff) ? "he" :
            chars.Any(c => c is >= 0x600 and <= 0x6ff) ? "ar" : chars.Any(c => c is >= 0x900 and <= 0x97f) ? "hi" :
            chars.Any(c => c is >= 0x370 and <= 0x3ff) ? "el" : chars.Any(c => char.IsAsciiLetter((char)c)) ? "en" : null;
        return TranslateLanguage.FromLocale(code);
    }
}
