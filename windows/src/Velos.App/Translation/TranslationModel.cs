using System.Windows.Threading;
using Velos.Core.Settings;
using Velos.Core.Translation;
using Velos.Windows.Translation;

namespace Velos.Translation;

// 对应 Mac TranslationModel；窗口只呈现状态，不再把状态塞进译文字符串。
internal sealed class TranslationModel : IDisposable
{
    internal enum Phase { Idle, Checking, Translating, Done, Failed }
    private readonly Func<TranslationPreferences> read;
    private readonly TranslationService service;
    private readonly Action<string> autoCopy;
    private readonly DispatcherTimer debounce = new() { Interval = TimeSpan.FromMilliseconds(600) };
    private CancellationTokenSource? request;
    private long generation;
    private bool disposed, composing;
    public event Action? Changed;
    public string SourceText { get; private set; } = "";
    public TranslateLanguage? SourceChoice { get; private set; }
    public TranslateLanguage? TargetChoice { get; private set; }
    public TranslateLanguage? Detected { get; private set; }
    public string Translation { get; private set; } = "";
    public bool IsPartial { get; private set; }
    public Phase Status { get; private set; }
    public string? Failure { get; private set; }
    public string? EngineNotice { get; private set; }
    public string? RecognitionFailure { get; private set; }
    public bool IsRecognizing { get; private set; } = true;
    public bool IsSlowRecognition { get; private set; }
    public TimeSpan? RecognitionTime { get; private set; }
    public EngineId Engine { get; private set; }
    public TranslateLanguage SourceLanguage => SourceChoice ?? Detected ?? TranslateLanguage.English;
    public TranslateLanguage TargetLanguage => LanguageRules.ResolvedTarget(TargetChoice ?? TranslateLanguage.FromLocale(read().DefaultTargetLanguage) ?? LanguageRules.DefaultTarget(SourceLanguage), SourceLanguage);
    public IReadOnlyList<EngineDefinition> Available => service.Available;

