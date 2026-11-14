using Velos.Core.Translation;

namespace Velos.Core.Settings;

public sealed record TranslationPreferences
{
    public string? PreferredRecognitionLanguage { get; init; }
    public bool SmartLayout { get; init; } = true;
    public EngineId EnabledEngines { get; init; }
    public EngineId DefaultEngine { get; init; } = EngineId.Tencent;
    public string? DefaultTargetLanguage { get; init; }
    public bool AutoCopy { get; init; }
    public bool PinnedByDefault { get; init; }
    public double SpeechRate { get; init; } = 1;
    public string LlmPrompt { get; init; } = "";
    public TranslationEngineOptions EngineOptions { get; init; } = new();
}

/// <summary>公开的服务配置；Key、Secret 和账号 ID 不进入此记录。</summary>
public sealed record TranslationEngineOptions
{
    public string OpenAiBaseUrl { get; init; } = "";
    public string OpenAiModel { get; init; } = "";
    public string ClaudeModel { get; init; } = "";
    public string TencentRegion { get; init; } = "";
    public string AzureRegion { get; init; } = "";
    public string Get(EngineId engine, string field) => (engine, field) switch
    {
        (EngineId.OpenAI, "baseURL") => OpenAiBaseUrl, (EngineId.OpenAI, "model") => OpenAiModel,
        (EngineId.Claude, "model") => ClaudeModel, (EngineId.Tencent, "region") => TencentRegion,
        (EngineId.Azure, "region") => AzureRegion, _ => ""
    };
    public TranslationEngineOptions Set(EngineId engine, string field, string value) => (engine, field) switch
    {
        (EngineId.OpenAI, "baseURL") => this with { OpenAiBaseUrl = value.Trim() },
        (EngineId.OpenAI, "model") => this with { OpenAiModel = value.Trim() },
        (EngineId.Claude, "model") => this with { ClaudeModel = value.Trim() },
        (EngineId.Tencent, "region") => this with { TencentRegion = value.Trim() },
        (EngineId.Azure, "region") => this with { AzureRegion = value.Trim() },
        _ => throw new ArgumentException("此字段不能存入普通设置。")
    };
}
