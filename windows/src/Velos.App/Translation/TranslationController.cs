using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velos.Core.Settings;
using Velos.Core.Translation;
using Velos.Screenshot;
using Velos.Windows.Capture;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.Translation;

internal sealed class TranslationController : IDisposable
{
    private readonly Func<TranslationPreferences> read;
    private readonly TranslationService service;
    private readonly Action openSettings;
    private readonly Action<string> copy, error;
    private readonly List<TranslationSelectionWindow> selectors = [];
    private readonly SelectionGroup selectionGroup = new();
    private readonly List<TranslationWindow> results = [];
    private CancellationTokenSource? capture;
    private CancellationTokenSource? recognition;
    private TranslationWindow? recognizingWindow;
    private bool disposed, pendingFull;
    private SelectionFocus? focus;
    public bool IsSelecting => capture is not null || selectors.Count > 0;
    public TranslationController(Func<TranslationPreferences> read, TranslationService service, Action openSettings, Action<string> copy, Action<string> error)
    { this.read = read; this.service = service; this.openSettings = openSettings; this.copy = copy; this.error = error; }
    public async void Toggle(bool fromTray)
    {
        if (disposed) return;
        if (capture is not null) { pendingFull = !pendingFull; return; }
        if (selectors.Count > 0)
        {
            selectionGroup.Toggle(); return;
        }
        using var operation = new CancellationTokenSource(); capture = operation; pendingFull = false;
        OcrWorker.WarmUp(read());
        focus = new SelectionFocus(session => Application.Current.Dispatcher.BeginInvoke(() => { if (ReferenceEquals(focus, session)) CancelSelection(); }));
        try
        {
            if (fromTray) await Task.Delay(220, operation.Token);
            var displays = Desktop.Displays(); var windows = Desktop.WindowBounds(results.Select(w => new WindowInteropHelper(w).Handle).ToHashSet());
            var hidden = results.Where(w => w.IsVisible).ToArray();
            (Display Display, BitmapSource Photo)[] images;
            try
            {
                foreach (var window in hidden) window.Hide(); Desktop.FlushComposition();
                images = await Task.WhenAll(displays.Select(async display =>
                {
                    var pixels = await WindowsCapture.FreezeDisplay(display, false, operation.Token).ConfigureAwait(false);
                    var photo = BitmapSource.Create(pixels.Width, pixels.Height, 96, 96, PixelFormats.Bgra32, null, pixels.Bgra, pixels.Width * 4); photo.Freeze();
                    return (display, photo);
                }));
            }
            finally { if (!disposed) foreach (var window in hidden.Where(results.Contains)) window.Show(); }
            operation.Token.ThrowIfCancellationRequested();
            foreach (var (display, photo) in images)
            {
                var selector = new TranslationSelectionWindow(display, photo, windows, Confirm, CancelSelection); selectors.Add(selector); selector.ShowOnDisplay();
                selectionGroup.Add(selector, display, selector.Surface, selector.SetSuppressed);
                selector.Closed += (_, _) => { if (selectors.Remove(selector)) CancelSelection(); };
            }
            if (selectors.Count == 0) throw new InvalidOperationException("没有可用的显示器。");
            var point = Desktop.Pointer(); var active = selectors.FirstOrDefault(s => s.Display.Bounds.Contains(point)) ?? selectors[0]; active.Surface.SetFullScreen(pendingFull); active.Activate();
        }
        catch (OperationCanceledException) { }
        catch (Exception exception) { CancelSelection(); error($"无法打开截屏翻译选区。（0x{exception.HResult:X8}）"); }
        finally { if (capture == operation) capture = null; }
    }
    public void CancelSelection()
    {
        var previousFocus = focus; focus = null; previousFocus?.Dispose();
        capture?.Cancel(); selectionGroup.Clear();
        var open = selectors.ToArray(); selectors.Clear(); foreach (var selector in open) selector.Close();
    }
    private void Confirm(TranslationSelectionWindow selector)
    {
        if (selector.Surface.Target is not { Width: > 1, Height: > 1 } region) return;
        try
        {
            var bitmap = selector.Surface.RenderCrop(region); var pixels = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4];
            if (bitmap.Format != PixelFormats.Bgra32 && bitmap.Format != PixelFormats.Pbgra32) bitmap = new FormatConvertedBitmap(bitmap, PixelFormats.Bgra32, null, 0);
            bitmap.CopyPixels(pixels, bitmap.PixelWidth * 4, 0);
            var location = new PixelRect(region.X + selector.Display.Bounds.X, region.Y + selector.Display.Bounds.Y, region.Width, region.Height);
            CancelSelection();
            foreach (var old in results.Where(w => !w.IsPinned).ToArray()) old.Close();
            recognition?.Cancel();
            if (recognizingWindow is { IsClosed: false } previous && previous.Model.IsRecognizing) previous.Model.RecognitionFailed("识别已被新的截屏翻译取消");
            var model = new TranslationModel(read, service, copy);
            var result = new TranslationWindow(location, model, read, openSettings, copy); results.Add(result);
            result.Closed += (_, _) => results.Remove(result);
            result.PinChanged += window => { if (!window.IsPinned) foreach (var other in results.Where(w => w != window && !w.IsPinned).ToArray()) other.Close(); };
            var operation = CancellationTokenSource.CreateLinkedTokenSource(result.ClosedToken); recognition = operation; recognizingWindow = result;
            _ = RecognizeCurrent();
            async Task RecognizeCurrent() {
                try { await RecognizeWindow(result, model, pixels, bitmap.PixelWidth, bitmap.PixelHeight, selector.Surface.PixelScale, read(), operation.Token); }
                finally { if (ReferenceEquals(recognition, operation)) { recognition = null; recognizingWindow = null; } operation.Dispose(); }
            }
        }
        catch (Exception exception) { CancelSelection(); error($"无法生成识别图片。（0x{exception.HResult:X8}）"); }
    }
    public void CancelNetwork() { foreach (var window in results) window.CancelTranslation(true); }
    internal static async Task RecognizeWindow(TranslationWindow window, TranslationModel model, byte[] pixels, int width, int height, double scale, TranslationPreferences preferences, CancellationToken token)
    {
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var slow = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        slow.Tick += (_, _) => { slow.Stop(); model.MarkSlowRecognition(); }; slow.Start();
        try {
            var result = await OcrWorker.Recognize(pixels, width, height, preferences, token, scale); pixels = [];
            token.ThrowIfCancellationRequested(); if (window.IsClosed) return;
            if (string.IsNullOrWhiteSpace(result.Text)) { model.RecognitionFailed("未识别到文字"); await Task.Delay(1500, token); if (!window.IsClosed) window.Close(); }
            else model.Recognized(result, watch.Elapsed);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!window.IsClosed && !token.IsCancellationRequested) model.RecognitionFailed("识别失败：" + error.Message); }
        finally { slow.Stop(); }
    }
    public void Dispose()
    {
        disposed = true; recognition?.Cancel(); CancelSelection(); foreach (var window in results.ToArray()) window.Close(); results.Clear();
    }
}
