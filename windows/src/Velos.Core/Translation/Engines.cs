namespace Velos.Core.Translation;

[Flags] public enum EngineId { None = 0, Youdao = 1, DeepL = 2, Azure = 4, Baidu = 8, Tencent = 16, Volcengine = 32, OpenAI = 64, Claude = 128 }
public sealed record CredentialField(string Id, string Label, bool Secret = false, bool Optional = false);
public sealed record EngineDefinition(EngineId Id, string Name, CredentialField[] Fields)
{
    public override string ToString() => Name;
    public bool IsLlm => Id is EngineId.OpenAI or EngineId.Claude;
    public bool HasCredentials(Func<string, string> read) => Fields.Where(f => !f.Optional).All(f => !string.IsNullOrWhiteSpace(read(f.Id)));
    public static IReadOnlyList<EngineDefinition> All { get; } = Array.AsReadOnly(new[] {
        new EngineDefinition(EngineId.Youdao, "有道智云", [new("appKey", "应用 ID", true), new("appSecret", "应用密钥", true)]),
        new(EngineId.DeepL, "DeepL", [new("authKey", "API Key", true)]),
        new(EngineId.Azure, "微软翻译", [new("key", "密钥", true), new("region", "区域", false, true)]),
        new(EngineId.Baidu, "百度翻译", [new("appid", "APP ID", true), new("secret", "密钥", true)]),
        new(EngineId.Tencent, "腾讯翻译君", [new("secretId", "SecretId", true), new("secretKey", "SecretKey", true), new("region", "地域", false, true)]),
        new(EngineId.Volcengine, "火山翻译", [new("accessKeyId", "Access Key ID", true), new("secretAccessKey", "Secret Access Key", true)]),
        new(EngineId.OpenAI, "大模型（OpenAI 兼容）", [new("baseURL", "Base URL"), new("model", "模型"), new("apiKey", "API Key", true)]),
        new(EngineId.Claude, "Claude", [new("apiKey", "API Key", true), new("model", "模型（默认 claude-opus-5-5）", false, true)]) });
    public static EngineDefinition Get(EngineId id) => All.First(e => e.Id == id);
}
