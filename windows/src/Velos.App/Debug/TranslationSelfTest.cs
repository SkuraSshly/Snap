#if DEBUG
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Velos.Core.Settings;
using Velos.Core.Translation;
using Velos.Translation;
using Velos.UI;
using Velos.Windows.Capture;
using Velos.Windows.Translation;
using Windows.Media.SpeechSynthesis;
using PixelRect = System.Drawing.Rectangle;

namespace Velos;

public partial class App
{
    private async void RunTranslationSelfTest(string profile, bool idle)
    {
        var results = new List<string>(); var exit = 1; Directory.CreateDirectory(profile);
        try
        {
            if (Environment.GetCommandLineArgs().Contains("--speech-regression"))
            { await ReviewTranslationSpeech(results); exit = 0; return; }
            if (Environment.GetCommandLineArgs().Contains("--verify-settings-flow"))
            { await ReviewTranslationSettings(profile, results); exit = 0; return; }
            var credentials = new CredentialStore("Velos/SelfTest/" + Guid.NewGuid().ToString("N") + "/");
            try { credentials.Set(EngineId.DeepL, "authKey", "synthetic-测试凭据"); Check(credentials.Get(EngineId.DeepL, "authKey") == "synthetic-测试凭据", "Windows 凭据管理器独立条目可读写"); }
            finally { credentials.ClearAll(); }
            Check(credentials.Get(EngineId.DeepL, "authKey") == "", "自测凭据已移除，未触碰用户正式凭据");
            Check(OfflineOcr.NormalizeChinese("傳統字符與簡化字符不同", TranslateLanguage.Chinese) == "传统字符与简化字符不同" &&
                OfflineOcr.NormalizeChinese("简体中文", TranslateLanguage.All[1]) == "簡體中文", "系统离线繁简转换与 Swift 基线一致");
            var languages = OfflineOcr.Languages(); results.Add("环境  OCR 语言包：" + string.Join("、", languages.Select(l => l.Code)));
            var image = SyntheticText("Hello Velos screenshot", 840, 120);
            var pixels = new byte[840 * 120 * 4]; image.CopyPixels(pixels, 840 * 4, 0);
            var preferences = new TranslationPreferences { PreferredRecognitionLanguage = languages.FirstOrDefault().Code };
            if (languages.Count > 0)
            {
                var recognized = await OcrWorker.Recognize(pixels, 840, 120, preferences, CancellationToken.None);
                Check(recognized.Text.Contains("Hello") && recognized.Text.Contains("screenshot"), "独立 OCR 进程识别合成英文并返回原文");
                results.Add("环境  合成识别结果：" + recognized.Text);
            }
            else results.Add("环境  未安装 OCR 包，识别会引导安装语言包");
            using (var synth = new SpeechSynthesizer())
            {
                if (SpeechSynthesizer.AllVoices.Count > 0)
                {
                    using var speech = await synth.SynthesizeTextToStreamAsync("Velos synthetic speech");
                    Check(speech.Size > 44, "系统语音可生成合成音频（不播放）");
                }
                else results.Add("环境  未安装系统语音，朗读会提示安装语音包");
            }
            var monitor = Desktop.Displays().First();
            var bounds = new PixelRect(monitor.WorkArea.X + 20, monitor.WorkArea.Y + 20, Math.Min(1280, monitor.WorkArea.Width - 40), Math.Min(800, monitor.WorkArea.Height - 40));
            var display = new Display(monitor.Handle, bounds, bounds);
            foreach (var dark in new[] { false, true })
            {
                WarmTheme.DebugSetDark(dark); var suffix = dark ? "深色" : "浅色";
                OpenSettings(); ((RadioButton)settingsWindow!.FindName("TranslationTab")).IsChecked = true;
                await SettleUI();
                WriteSettingsImage(settingsWindow, Path.Combine(profile, "翻译设置-" + suffix + ".png"));
                ((ScrollViewer)settingsWindow.FindName("PageScroll")).ScrollToBottom(); await SettleUI();
                WriteSettingsImage(settingsWindow, Path.Combine(profile, "翻译设置底部-" + suffix + ".png")); settingsWindow.Close();
                var selector = new TranslationSelectionWindow(display, SyntheticImage(bounds.Width, bounds.Height), [], _ => { }, () => { });
                selector.ShowOnDisplay(); selector.Surface.DebugDrag(new System.Drawing.Point(160, 140), new System.Drawing.Point(800, 560));
                await SettleUI();
                WriteRecordingComposite(display, [selector], Path.Combine(profile, "翻译选区-" + suffix + ".png")); selector.Close();
                var anchor = new PixelRect(bounds.X + 40, bounds.Y + 40, 200, 180);
                var noNetwork = new TranslationService(() => new TranslationPreferences(), (_, _) => "");
                var window = new TranslationWindow(anchor, () => new TranslationPreferences(), noNetwork, () => { }, _ => { });
                await SettleUI();
                WriteRecordingComposite(display, [window], Path.Combine(profile, "翻译识别中-" + suffix + ".png"));
                window.DebugShow("Velos translate test\n截屏翻译自测", "这是合成的翻译结果。\n只用于界面对照，不访问在线服务。");
                await Task.Delay(240);
                await SettleUI();
                WriteTranslationImage(window, Path.Combine(profile, "翻译结果-" + suffix + ".png"));
                window.DebugOpenEngineMenu(); await Task.Delay(120);
                Check(window.IsVisible && window.DebugEngineMenuOpen, "引擎菜单打开时未钉住的翻译窗口保持显示"); window.DebugCloseEngineMenu();
                Check(Desktop.DebugIsExcluded(new WindowInteropHelper(window).Handle), suffix + "翻译结果从截图中排除");
                Desktop.SetRecordingActive(true); Check(!Desktop.DebugIsExcluded(new WindowInteropHelper(window).Handle), "录屏时翻译结果可见"); Desktop.SetRecordingActive(false);
                var compactHeight = window.ActualHeight;
                window.TogglePin(); Check(window.IsPinned && window.ResizeMode == ResizeMode.CanResize, "钉住后可调整大小");
                await SettleUI(); Check(!window.DebugFreeSized && window.SizeToContent == SizeToContent.Height && Math.Abs(compactHeight - window.ActualHeight) < 2, "Mac 语义：仅钉住不撑高卡片，开始调整大小后才自由布局");
                WriteTranslationImage(window, Path.Combine(profile, "翻译钉住-" + suffix + ".png"));
                if (!dark && Environment.GetCommandLineArgs().Contains("--verify-native-resize"))
                {
                    // 仅这个合成验收窗口可被电脑操作工具发现和截图，不改变产品的窗口排除策略。
                    window.Title = "Velos 原生边框自测"; window.ShowInTaskbar = true;
                    Desktop.ExcludeFromCapture(new WindowInteropHelper(window).Handle, false);
                    File.WriteAllText(Path.Combine(profile, "等待原生缩放.txt"), "合成结果窗口已钉住，等待原生边框拖动。");
                    for (var attempt = 0; attempt < 600 && !window.DebugFreeSized; attempt++) await Task.Delay(100);
                    Check(window.DebugFreeSized, "原生鼠标拖动边框实际触发自由布局，未通过调试方法代替");
                    File.WriteAllText(Path.Combine(profile, "原生缩放通过.txt"), "原生边框拖动已触发自由布局。"); await Task.Delay(5000);
                }
                window.DebugBeginResize();
                await Task.Delay(240); window.UpdateLayout(); var initialTextHeight = window.DebugSourceHeight;
                window.Height = Math.Min(window.MaxHeight, window.ActualHeight + 220); window.Width = 560;
                await SettleUI(); window.UpdateLayout();
                Check(window.DebugSourceHeight > initialTextHeight + 40, "钉住后扩大窗口，原文和译文卡片同步伸展");
                WriteTranslationImage(window, Path.Combine(profile, "翻译调整大小-" + suffix + ".png"));
                var unchangedSource = window.DebugSource; window.DebugSwap();
                Check(window.DebugSource == unchangedSource, "Mac 语义：交换语言保持原文，不用旧译文替换原文");
                window.DebugEdit("");
                Check(window.DebugOutput == "" && !window.DebugHasCopyableTranslation, "清空原文立即清除旧译文和可复制内容");
                window.TogglePin(); await SettleUI();
                Check(window.Width == 420 && window.SizeToContent == SizeToContent.Height, "取消钉住恢复紧凑布局");
                if (!dark && Environment.GetCommandLineArgs().Contains("--verify-translation-input"))
                {
                    window.DebugShow("Native input source", "合成译文，仅用于窗口操作检查。");
                    window.Title = "Velos 翻译窗口操作验收"; window.ShowInTaskbar = true;
                    Desktop.ExcludeFromCapture(new WindowInteropHelper(window).Handle, false);
                    var before = window.PointToScreen(new Point());
                    File.WriteAllText(Path.Combine(profile, "等待翻译操作.txt"), "未钉住：从最外侧边缘拖动；Ctrl+P 钉住后调整边缘大小。创建继续翻译验收.txt 结束。");
                    for (var i = 0; i < 3000 && !File.Exists(Path.Combine(profile, "继续翻译验收.txt")); i++) await Task.Delay(100);
                    var after = window.PointToScreen(new Point());
                    Check(Math.Abs(after.X - before.X) + Math.Abs(after.Y - before.Y) > 30, "原生鼠标从未钉住的外侧边缘实际移动窗口");
                    Check(window.IsPinned && window.DebugFreeSized, "原生输入钉住后拖边缘实际触发缩放");
                }
                window.Close();
                Check(noNetwork.Available.Count == 0, "默认无可用在线引擎，不发网络请求");
                results.Add("通过  " + suffix + "翻译设置、选区、识别占位、结果、钉住界面");
            }
            await ReviewTranslationSettings(profile, results);
            await ReviewTranslationModel(results);
            await ReviewTranslationSpeech(results);
            exit = 0;
        }
        catch (Exception error) { results.Add("失败  " + error); }
        finally
        {
            Desktop.SetRecordingActive(false); WarmTheme.Refresh(); foreach (var window in Windows.Cast<Window>().ToArray()) window.Close();
            File.WriteAllLines(Path.Combine(profile, "结果.txt"), results);
            if (idle && exit == 0) { File.WriteAllText(Path.Combine(profile, "空闲就绪.txt"), ""); await Task.Delay(TimeSpan.FromSeconds(38)); }
            Shutdown(exit);
        }
        void Check(bool value, string description) { if (!value) throw new InvalidOperationException(description); results.Add("通过  " + description); }
    }
    private static BitmapSource SyntheticText(string text, int width, int height)
    {
        var drawing = new DrawingVisual(); using (var dc = drawing.RenderOpen())
        {
            dc.DrawRectangle(Brushes.White, null, new Rect(0, 0, width, height));
            dc.DrawText(new FormattedText(text, System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                new Typeface("Segoe UI"), 56, Brushes.Black, 1), new Point(28, 18));
        }
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32); bitmap.Render(drawing); bitmap.Freeze(); return bitmap;
    }
    private static void WriteTranslationImage(Window window, string path)
    {
        window.UpdateLayout(); var element = (FrameworkElement)window.Content; var dpi = VisualTreeHelper.GetDpi(element);
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(element.ActualWidth * dpi.DpiScaleX), (int)Math.Ceiling(element.ActualHeight * dpi.DpiScaleY), dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
        bitmap.Render(element); File.WriteAllBytes(path, Screenshot.ShotEncoding.Encode(bitmap));
    }
}
#endif
