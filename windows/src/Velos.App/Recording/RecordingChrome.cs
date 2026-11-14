using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Velos.Core.Recording;
using Velos.LongCapture;
using Velos.Screenshot;
using Velos.UI;
using Velos.Windows.Capture;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.Recording;

internal sealed class RecordingFrameWindow : Window
{
    private readonly FrameDrawing frame;
    public bool Excluded { get; private set; }
    public RecordingFrameWindow(Display display, PixelRect area, double scale)
    {
        Title = "Velos 录屏红框"; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent; ShowInTaskbar = false; ShowActivated = false; Topmost = true;
        frame = new FrameDrawing(display.Bounds, area, scale);
        Content = new Grid { Background = Brushes.Transparent, Children = { frame } };
        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        Desktop.MakeClickThrough(hwnd); Desktop.Position(hwnd, display.Bounds);
        Show(); Desktop.Position(hwnd, display.Bounds);
        Excluded = Desktop.ExcludeFromCapture(hwnd, true);
    }
    public void SetPaused(bool paused) { frame.Paused = paused; frame.InvalidateVisual(); }
    private sealed class FrameDrawing(PixelRect screen, PixelRect area, double scale) : FrameworkElement
    {
        public bool Paused { get; set; }
        protected override void OnRender(DrawingContext drawing)
        {
            var rect = new Rect((area.X - screen.X) / scale, (area.Y - screen.Y) / scale, area.Width / scale, area.Height / scale);
            if (area == screen) rect.Inflate(-1.5, -1.5);
            else rect.Inflate(2, 2);
            var pen = new Pen(Paused ? WarmTheme.Apricot : WarmTheme.Coral, 2);
            if (Paused) pen.DashStyle = new DashStyle([7, 5], 0);
            drawing.DrawRectangle(null, pen, rect);
        }
    }
}

internal sealed class RecordingCountdownWindow : Window
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly TextBlock number;
    private readonly TaskCompletionSource<bool> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int remaining = 3;
    public Task<bool> Completion => completion.Task;
    public RecordingCountdownWindow(PixelRect area, double scale)
    {
        Title = "Velos 录屏倒计时"; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        Background = CaptureChrome.Paper; ShowInTaskbar = false; Topmost = true;
        number = new TextBlock { Text = "3", FontFamily = WarmTheme.Text, FontSize = 64, FontWeight = FontWeights.Bold,
            Foreground = CaptureChrome.Ink, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 11, 0, 5) };
        Content = new Border { Background = CaptureChrome.Paper, CornerRadius = new CornerRadius(34), BorderBrush = CaptureChrome.Line,
            BorderThickness = new Thickness(1), Child = new StackPanel { Children = { number, new TextBlock
            { Text = "Esc 取消 · Enter 立即开始", FontFamily = WarmTheme.Text, FontSize = 11, Foreground = CaptureChrome.Ink,
                Opacity = 0.55, HorizontalAlignment = HorizontalAlignment.Center } } } };
        var bounds = new PixelRect((int)Math.Round(area.X + (area.Width - 190 * scale) / 2),
            (int)Math.Round(area.Y + (area.Height - 150 * scale) / 2), (int)Math.Round(190 * scale), (int)Math.Round(150 * scale));
        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        Desktop.Position(hwnd, bounds); Show(); Desktop.Position(hwnd, bounds);
        Desktop.RoundWindow(hwnd, bounds.Width, bounds.Height, (int)(34 * scale));
        Desktop.ExcludeFromCapture(hwnd, true);
        PreviewKeyDown += (_, e) => { if (Keyboard.Modifiers != ModifierKeys.None || e.IsRepeat) return; if (e.Key == Key.Escape) Finish(false); else if (e.Key is Key.Enter or Key.Space) Finish(true); else return; e.Handled = true; };
        MouseLeftButtonDown += (_, _) => Finish(false);
        Closed += (_, _) => { timer.Stop(); completion.TrySetResult(false); };
        timer.Tick += (_, _) =>
        {
            if (--remaining == 0) { Finish(true); return; }
            number.Text = remaining.ToString();
            WarmMotion.Fade(number, 1, 250, .25);
        };
        WarmMotion.Fade(number, 1, 250, .25); timer.Start();
        Activate();
    }
    public void Finish(bool accepted) { timer.Stop(); if (completion.TrySetResult(accepted)) Close(); }
}

