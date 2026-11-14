#if DEBUG
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velos.Core.LongCapture;
using Velos.Core.Settings;
using Velos.LongCapture;
using Velos.Windows.Capture;
using PixelRect = System.Drawing.Rectangle;

namespace Velos;

public partial class App
{
    private async Task VerifyNativeAutoScroll(string profile, Action<bool, string> check)
    {
        var monitor = Desktop.Displays().First(); var scale = 1d;
        var fixture = new Window { Title = "Velos 自动滚动合成自测", WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterScreen, Width = 600, Height = 390, Background = Brushes.White, Topmost = true };
        var hwnd = new WindowInteropHelper(fixture).EnsureHandle(); HwndSource.FromHwnd(hwnd)!.CompositionTarget!.RenderMode = RenderMode.SoftwareOnly;
        fixture.Show(); scale = VisualTreeHelper.GetDpi(fixture).DpiScaleX;
        var bounds = new PixelRect(monitor.WorkArea.X + 80, monitor.WorkArea.Y + 80, 600, 390);
        Desktop.Position(hwnd, bounds);
        var pixels = ScrollTestFrame(bounds.Width, 2200, 0, ScrollAxis.Vertical);
        var image = BitmapSource.Create(pixels.Width, pixels.Height, 96, 96, PixelFormats.Bgr32, null, pixels.Pixels, pixels.Stride); image.Freeze();
        var scroll = new ScrollViewer { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            Content = new Image { Source = image, Width = bounds.Width / scale, Height = pixels.Height / scale, Stretch = Stretch.Fill } };
        scroll.PreviewMouseWheel += (_, e) => { scroll.ScrollToVerticalOffset(scroll.VerticalOffset - e.Delta * 48d / 120); e.Handled = true; };
        var begin = new Button { Content = "点击这里开始原生自动滚动自测", Padding = new Thickness(18), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        fixture.Content = new Grid { Children = { scroll, begin } }; fixture.UpdateLayout(); await SettleUI();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var errors = new List<string>();
        using var session = new LongCaptureSession(new Display(monitor.Handle, bounds, monitor.WorkArea), bounds, scale, new ScreenshotPreferences(), (_, _, _) => { }, errors.Add, () => { });
        session.DebugStart();
        begin.Click += async (_, _) => {
            try {
                begin.Visibility = Visibility.Collapsed; await SettleUI();
                session.DebugCaptureWindow(hwnd);
                await WaitFor(() => session.DebugLength > 0, "采集不含测试启动按钮的稳定首帧");
                session.DebugToggleAuto(); started.TrySetResult();
            } catch (Exception error) { started.TrySetException(error); }
        };
        try
        {
            await started.Task.WaitAsync(TimeSpan.FromMinutes(3));
            await WaitFor(() => scroll.VerticalOffset > 30, "真实 SendInput 滚轮进入合成页面");
            check(session.DebugAutoState == AutoScroll.Status.Running, "原生自动滚动已启动，未监听手动滚轮");
            var pointer = Desktop.Pointer();
            var deadline = DateTime.UtcNow.AddSeconds(35);
            while (!session.DebugAutoStopped)
            { if (DateTime.UtcNow > deadline) throw new TimeoutException("等待自动滚动到底"); await Task.Delay(50); }
            check(session.DebugAutoReason == AutoScroll.Reason.ReachedEnd && scroll.VerticalOffset >= scroll.ScrollableHeight - 1,
                "真实高精度滚轮使页面匀速到底，停留 1.2 秒后自动停止");
            check(Desktop.Pointer() == pointer, "自动滚动全程没有改变指针坐标");
            File.WriteAllText(Path.Combine(profile, "原生自动滚动诊断.txt"), $"DPI={scale}; 窗口={fixture.ActualWidth}×{fixture.ActualHeight}; 视口={scroll.ViewportWidth}×{scroll.ViewportHeight}; 内容={scroll.ExtentWidth}×{scroll.ExtentHeight}; 末端偏移={scroll.VerticalOffset}; 源高={pixels.Height}; 拼接={session.DebugLength}");
            check(session.DebugLength >= pixels.Height - 3 && session.DebugLength <= pixels.Height + 3, $"WGC 逐帧拼接保留整页原生高度（{session.DebugLength}）");
            check(errors.Count == 0, "自动滚动合成流程无异常");
            WriteLongComposite(new Display(monitor.Handle, bounds, monitor.WorkArea), SyntheticImage(bounds.Width, bounds.Height), session, Path.Combine(profile, "原生自动滚动.png"));
            File.WriteAllText(Path.Combine(profile, "原生自动滚动通过.txt"), "SendInput → 合成滚动页面 → WGC 窗口流 → 2.2 拼接器 → 到底停止。未采集真实屏幕、音频或其他应用。");
        }
        finally { session.Dispose(); fixture.Close(); }
    }
}
#endif
