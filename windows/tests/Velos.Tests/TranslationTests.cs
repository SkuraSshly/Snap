using System.Net;
using System.Text;
using Velos.Core.Settings;
using Velos.Core.Translation;

internal static class TranslationTests
{
    public static (string Name, Action Run)[] Cases(Action<bool, string> check) =>
    [
        ("腾讯 TC3 规范请求与 Swift 官方例子哈希一致", () =>
        {
            var u = "\\u"; var payload = "{\"Limit\": 1, \"Filters\": [{\"Values\": [\"" + u + "672a" + u + "547d" + u + "540d\"], \"Name\": \"instance-name\"}]}";
            check(EngineSigning.Sha256(payload) == "35e9c5b0e3ae67532d3c9f17ead6c90222632e5b1ff7f6e89887f1398934f064", "请求体");
            check(EngineSigning.Sha256(EngineSigning.TencentCanonical("cvm.tencentcloudapi.com", "DescribeInstances", payload)) == "7019a55be8395899b900fb5564e4200d984910f34794a27cb3fb7d10ff6a1e84", "规范请求");
        }),
        ("百度签名与 Swift 官方例子一致", () => check(EngineSigning.Baidu("apple", "2015063000000001", "1435660288", "12345678") == "f89f9594663708c1605f3d736d01d2d4", "MD5")),
        ("有道长文本按前十字加长度加后十字签名", () => check(EngineSigning.Youdao("abcdefghijKLMNOPQRSTUVWXYZ0123456789", "k", "s", "1", "x") == EngineSigning.Sha256("kabcdefghij360123456789s1x"), "v3")),
        ("有道按可见字符处理组合字和表情", () => { var cluster = "👩‍💻"; var text = string.Concat(Enumerable.Repeat(cluster, 21)); var ten = string.Concat(Enumerable.Repeat(cluster, 10)); check(EngineSigning.Youdao(text, "k", "s", "1", "x") == EngineSigning.Sha256("k" + ten + "21" + ten + "s1x"), "字素长度"); }),
        ("DeepL 免费与专业 Key 使用对应接口", () => { check(EngineSigning.DeepL("abc:fx").Host == "api-free.deepl.com", "Free"); check(EngineSigning.DeepL("abc").Host == "api.deepl.com", "Pro"); }),
        ("默认目标语言按中文与其他语言切换", () => { check(LanguageRules.DefaultTarget(TranslateLanguage.Chinese) == TranslateLanguage.English, "中文"); check(LanguageRules.DefaultTarget(TranslateLanguage.All[1]) == TranslateLanguage.English, "繁体"); check(LanguageRules.DefaultTarget(null) == TranslateLanguage.Chinese, "未知"); }),
        ("相同原文和目标语言自动换另一种", () => { check(LanguageRules.ResolvedTarget(TranslateLanguage.English, TranslateLanguage.English) == TranslateLanguage.Chinese, "英语"); check(LanguageRules.ResolvedTarget(TranslateLanguage.Chinese, TranslateLanguage.Chinese) == TranslateLanguage.English, "中文"); }),
        ("语言地区标识映射与 Swift 规则一致", () => { check(TranslateLanguage.FromLocale("zh-TW") == TranslateLanguage.All[1], "台湾"); check(TranslateLanguage.FromLocale("zh-Hans-TW") == TranslateLanguage.Chinese, "显式脚本"); check(TranslateLanguage.FromLocale("nn-NO")?.Code == "nb", "挪威语"); }),
        ("大模型地址只接受 HTTP 并自动补全路径", () => { check(EngineSigning.OpenAIEndpoint("https://api.deepseek.com/v1/")?.AbsoluteUri == "https://api.deepseek.com/v1/chat/completions", "补全"); check(EngineSigning.OpenAIEndpoint("https://x.com/v1/chat/completions")?.AbsoluteUri == "https://x.com/v1/chat/completions", "不重复"); check(EngineSigning.OpenAIEndpoint("ftp://x.com") is null, "协议"); }),
        ("语言检测识别中英文与日文脚本", () => { check(LanguageRules.DetectScript("这是一段中文句子") == TranslateLanguage.Chinese, "中文"); check(LanguageRules.DetectScript("This is an English sentence") == TranslateLanguage.English, "英文"); check(LanguageRules.DetectScript("日本語のテスト")?.Code == "ja", "日文"); }),
        ("不支持的源语言按 Swift 规则退回自动识别", () =>
        {
            var hebrew = TranslateLanguage.FromLocale("he")!;
            using var baidu = EngineRequests.Create(EngineId.Baidu, "text", hebrew, TranslateLanguage.Chinese, _ => "synthetic", "", DateTimeOffset.UnixEpoch, "n");
            check(baidu.Content!.ReadAsStringAsync().GetAwaiter().GetResult().Contains("from=auto"), "百度自动识别");
            using var volc = EngineRequests.Create(EngineId.Volcengine, "text", hebrew, TranslateLanguage.Chinese, _ => "synthetic", "", DateTimeOffset.UnixEpoch, "n");
            check(!volc.Content!.ReadAsStringAsync().GetAwaiter().GetResult().Contains("SourceLanguage"), "火山省略来源");
            check(TranslateLanguage.FromLocale("zh-tw") == TranslateLanguage.All[1], "地区标识忽略大小写");
        }),
        ("八种引擎请求只构造文字与协议字段", () => { foreach (var engine in EngineDefinition.All) { using var request = EngineRequests.Create(engine.Id, "Hello Velos", TranslateLanguage.English, TranslateLanguage.Chinese, key => key == "baseURL" ? "https://example.invalid/v1" : "synthetic-key", "", DateTimeOffset.FromUnixTimeSeconds(1551113065), "nonce"); var body = request.Content!.ReadAsStringAsync().GetAwaiter().GetResult(); check(request.Method == HttpMethod.Post && request.RequestUri!.Scheme == "https" && body.Contains("Hello") && !body.Contains("image/"), engine.Name); } }),
        ("六种非流式引擎响应均可解析", () => { foreach (var (id, json) in new[] { (EngineId.Youdao, "{\"errorCode\":\"0\",\"translation\":[\"你好\"]}"), (EngineId.Baidu, "{\"trans_result\":[{\"dst\":\"你好\"}]}"), (EngineId.Tencent, "{\"Response\":{\"TargetText\":\"你好\"}}"), (EngineId.Volcengine, "{\"TranslationList\":[{\"Translation\":\"你好\"}]}"), (EngineId.Azure, "[{\"translations\":[{\"text\":\"你好\"}]}]"), (EngineId.DeepL, "{\"translations\":[{\"text\":\"你好\"}]}") }) check(EngineResponses.Parse(id, json) == "你好", id.ToString()); }),
        ("流式 OpenAI 和 Claude 输出按文本增量解析", () => { check(EngineResponses.StreamPiece(EngineId.OpenAI, "{\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}").Piece == "你好", "OpenAI"); check(EngineResponses.StreamPiece(EngineId.Claude, "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"你好\"}}").Piece == "你好", "Claude"); check(EngineResponses.StreamPiece(EngineId.OpenAI, "[DONE]").End, "结束"); }),
#if DEBUG
        ("未启用或无 Key 时不会进入 HTTP 管线", () => { var calls = 0; var options = new TranslationPreferences(); var service = new TranslationService(() => options, (_, _) => "") { DebugHandler = () => new FakeHandler(() => calls++) }; Try(); options = options with { EnabledEngines = EngineId.Youdao }; Try(); check(calls == 0, "无网络请求"); void Try() { try { service.Translate(EngineId.Youdao, "text", null, TranslateLanguage.Chinese, null, CancellationToken.None).GetAwaiter().GetResult(); throw new Exception("应拒绝请求"); } catch (InvalidOperationException) { } } }),
        ("本地假 HTTP 管线能够翻译且支持取消", () => { var calls = 0; var options = new TranslationPreferences { EnabledEngines = EngineId.Youdao }; var service = new TranslationService(() => options, (_, _) => "synthetic") { DebugHandler = () => new FakeHandler(() => calls++) }; check(service.Translate(EngineId.Youdao, "Hello", null, TranslateLanguage.Chinese, null, CancellationToken.None).GetAwaiter().GetResult() == "你好" && calls == 1, "假服务响应"); using var token = new CancellationTokenSource(); token.Cancel(); try { service.Translate(EngineId.Youdao, "Hello", null, TranslateLanguage.Chinese, null, token.Token).GetAwaiter().GetResult(); throw new Exception("应取消"); } catch (OperationCanceledException) { } }),
#endif
        ("翻译配置序列化不包含任何凭据", () => { var json = System.Text.Json.JsonSerializer.Serialize(new AppSettings { TranslationOptions = new TranslationPreferences { EnabledEngines = EngineId.Azure | EngineId.DeepL } }); check(!json.Contains("apiKey") && !json.Contains("secretKey") && !json.Contains("authKey"), "设置无 Key"); }),
        ("视频显式缩放保留颜色与原生直通", () => { var pixels = Enumerable.Repeat((byte)80, 8 * 4 * 4).ToArray(); check(ReferenceEquals(new Velos.Core.Recording.VideoScaler(new(8, 4), new(8, 4)).Scale(pixels), pixels), "原生直通"); var result = new Velos.Core.Recording.VideoScaler(new(8, 4), new(4, 2)).Scale(pixels); check(result.Length == 32 && result[0] == 80 && result[3] == 255, "缩放"); })
    ];
    private sealed class FakeHandler(Action called) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) { token.ThrowIfCancellationRequested(); called(); return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"errorCode\":\"0\",\"translation\":[\"你好\"]}", Encoding.UTF8, "application/json") }); }
    }
}