internal sealed class RecordingControlBar : IDisposable
{
    private readonly LongFloatingWindow window;
    private readonly TextBlock time;
    private readonly TextBlock dot;
    private readonly TextBlock reason;
    private readonly Border panel;
    private readonly PixelRect work;
    private readonly double scale;
    private readonly Button pause;
    private readonly Button microphone;
    private readonly Func<TimeSpan> elapsed;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    public Window Window => window;
    public RecordingControlBar(Display display, PixelRect area, double scale, bool withMicrophone, Func<TimeSpan> elapsed,
        Action togglePause, Action toggleMicrophone, Action stop)
    {
        this.elapsed = elapsed; this.scale = scale; work = display.WorkArea;
        time = new TextBlock { Text = "00:00", FontFamily = WarmTheme.Text, FontSize = 14, FontWeight = FontWeights.SemiBold,
            Foreground = CaptureChrome.Ink, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(5, 0, 10, 0) };
        System.Windows.Documents.Typography.SetNumeralAlignment(time, FontNumeralAlignment.Tabular);
        dot = new TextBlock { Text = "●", FontSize = 10, Foreground = WarmTheme.Coral, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 2, 0) };
        reason = new TextBlock { FontFamily = WarmTheme.Text, FontSize = 12, Foreground = CaptureChrome.Ink, Opacity = .55,
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0), MaxWidth = Math.Max(80, Math.Min(260, work.Width / scale - 300)),
            TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        pause = CaptureChrome.IconButton(ActionIcon.Pause, "暂停录制", togglePause);
        microphone = CaptureChrome.IconButton(ActionIcon.Microphone, "麦克风静音", toggleMicrophone);
        microphone.Visibility = withMicrophone ? Visibility.Visible : Visibility.Collapsed;
        var stopButton = CaptureChrome.IconButton("\ue71a", "停止录制", stop, "停止");
        stopButton.Background = WarmTheme.Coral;
        var separator = new Border { Width = 1.5, Height = 16, CornerRadius = new CornerRadius(.75), Background = WarmTheme.Floating.Divider, Margin = new Thickness(5, 0, 6.5, 0) };
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Children = { dot, time, reason, separator, pause, microphone, stopButton } };
        panel = CaptureChrome.Pill(controls);
        window = new LongFloatingWindow("Velos 录屏控制条", panel);
        controls.MouseLeftButtonDown += (_, e) =>
        {
            if (!Interaction.IsControl(e.OriginalSource))
            {
                try { window.DragMove(); } catch (InvalidOperationException) { }
            }
        };
        for (var pass = 0; pass < 2; pass++)
        {
            panel.Measure(new Size(work.Width / scale - 16, double.PositiveInfinity));
            var width = (int)Math.Ceiling((panel.DesiredSize.Width + 1) * scale);
            var height = (int)Math.Ceiling(panel.DesiredSize.Height * scale);
            var x = Math.Clamp(area.X + (area.Width - width) / 2, work.Left + 8, Math.Max(work.Left + 8, work.Right - width - 8));
            var y = area.Bottom + (int)(12 * scale);
            if (y + height > work.Bottom - 8) y = area.Top - (int)(12 * scale) - height;
            if (y < work.Top + 8 || area == display.Bounds) y = work.Bottom - height - (int)(28 * scale);
            if (!window.Place(new PixelRect(x, y, width, height), (int)(22 * scale)))
                throw new InvalidOperationException("当前桌面无法从录制排除控制条。");
            window.UpdateLayout();
        }
        timer.Tick += (_, _) => time.Text = RecordingGeometry.Clock(elapsed());
        timer.Start();
    }
    public void Refresh(bool paused, bool muted, string? explanation = null)
    {
        Interaction.SetAction(pause, paused ? ActionIcon.Play : ActionIcon.Pause, paused ? "继续录制" : "暂停录制");
        Interaction.SetAction(microphone, muted ? ActionIcon.MicrophoneOff : ActionIcon.Microphone, muted ? "取消麦克风静音" : "麦克风静音");
        microphone.Foreground = muted ? WarmTheme.Coral : CaptureChrome.Ink;
        dot.Foreground = paused ? WarmTheme.Apricot : WarmTheme.Coral;
        time.Foreground = paused ? WarmTheme.Apricot : CaptureChrome.Ink;
        time.Text = RecordingGeometry.Clock(elapsed());
        reason.Text = explanation ?? ""; reason.Visibility = string.IsNullOrEmpty(explanation) ? Visibility.Collapsed : Visibility.Visible;
        if (paused) timer.Stop(); else timer.Start();
        var current = Desktop.WindowRectangle(new WindowInteropHelper(window).Handle);
        panel.Measure(new Size(Math.Max(1, work.Width / scale - 16), double.PositiveInfinity));
        var width = Math.Min(work.Width - 16, (int)Math.Ceiling((panel.DesiredSize.Width + 1) * scale));
        var height = (int)Math.Ceiling(panel.DesiredSize.Height * scale);
        var x = Math.Clamp(current.X, work.Left + 8, Math.Max(work.Left + 8, work.Right - width - 8));
        var y = Math.Clamp(current.Y, work.Top + 8, Math.Max(work.Top + 8, work.Bottom - height - 8));
        window.Place(new PixelRect(x, y, width, height), (int)(22 * scale));
    }
    public void Dispose() { timer.Stop(); window.Close(); }
#if DEBUG
    internal string DebugPauseName => System.Windows.Automation.AutomationProperties.GetName(pause);
    internal ActionIcon? DebugMicrophoneIcon => (microphone.Content as ActionIconView)?.Kind;
    internal bool DebugButtonIsGuarded => Interaction.IsControl((DependencyObject)pause.Content);
    internal void DebugPauseClick() => pause.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
#endif
}
