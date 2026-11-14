using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.VisualBasic.FileIO;
using Velos.Core.Settings;
using Velos.Windows.Capture;
using Velos.Windows.Recording;
using Velos.Screenshot;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.Recording;

internal sealed class RecordingController
{
    private readonly Func<RecordingPreferences> read;
    private readonly Action<RecordingPreferences> update;
    private readonly Action<string> notify;
    private readonly List<RecordingSelectionWindow> selectors = [];
    private readonly SelectionGroup selectionGroup = new();
    private CancellationTokenSource? selectionDelay;
    private bool pendingFullScreen;
    private readonly HashSet<Window> results = [];
    private ScreenRecorder? recorder;
    private RecordingCountdownWindow? countdown;
    private RecordingFrameWindow? frame;
    private RecordingControlBar? bar;
    private ClickHighlighter? clicks;
    private bool starting, stopping, cancelStart;
    private string? temporary;
    private string? finalPath;
    private Display? recordedDisplay;
    private double recordedScale;
    private Task? stopTask;
    private bool closing;
    private SelectionFocus? focus;
    private readonly nint messageWindow;
    private RecordingSystemEvents? systemEvents;
    private string? pauseReason;
    private CancellationTokenSource? startCancellation;
    private TaskCompletionSource? startFinished;
    public bool IsSelecting => selectionDelay is not null || selectors.Count > 0 || countdown is not null || starting;
    public bool IsRecording => recorder is not null;
    public bool IsPaused => recorder?.IsPaused == true;
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "ScreenRecordings");

    public RecordingController(Func<RecordingPreferences> read, Action<RecordingPreferences> update, Action<string> notify, nint messageWindow = 0)
    { this.read = read; this.update = update; this.notify = notify; this.messageWindow = messageWindow; }

    public async void Toggle(bool fromTray = false)
    {
        if (recorder is not null) { _ = Stop(); return; }
        if (countdown is not null) { countdown.Finish(false); return; }
        if (starting) { cancelStart = true; startCancellation?.Cancel(); return; }
        if (stopping || closing) return;
        if (selectionDelay is not null) { pendingFullScreen = !pendingFullScreen; return; }
        if (selectors.Count > 0)
        {
            selectionGroup.Toggle(); return;
        }
        using var operation = new CancellationTokenSource(); selectionDelay = operation; pendingFullScreen = false;
        try
        {
            if (fromTray) await Task.Delay(220, operation.Token);
            operation.Token.ThrowIfCancellationRequested();
            focus = new SelectionFocus(session => Application.Current.Dispatcher.BeginInvoke(() => { if (ReferenceEquals(focus, session)) CancelSelection(); }));
            var windows = Desktop.WindowBounds(new HashSet<nint>());
            foreach (var display in Desktop.Displays())
            {
                var selector = new RecordingSelectionWindow(display, windows, read, Update, Begin, CancelSelection);
                selectors.Add(selector); selector.ShowOnDisplay();
                selectionGroup.Add(selector, display, selector.Surface, selector.SetSuppressed);
                selector.Closed += (_, _) => { if (selectors.Remove(selector)) CancelSelection(); };
            }
            var pointer = Desktop.Pointer();
            var active = selectors.FirstOrDefault(s => s.Display.Bounds.Contains(pointer)) ?? selectors[0];
            active.Surface.SetFullScreen(pendingFullScreen); active.Activate();
        }
        catch (OperationCanceledException) when (operation.IsCancellationRequested) { }
        catch (Exception error) { CancelSelection(); notify($"无法打开录屏选区。（0x{error.HResult:X8}）"); }
        finally { if (selectionDelay == operation) selectionDelay = null; }
    }
    private void Update(RecordingPreferences options) { update(options); foreach (var selector in selectors) selector.RefreshOptions(); }
    public void CancelSelection()
    {
        var previousFocus = focus; focus = null; previousFocus?.Dispose();
        if (starting) { cancelStart = true; startCancellation?.Cancel(); }
        selectionDelay?.Cancel(); selectionGroup.Clear();
        var open = selectors.ToArray(); selectors.Clear();
        foreach (var selector in open) selector.Close();
        countdown?.Finish(false); countdown = null;
    }
    private async void Begin(RecordingSelectionWindow selector)
    {
        if (starting || selector.Surface.Region is not { } local || local.Width < 2 || local.Height < 2) return;
        starting = true;
        var display = selector.Display;
        var scale = VisualTreeHelper.GetDpi(selector).DpiScaleX;
        var area = new PixelRect(local.X + display.Bounds.X, local.Y + display.Bounds.Y, local.Width & ~1, local.Height & ~1);
        CancelSelection();
        cancelStart = false;
        using var operation = new CancellationTokenSource(); startCancellation = operation;
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); startFinished = finished;
        try
        {
            var options = read();
            if (messageWindow != 0)
            {
                systemEvents = new RecordingSystemEvents(messageWindow, HandleSystemEvent);
                if (!systemEvents.SessionRegistered || !systemEvents.DisplayRegistered) notify("部分系统事件监听不可用，请在锁屏或熄屏前手动暂停录屏。");
            }
            if (options.Countdown)
            {
                countdown = new RecordingCountdownWindow(area, scale);
                var accepted = await countdown.Completion; countdown = null;
                if (!accepted || closing) return;
            }
            if (cancelStart || closing) return;
            var directory = string.IsNullOrWhiteSpace(options.Directory) ? DefaultDirectory : options.Directory;
            Directory.CreateDirectory(directory);
            finalPath = Unique(directory, $"录屏 {DateTime.Now:yyyy-MM-dd HH.mm.ss}", ".mp4");
            temporary = Path.Combine(directory, $".Velos-{Guid.NewGuid():N}.mp4.partial");
            recordedDisplay = display; recordedScale = scale;
            frame = new RecordingFrameWindow(display, area, scale);
            if (!frame.Excluded) { frame.Close(); frame = null; notify("当前桌面无法排除录屏红框，本次隐藏红框。"); }
            bar = new RecordingControlBar(display, area, scale, options.Microphone, () => recorder?.Elapsed ?? TimeSpan.Zero,
                TogglePause, ToggleMicrophone, () => _ = Stop());
            Desktop.SetRecordingActive(true);
            recorder = await ScreenRecorder.Start(temporary, display, area, options,
                text => Application.Current.Dispatcher.BeginInvoke(() => notify(text)),
                error => Application.Current.Dispatcher.BeginInvoke(() => { notify($"屏幕采集已中断，正在保存。（0x{error.HResult:X8}）"); _ = Stop(); }), operation.Token);
            if (cancelStart || closing) { await recorder.DisposeAsync(); recorder = null; ClearChrome(); RecyclePartial(); return; }
            if (options.HighlightClicks)
            {
                try { clicks = new ClickHighlighter(display, scale); }
                catch (System.ComponentModel.Win32Exception) { notify("鼠标点击高亮不可用，录屏继续。"); }
            }
            if (recorder.ActualCodec != options.Codec) notify("此电脑无法使用 HEVC 编码，本次已改用 H.264。");
        }
        catch (OperationCanceledException) when (operation.IsCancellationRequested)
        {
            if (recorder is not null) { await recorder.DisposeAsync(); recorder = null; }
            ClearChrome(); RecyclePartial();
        }
        catch (Exception error)
        {
            if (recorder is not null) { await recorder.DisposeAsync(); recorder = null; }
            ClearChrome(); RecyclePartial();
            notify($"无法开始录屏，请检查编码器、保存目录和屏幕采集权限。（0x{error.HResult:X8}）");
        }
        finally
        {
            starting = false; if (startCancellation == operation) startCancellation = null;
            if (recorder is null) { systemEvents?.Dispose(); systemEvents = null; }
            finished.TrySetResult();
        }
    }
    public void TogglePause()
    {
        recorder?.TogglePause();
        pauseReason = null;
        frame?.SetPaused(IsPaused); if (clicks is not null) clicks.Paused = IsPaused;
        bar?.Refresh(IsPaused, recorder?.MicrophoneMuted == true, pauseReason);
    }
    internal void HandleSystemMessage(int message, nint wParam, nint lParam) => systemEvents?.HandleMessage(message, wParam, lParam);
    private void HandleSystemEvent(RecordingSystemEvent reason)
    {
        if (stopping || closing) return;
        if (reason == RecordingSystemEvent.Suspend)
        {
            if (recorder is not null) _ = Stop();
            else { cancelStart = true; startCancellation?.Cancel(); countdown?.Finish(false); }
            return;
        }
        if (recorder is null)
        { if (starting) { cancelStart = true; startCancellation?.Cancel(); countdown?.Finish(false); } return; }
        if (recorder.IsPaused) return;
        pauseReason = reason switch
        {
            RecordingSystemEvent.DisplayOff => "屏幕熄灭时自动暂停了",
            RecordingSystemEvent.SessionLocked => "锁屏时自动暂停了",
            _ => "切换用户时自动暂停了"
        };
        recorder.TogglePause(); frame?.SetPaused(true); if (clicks is not null) clicks.Paused = true;
        bar?.Refresh(true, recorder.MicrophoneMuted, pauseReason);
    }
    private void ToggleMicrophone()
    {
        if (recorder is null) return;
        recorder.MicrophoneMuted = !recorder.MicrophoneMuted;
        bar?.Refresh(IsPaused, recorder.MicrophoneMuted, pauseReason);
    }
    public Task Stop() => stopping ? stopTask ?? Task.CompletedTask : stopTask = Finish();
    private async Task Finish()
    {
        if (recorder is null) { CancelSelection(); return; }
        stopping = true;
        systemEvents?.Dispose(); systemEvents = null;
        var active = recorder;
        try
        {
            await active.Stop();
            await active.DisposeAsync(); recorder = null;
            ClearChrome();
            if (temporary is null || finalPath is null) return;
            while (true)
            {
                try { File.Move(temporary, finalPath, false); break; }
                catch (IOException) when (File.Exists(finalPath)) { finalPath = Unique(Path.GetDirectoryName(finalPath)!, Path.GetFileNameWithoutExtension(finalPath), ".mp4"); }
            }
            temporary = null;
            if (!closing && read().Thumbnail && recordedDisplay is { } display)
                Track(new RecordingThumbnail(finalPath, display, recordedScale, read, notify, Preview, ClosePreview));
            else notify($"录屏已保存到：{finalPath}");
        }
        catch (Exception error)
        {
            try { await active.DisposeAsync(); } catch { }
            recorder = null; ClearChrome();
            notify($"录屏保存失败，未完成文件保留在 {temporary}，可在视频播放器中尝试恢复。（0x{error.HResult:X8}）");
        }
        finally { stopping = false; }
    }
    private void Preview(string path)
    {
        var fullPath = Path.GetFullPath(path);
        if (results.OfType<VideoPreviewWindow>().FirstOrDefault(window => string.Equals(window.FilePath, fullPath, StringComparison.OrdinalIgnoreCase)) is { } existing) { existing.Resume(); return; }
        var window = new VideoPreviewWindow(path, notify); Track(window); window.Show(); window.Activate();
    }
    private void ClosePreview(string path)
    { foreach (var window in results.OfType<VideoPreviewWindow>().Where(window => string.Equals(window.FilePath, Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase)).ToArray()) window.Close(); }
    public void ExportGif(string path, Display display, double scale)
    {
        if (closing) return;
        var thumbnail = new RecordingThumbnail(path, display, scale, read, notify, Preview, ClosePreview);
        Track(thumbnail); thumbnail.ExportGif();
    }
    private void Track(Window window) { results.Add(window); window.Closed += (_, _) => results.Remove(window); }
    private void ClearChrome() { systemEvents?.Dispose(); systemEvents = null; pauseReason = null; bar?.Dispose(); bar = null; frame?.Close(); frame = null; clicks?.Close(); clicks = null; Desktop.SetRecordingActive(false); }
    private void RecyclePartial()
    {
        if (temporary is not null && File.Exists(temporary))
            try { FileSystem.DeleteFile(temporary, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin); } catch { }
        temporary = null;
    }
    internal static string Unique(string directory, string name, string extension)
    {
        var path = Path.Combine(directory, name + extension);
        for (var i = 2; File.Exists(path); i++) path = Path.Combine(directory, $"{name} {i}{extension}");
        return path;
    }
    public async Task Close()
    {
        closing = true; CancelSelection();
        if (starting && startFinished is { } pending) await pending.Task;
        await Stop();
        var conversions = results.OfType<RecordingThumbnail>().Select(thumbnail => thumbnail.PendingConversion).ToArray();
        foreach (var result in results.ToArray()) result.Close();
        await Task.WhenAll(conversions);
    }
}
