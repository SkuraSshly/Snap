#if DEBUG
using System.Windows;
using Velos.Core.Settings;
using Velos.Core.Translation;
using Velos.Translation;
using Velos.Windows.Capture;

namespace Velos;

public partial class App
{
    private async Task ReviewTranslationSpeech(List<string> results)
    {
        var preferences = new TranslationPreferences { PinnedByDefault = true };
        var service = new TranslationService(() => preferences, (_, _) => "");
        var display = Desktop.Displays().First();
        var a = new TranslationWindow(new(display.WorkArea.Left + 50, display.WorkArea.Top + 50, 200, 160), () => preferences, service, () => { }, _ => { });
        var b = new TranslationWindow(new(display.WorkArea.Left + 700, display.WorkArea.Top + 50, 200, 160), () => preferences, service, () => { }, _ => { });
        try {
            a.DebugShow("First synthetic source", "第一个窗口"); b.DebugShow("Second synthetic source", "第二个窗口"); await SettleUI();
            var speaker = TranslationSpeaker.Shared;
            speaker.DebugBeginSession(a.DebugSpeechIdentity("source"));
            Check(a.DebugSourceSpeaking, "SP01", "正在朗读的翻译窗口显示停止按钮");
            var otherWasSpeaking = b.DebugSourceSpeaking;
            b.Close(); await SettleUI();
            Check(speaker.SpeakingId == a.DebugSpeechIdentity("source"), "SP03", "关闭未朗读的窗口不打断其他窗口");
            Check(!otherWasSpeaking, "SP02", "其他窗口的同类按钮不冒充正在朗读");
            speaker.Toggle("synthetic", TranslateLanguage.English, a.DebugSpeechIdentity("source"), 1, message => throw new InvalidOperationException(message));
            Check(speaker.SpeakingId is null && !a.DebugSourceSpeaking, "SP04", "同一窗口再次点击停止自己的朗读");
            speaker.DebugBeginSession(a.DebugSpeechIdentity("source")); a.Close();
            Check(speaker.SpeakingId is null, "SP05", "关闭正在朗读的窗口清理自身语音会话");
        } finally {
            TranslationSpeaker.Shared.Stop(); if (a.IsVisible) a.Close(); if (b.IsVisible) b.Close();
        }
        void Check(bool ok, string id, string message) { if (!ok) throw new InvalidOperationException($"[{id}] {message}"); results.Add($"通过  [{id}] {message}"); }
    }
}
#endif
