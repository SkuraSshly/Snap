using System.Windows;
using Velos.Core.Translation;
using Windows.Media.Core;
using Windows.Media.SpeechSynthesis;
using MediaPlayer = Windows.Media.Playback.MediaPlayer;

namespace Velos.Translation;

// 对应 Speaker.shared：所有翻译结果窗口共用一次朗读。
internal sealed class TranslationSpeaker
{
    public static TranslationSpeaker Shared { get; } = new();
    private CancellationTokenSource? pending;
    private SpeechSynthesizer? synthesizer;
    private SpeechSynthesisStream? stream;
    private MediaPlayer? player;
    public string? SpeakingId { get; private set; }
    public event Action? Changed;
    public async void Toggle(string text, TranslateLanguage language, string id, double rate, Action<string> error)
    {
        if (SpeakingId == id) { Stop(); return; }
        Stop(); if (string.IsNullOrWhiteSpace(text)) return;
        var operation = new CancellationTokenSource(); pending = operation; SpeakingId = id; Changed?.Invoke();
        try
        {
            synthesizer = new SpeechSynthesizer();
            var voices = SpeechSynthesizer.AllVoices.Where(voice => TranslateLanguage.FromLocale(voice.Language) == language).ToArray();
            var voice = voices.FirstOrDefault(voice => voice.Id == SpeechSynthesizer.DefaultVoice.Id) ?? voices.FirstOrDefault();
            if (voice is null) throw new InvalidOperationException("没有安装此语言的系统语音，请在 Windows 语言设置中添加语音包。");
            synthesizer.Voice = voice; synthesizer.Options.SpeakingRate = Math.Clamp(rate, .5, 2);
            var generated = await synthesizer.SynthesizeTextToStreamAsync(text.Trim()).AsTask(operation.Token);
            if (pending != operation || operation.IsCancellationRequested) { generated.Dispose(); return; }
            stream = generated; player = new MediaPlayer { Source = MediaSource.CreateFromStream(generated, generated.ContentType) };
            player.MediaEnded += (_, _) => Application.Current.Dispatcher.BeginInvoke(() => { if (pending == operation) Stop(); });
            player.MediaFailed += (_, _) => Application.Current.Dispatcher.BeginInvoke(() => { if (pending == operation) { Stop(); error("无法播放系统语音。"); } });
            player.Play();
        }
        catch (OperationCanceledException) { }
        catch (Exception failure) { if (pending == operation) { Stop(); error(failure.Message); } }
    }
    internal void StopOwned(string owner)
    {
        if (SpeakingId?.StartsWith(owner + ":", StringComparison.Ordinal) == true) Stop();
    }
    public void Stop()
    {
        var operation = pending; pending = null; operation?.Cancel(); operation?.Dispose(); SpeakingId = null;
        player?.Pause(); player?.Dispose(); player = null; stream?.Dispose(); stream = null; synthesizer?.Dispose(); synthesizer = null;
        Changed?.Invoke();
    }
#if DEBUG
    // Establish the same active-session state without generating or playing test audio.
    internal void DebugBeginSession(string id) { Stop(); pending = new CancellationTokenSource(); SpeakingId = id; Changed?.Invoke(); }
#endif
}
