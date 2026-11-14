using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Velos.Core.LongCapture;
using Velos.Core.Settings;
using Velos.Screenshot;
using Velos.UI;
using Velos.Windows.Capture;
using DipRect = System.Drawing.RectangleF;
using DipSize = System.Drawing.SizeF;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.LongCapture;

internal sealed class LongCaptureSession : IDisposable
{
    private const int EscapeId = 1;
    private readonly Display display;
    private readonly PixelRect area;
    private readonly double scale;
    private readonly Action<BitmapSource, ScrollAxis, ShotAction> completed;
    private readonly Action<string> error;
    private readonly Action closed;
    private readonly Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
    private readonly DispatcherTimer autoTimer = new() { Interval = TimeSpan.FromSeconds(1d / 60) };
    private readonly LongCaptureEngine engine;
    private readonly LongCaptureOverlay overlay;
    private readonly LongFloatingWindow toolbar;
    private readonly LongFloatingWindow preview;
    private readonly LongPreviewCanvas previewCanvas = new();
    private readonly Button autoButton;
    private readonly AutoScroll auto;
    private WheelInput? wheelInput;
    private readonly Button[] output;
    private readonly Button cancel;
    private readonly TextBlock status;
    private HwndSource? keyWindow;
    private int displayedLength;
    private bool limited, captureFailed;
    private volatile bool ending;
    private bool disposed;