    public TranslationModel(Func<TranslationPreferences> read, TranslationService service, Action<string> autoCopy)
    {
        this.read = read; this.service = service; this.autoCopy = autoCopy;
        var available = service.Available;
        Engine = available.Any(item => item.Id == read().DefaultEngine) ? read().DefaultEngine : available.FirstOrDefault()?.Id ?? EngineId.None;
        debounce.Tick += (_, _) => { debounce.Stop(); _ = Translate(); };
    }
    public void Edit(string text)
    {
        if (disposed || SourceText == text) return;
        SourceText = text; Detected = OfflineOcr.DetectLanguage(text) ?? Detected;
        if (string.IsNullOrWhiteSpace(text))
        {
            Cancel(); Translation = ""; Status = Phase.Idle; IsPartial = false; Failure = EngineNotice = null; Notify(); return;
        }
        // Mac 保留旧译文；0.6 秒后进入翻译中，以淡色显示旧结果，首段新结果到达再替换。
        debounce.Stop(); if (!composing && !IsRecognizing && RecognitionFailure is null) debounce.Start(); Notify();
    }
    public void SetComposing(bool value)
    { composing = value; debounce.Stop(); if (!value && !IsRecognizing && RecognitionFailure is null) debounce.Start(); }
    public void Recognized(RecognitionResult result, TimeSpan elapsed)
    {
        if (disposed) return;
        SourceText = result.Text; Detected = TranslateLanguage.FromLocale(result.Language) ?? OfflineOcr.DetectLanguage(result.Text);
        RecognitionTime = elapsed; IsRecognizing = false; RecognitionFailure = null; IsSlowRecognition = false;
        Notify(); _ = Translate();
    }
    public void RecognitionFailed(string message)
    { if (disposed) return; IsRecognizing = false; RecognitionFailure = message; IsSlowRecognition = false; Notify(); }
    public void MarkSlowRecognition()
    { if (IsRecognizing && !disposed) { IsSlowRecognition = true; Notify(); } }
    public void ChooseLanguage(bool source, TranslateLanguage? language)
    {
        if (source) { if (SourceChoice == language) return; SourceChoice = language; }
        else { if (TargetChoice == language) return; TargetChoice = language; }
        Notify(); _ = Translate();
    }
    public void SwapLanguages()
    { var source = SourceLanguage; SourceChoice = TargetLanguage; TargetChoice = source; Notify(); _ = Translate(); }
    public void Use(EngineId engine) { Engine = engine; Notify(); _ = Translate(); }
    public async Task Translate()
    {
        debounce.Stop();
        if (disposed || IsRecognizing || RecognitionFailure is not null || composing) return;
        Cancel();
        if (string.IsNullOrWhiteSpace(SourceText))
        { Translation = ""; Status = Phase.Idle; IsPartial = false; Failure = null; EngineNotice = null; Notify(); return; }
        var version = ++generation; var operation = new CancellationTokenSource(); request = operation;
        var text = SourceText; var source = SourceLanguage; var target = TargetLanguage;
        bool Current() => !disposed && version == generation && !operation.IsCancellationRequested &&
            text == SourceText && source == SourceLanguage && target == TargetLanguage;
        Status = Phase.Translating; IsPartial = false; Failure = EngineNotice = null; Notify();
        try
        {
            var available = service.Available;
            var first = available.FirstOrDefault(item => item.Id == Engine) ?? available.FirstOrDefault();
            if (first is null)
            { Failure = "请在设置 › 截屏翻译中填写 Key 并启用翻译引擎。Windows 没有 Apple 离线翻译接口。"; Status = Phase.Failed; Notify(); return; }
            Engine = first.Id; Notify();
            var failures = new List<string>(); var attempt = 0;
            foreach (var engine in new[] { first }.Concat(available.Where(item => item.Id != first.Id)))
            {
                if (!Current()) return;
                var currentAttempt = ++attempt; IsPartial = false; Notify();
                try
                {
                    var result = await service.Translate(engine.Id, text, source, target,
                        new Progress<string>(partial =>
                        { if (Current() && attempt == currentAttempt) { Translation = partial; IsPartial = true; Notify(); } }), operation.Token);
                    attempt++;
                    if (!Current()) return;
                    Translation = OfflineOcr.NormalizeChinese(result.Trim(), target);
                    if (Translation.Length == 0) throw new InvalidOperationException(engine.Name + " 没有返回译文");
                    IsPartial = false; Engine = engine.Id;
                    EngineNotice = failures.Count == 0 ? null : string.Join("；", failures) + "，已切换到 " + engine.Name;
                    Status = Phase.Done; Notify();
                    if (read().AutoCopy) { try { autoCopy(Translation); } catch { /* 剪贴板失败不能误触发引擎回退。 */ } }
                    return;
                }
                catch (OperationCanceledException) when (operation.IsCancellationRequested) { return; }
                catch (Exception error)
                { attempt++; if (!Current()) return; failures.Add(engine.Name + " 失败（" + error.Message + "）"); }
            }
            if (Current()) { IsPartial = false; Failure = string.Join("；", failures); Status = Phase.Failed; Notify(); }
        }
        catch (OperationCanceledException) when (operation.IsCancellationRequested) { }
        catch (Exception error) { if (Current()) { IsPartial = false; Failure = error.Message; Status = Phase.Failed; Notify(); } }
        finally { if (ReferenceEquals(request, operation)) request = null; operation.Dispose(); }
    }
    public void Cancel(bool explain = false)
    {
        generation++; debounce.Stop(); var active = request; request = null; active?.Cancel();
        if (explain && active is not null && !disposed)
        { IsPartial = false; Failure = "翻译配置已更改，请重新翻译或选择已启用的引擎。"; Status = Phase.Failed; Notify(); }
    }
    private void Notify() { if (!disposed) Changed?.Invoke(); }
    public void Dispose() { if (disposed) return; disposed = true; Cancel(); Changed = null; }
#if DEBUG
    internal void DebugShow(string original, string translated)
    { Cancel(); SourceText = original; Translation = translated; Detected = OfflineOcr.DetectLanguage(original); IsRecognizing = false; RecognitionFailure = null; IsPartial = false; RecognitionTime = TimeSpan.FromSeconds(.27); Status = Phase.Done; Notify(); }
#endif
}