    public LongCaptureSession(Display display, PixelRect area, double scale, ScreenshotPreferences options,
        Action<BitmapSource, ScrollAxis, ShotAction> completed, Action<string> error, Action closed)
    {
        this.display = display;
        this.area = area;
        this.scale = scale;
        this.completed = completed;
        this.error = error;
        this.closed = closed;
        engine = new LongCaptureEngine(scale);
        engine.OnUpdate = update => dispatcher.BeginInvoke(() => Handle(update), DispatcherPriority.Background);
        engine.OnError = failure => dispatcher.BeginInvoke(() => CaptureFailed(failure));
        overlay = new LongCaptureOverlay(display.Bounds, area, scale);
        overlay.DpiChanged += (_, _) => { if (overlay.IsLoaded && overlay.IsVisible) dispatcher.BeginInvoke(Dispose); };
        preview = new LongFloatingWindow("Velos 长截图预览", new Border
        {
            Background = CaptureChrome.Paper, BorderBrush = CaptureChrome.Line, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12), Padding = new Thickness(6), Child = previewCanvas,
            IsHitTestVisible = false
        }, clickThrough: true);
        auto = new AutoScroll(new DipRect((float)(area.X / scale), (float)(area.Y / scale), (float)(area.Width / scale), (float)(area.Height / scale)));
        autoButton = CaptureChrome.IconButton("\ue768", "自动滚动：鼠标放在选区内，再点一次停止", ToggleAuto, "自动滚动");
        autoButton.MinWidth = 104; autoButton.Margin = new Thickness(0, 0, 10, 0); autoButton.Background = WarmTheme.Coral; autoButton.Foreground = Brushes.White;
        status = new TextBlock
        {
            FontFamily = WarmTheme.Text, FontSize = 12, FontWeight = FontWeights.Medium, Foreground = CaptureChrome.Ink,
            MinWidth = 118, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center
        };
        Typography.SetNumeralAlignment(status, FontNumeralAlignment.Tabular);
        cancel = CaptureChrome.IconButton("\ue711", "取消长截图（Esc）", Dispose);
        output =
        [
            CaptureChrome.IconButton("\ue70f", "编辑", () => Finish(ShotAction.Edit)),
            CaptureChrome.PinButton(() => Finish(ShotAction.Pin)),
            CaptureChrome.SaveButton(() => Finish(ShotAction.Save)),
            CaptureChrome.IconButton("\ue73e", "完成", () => Finish(ShotAction.Done), "完成")
        ];
        var controls = new WrapPanel { Children = { autoButton, status, cancel } };
        foreach (var button in output) controls.Children.Add(button);
        foreach (var button in output.Append(cancel).Append(autoButton)) button.Focusable = false;
        toolbar = new LongFloatingWindow("Velos 长截图控制条", CaptureChrome.Pill(controls));
        autoTimer.Tick += (_, _) => AutoTick();
        auto.Changed += UpdateAuto;
        UpdateStatus(0, ScrollAxis.Vertical, false);
    }

    public void Start()
    {
        if (ending || disposed) return;
        ShowWindows(ScrollAxis.Vertical);
        if (ending) return;
        InstallEscape(); Desktop.FlushComposition(); engine.Start(display, area);
    }

    private void CaptureFailed(Exception failure)
    {
        if (ending) return;
        captureFailed = true; StopAuto(); autoButton.IsEnabled = false;
        var message = (displayedLength > 0 ? "截取中断：" : "无法开始长截图：") +
            (failure is InvalidOperationException or NotSupportedException ? failure.Message : $"（0x{failure.HResult:X8}）");
        overlay.SetHint(message); status.ToolTip = message;
    }
    private void Handle(LongCaptureEngine.Update update)
    {
        if (ending) return;
#if DEBUG
        lastDebugEvent = update.Event;
#endif
        limited = update.Limited;
        if (update.Preview is not null) previewCanvas.Update(update.Preview, ScrollAxis.Vertical);
        if (update.Motion is { } shift) auto.NoteMotion(shift, PointerDip(), Now);
        if (update.Event == ScrollStitcher.EventKind.LimitReached && auto.Active) StopAuto(AutoScroll.Reason.Limit);
        if (update.Event == ScrollStitcher.EventKind.Appended && !auto.Active && !captureFailed) overlay.SetHint(null);
        if (displayedLength != update.Length || limited) UpdateStatus(update.Length, ScrollAxis.Vertical, limited);
    }

    private void UpdateStatus(int length, ScrollAxis axis, bool limited)
    {
        displayedLength = length;
        status.Text = length == 0 ? "等待滚动…" : $"已拼接 {length} 像素";
        if (!captureFailed) status.ToolTip = limited ? "已达到 20,000 像素上限。" : "在选区内向下滚动";
        foreach (var button in output) button.IsEnabled = length > 0;
        autoButton.IsEnabled = !limited && !captureFailed;
        if (toolbar.IsVisible && !ending) PlaceWindows(axis);
    }

    private void ShowWindows(ScrollAxis axis)
    {
        overlay.ShowOverlay();
        PlaceWindows(axis);
        overlay.SetHint("请缓慢向下滚动页面，或点「自动滚动」");
    }

    private void PlaceWindows(ScrollAxis axis)
    {
        var monitor = display.Bounds;
        DipRect ToDip(PixelRect rect) => new((float)((rect.X - monitor.X) / scale), (float)((rect.Y - monitor.Y) / scale),
            (float)(rect.Width / scale), (float)(rect.Height / scale));
        PixelRect ToPixels(DipRect rect) => new(monitor.X + (int)Math.Round(rect.X * scale), monitor.Y + (int)Math.Round(rect.Y * scale),
            (int)Math.Round(rect.Width * scale), (int)Math.Round(rect.Height * scale));

        var region = ToDip(area);
        var work = ToDip(display.WorkArea);
        _ = new WindowInteropHelper(toolbar).EnsureHandle();
        var barContent = (FrameworkElement)toolbar.Content;
        barContent.InvalidateMeasure();
        barContent.MaxWidth = Math.Max(1, work.Width - 8);
        barContent.Measure(new Size(barContent.MaxWidth, double.PositiveInfinity));
        var barBounds = default(DipRect);
        // Show 后 WPF 才完整应用按钮模板，再测一次，避免首帧按最小按钮宽度排出两行。
        for (var pass = 0; pass < 2; pass++)
        {
            barContent.InvalidateMeasure();
            barContent.Measure(new Size(barContent.MaxWidth, double.PositiveInfinity));
            barBounds = LongCaptureLayout.Bar(region,
                new DipSize((float)Math.Ceiling(barContent.DesiredSize.Width + 1), (float)Math.Ceiling(barContent.DesiredSize.Height)), work);
            if (!toolbar.Place(ToPixels(barBounds), (int)Math.Round(22 * scale)) && barBounds.IntersectsWith(region))
                throw new InvalidOperationException("当前桌面无法从采集排除选区内的控制条。请缩小选区，给控制条留出位置。");
            toolbar.UpdateLayout();
        }

        if (LongCaptureLayout.Preview(region, barBounds, work, axis) is { } previewBounds)
        {
            preview.Place(ToPixels(previewBounds), (int)Math.Round(12 * scale));
            preview.UpdateLayout();
            engine.SetPreviewSize(Math.Max(1, (int)Math.Round(previewCanvas.ActualWidth * scale)), Math.Max(1, (int)Math.Round(previewCanvas.ActualHeight * scale)));
        }
        else
        {
            preview.Hide();
            engine.SetPreviewSize(0, 0);
        }
    }

    private void InstallEscape()
    {
        var hwnd = new WindowInteropHelper(toolbar).Handle;
        if (!Desktop.TryRegisterEscape(hwnd, EscapeId))
            return;
        keyWindow = HwndSource.FromHwnd(hwnd);
        keyWindow?.AddHook(HandleEscape);
    }

    private nint HandleEscape(nint hwnd, int message, nint wParam, nint lParam, ref bool handled)
    {
        if (message == 0x0312 && wParam == EscapeId)
        {
            handled = true;
            dispatcher.BeginInvoke(Dispose);
        }
        return 0;
    }

    private static double Now => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency;
    private System.Drawing.PointF PointerDip()
    { var point = Desktop.Pointer(); return new((float)(point.X / scale), (float)(point.Y / scale)); }

    private void ToggleAuto()
    {
        if (ending || captureFailed || limited) return;
        if (auto.Active) { StopAuto(); return; }
        wheelInput = new WheelInput(); auto.Start(PointerDip(), Now); autoTimer.Start(); AutoTick();
    }

    private void StopAuto(AutoScroll.Reason reason = AutoScroll.Reason.User)
    { autoTimer.Stop(); wheelInput = null; auto.Stop(reason); }

    private void AutoTick()
    {
        if (ending) { StopAuto(); return; }
        var pointer = Desktop.Pointer(); var dip = new System.Drawing.PointF((float)(pointer.X / scale), (float)(pointer.Y / scale));
        var step = auto.Tick(dip, Now);
        if (!auto.Active) { autoTimer.Stop(); wheelInput = null; return; }
        if (step != 0 && wheelInput is not null && !wheelInput.Scroll(step, pointer))
        {
            StopAuto(AutoScroll.Reason.Unavailable);
            status.ToolTip = "无法向当前窗口发送滚轮，可能是管理员权限窗口。请手动滚动。";
        }
    }

    private void UpdateAuto()
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        content.Children.Add(new ActionIconView(auto.Active ? ActionIcon.Stop : ActionIcon.Play, 14));
        content.Children.Add(new TextBlock { Text = auto.Active ? "停止" : "自动滚动", Margin = new Thickness(5, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
        autoButton.Content = content;
        autoButton.Background = auto.Active ? WarmTheme.Brush(178, 70, 58) : WarmTheme.Coral;
        autoButton.ToolTip = auto.State == AutoScroll.Status.Paused ? "鼠标移回选区后继续自动滚动" : auto.Active ? "停止自动滚动" : auto.StopReason switch
        { AutoScroll.Reason.ReachedEnd => "已滚动到底", AutoScroll.Reason.Limit => "已达到长度上限", AutoScroll.Reason.Unavailable => "无法发送滚轮，请手动滚动", _ => "自动滚动：鼠标放在选区内，再点一次停止" };
        if (toolbar.IsVisible && !ending) PlaceWindows(ScrollAxis.Vertical);
        if (!ending) overlay.SetHint(auto.State switch
        {
            AutoScroll.Status.Running => null,
            AutoScroll.Status.Paused => "把鼠标移回选区里，自动滚动会接着滚",
            _ => auto.StopReason switch
            {
                AutoScroll.Reason.ReachedEnd => "已经滚到底了",
                AutoScroll.Reason.Limit => "长图已到长度上限",
                AutoScroll.Reason.Unavailable => "无法向当前窗口发送滚轮，请改用手动滚动。管理员窗口需要相同权限。",
                _ => null
            }
        });
    }

    private async void Finish(ShotAction action)
    {
        if (ending || displayedLength == 0) return;
        ending = true; SetBusy(); StopAuto();
        try
        {
            await engine.StopAsync();
            var image = await engine.MakeImageAsync();
            if (disposed) return;
            await CloseAsync();
            if (image is not null) completed(image, ScrollAxis.Vertical, action);
        }
        catch (Exception failure) { await CloseAsync(); Report("无法生成长截图", failure); }
    }
    private void SetBusy()
    {
        foreach (var button in output.Append(autoButton).Append(cancel)) button.IsEnabled = false;
        status.Text = "正在生成…";
    }
    private void Report(string title, Exception failure) =>
        error($"{title}。{(failure is InvalidOperationException or NotSupportedException ? failure.Message : $"（0x{failure.HResult:X8}）")}");

    // 取消也先停采集，再关界面，覆盖启动期间立即取消的情况。
    public async void Dispose()
    {
        if (ending || disposed) return;
        ending = true; StopAuto();
        foreach (var button in output.Append(autoButton).Append(cancel)) button.IsEnabled = false;
        try { await engine.StopAsync(); }
        finally { await CloseAsync(); }
    }
    private async Task CloseAsync()
    {
        if (disposed) return;
        disposed = true; ending = true; StopAuto();
        engine.OnUpdate = null; engine.OnError = null;
        previewCanvas.Update(null, ScrollAxis.Vertical);
        if (keyWindow is { } source)
        {
            Desktop.UnregisterKey(source.Handle, EscapeId); source.RemoveHook(HandleEscape); keyWindow = null;
        }
        preview.Close(); toolbar.Close(); overlay.Close();
        try { await engine.DisposeAsync(); }
        finally { closed(); }
    }

#if DEBUG
    private ScrollStitcher.EventKind lastDebugEvent;
    public ScrollStitcher.EventKind DebugLastEvent => lastDebugEvent;
    public bool DebugHintVisible => overlay.DebugHintVisible;
    public void DebugStart() => ShowWindows(ScrollAxis.Vertical);
    public void DebugFeed(ScrollFrame frame) => engine.DebugFeed(frame);
    public bool DebugAutoStopped => !autoTimer.IsEnabled && !auto.Active;
    public void DebugToggleAuto() => ToggleAuto();
    public AutoScroll.Status DebugAutoState => auto.State;
    public AutoScroll.Reason DebugAutoReason => auto.StopReason;
    public void DebugCaptureWindow(nint window) => engine.DebugCaptureWindow(window, new PixelRect(0, 0, area.Width, area.Height));
    public void DebugFinish(ShotAction action) => Finish(action);
    public Window DebugOverlay => overlay;
    public Window DebugToolbar => toolbar;
    public Window DebugPreview => preview;
    public int DebugLength => displayedLength;
    public bool DebugControlsFit => output.Append(cancel).Append(autoButton).All(button =>
    {
        var origin = button.TranslatePoint(new Point(), toolbar);
        return origin.X >= 0 && origin.Y >= 0 && origin.X + button.ActualWidth <= toolbar.ActualWidth + 1 &&
            origin.Y + button.ActualHeight <= toolbar.ActualHeight + 1;
    });
#endif
}
