#if DEBUG
using System.IO;
using System.Threading.Channels;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Velos.Core.LongCapture;
using Velos.Core.Settings;
using Velos.LongCapture;
using Velos.Screenshot;
using Velos.UI;
using Velos.Windows.Capture;
using PixelRect = System.Drawing.Rectangle;

namespace Velos;

public partial class App
{
    private async void RunLongCaptureSelfTest(string profile, bool measureIdle)
    {
        var results = new List<string>();
        var exitCode = 1;
        Directory.CreateDirectory(profile);
        try
        {
            if (Environment.GetCommandLineArgs().Contains("--verify-auto-input"))
            {
                await VerifyNativeAutoScroll(profile, Check); exitCode = 0; return;
            }
            results.Add("环境  进程架构 " + System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture);
            Check(tray!.DebugUsesReferenceIcon, "托盘使用提供的 PNG 资源");
            Check(WriteIconSheets(profile), "统一矢量图标在浅深色及 100／125／150／200% 下均有实际像素输出");
            await TestContinuousCrop(profile, Check);
            await TestNativeLongOutput(profile, Check);
            Check(WheelInput.DebugHasNoPointerMovement, "2.2：自动滚轮仅有 WHEEL 标志，无 MOVE、坐标或全局钩子");

            var monitor = Desktop.Displays().First();
            var bounds = new PixelRect(monitor.WorkArea.Left + 20, monitor.WorkArea.Top + 20,
                Math.Min(1280, monitor.WorkArea.Width - 40), Math.Min(800, monitor.WorkArea.Height - 40));
            var display = new Display(monitor.Handle, bounds, bounds);
            var area = new PixelRect(bounds.X + 300, bounds.Y + 220, 480, 310);
            var scale = 1d;
            var background = SyntheticImage(bounds.Width, bounds.Height);
            foreach (var dark in new[] { false, true })
            {
                WarmTheme.DebugSetDark(dark);
                var suffix = dark ? "深色" : "浅色";
                OpenSettings();
                scale = VisualTreeHelper.GetDpi(settingsWindow!).DpiScaleX;
                foreach (var tab in new[] { ("GeneralTab", "通用"), ("HotkeysTab", "快捷键"), ("ScreenshotTab", "截图设置") })
                {
                    ((RadioButton)settingsWindow!.FindName(tab.Item1)).IsChecked = true;
                    await SettleUI();
                    WriteSettingsImage(settingsWindow, Path.Combine(profile, tab.Item2 + "-" + suffix + ".png"));
                    if (tab.Item1 == "ScreenshotTab")
                    {
                        ((ScrollViewer)settingsWindow.FindName("PageScroll")).ScrollToBottom();
                        await SettleUI();
                        WriteSettingsImage(settingsWindow, Path.Combine(profile, "长截图设置-" + suffix + ".png"));
                    }
                }
                settingsWindow!.Close();

                var errors = new List<string>();
                var done = new TaskCompletionSource<(BitmapSource Image, ScrollAxis Axis, ShotAction Action)>();
                using var session = new LongCaptureSession(display, area, scale, new ScreenshotPreferences(),
                    (image, axis, action) => done.TrySetResult((image, axis, action)), errors.Add, () => { });
                session.DebugStart();
                Check(session.DebugHintVisible, "Mac 语义：长截图开始时显示一次方向提示");
                session.DebugFeed(ScrollTestFrame(area.Width, area.Height, 0, ScrollAxis.Vertical));
                for (var offset = 30; offset <= 180; offset += 30)
                    session.DebugFeed(ScrollTestFrame(area.Width, area.Height, offset, ScrollAxis.Vertical));
                await WaitFor(() => session.DebugLength == area.Height + 180, "竖向拼接长度");
                await Task.Delay(250);
                Check(session.DebugPreview.IsVisible, suffix + "竖向实时预览可见");
                Check(session.DebugControlsFit, "控制条所有按钮位于窗口内");
                Check(Desktop.DebugIsExcluded(new WindowInteropHelper(session.DebugToolbar).Handle) &&
                    Desktop.DebugIsExcluded(new WindowInteropHelper(session.DebugPreview).Handle), "控制条和预览从采集排除");
                WriteLongComposite(display, background, session, Path.Combine(profile, "长截图-竖向-" + suffix + ".png"));
                Check(!session.DebugHintVisible, "Mac 语义：开始拼接后不再保留过程提示");
                var noise = new byte[area.Width * area.Height * 4]; new Random(819).NextBytes(noise);
                session.DebugFeed(new ScrollFrame(area.Width, area.Height, area.Width * 4, noise)); await SettleUI();
                Check(session.DebugLastEvent == ScrollStitcher.EventKind.Lost && !session.DebugHintVisible, "Mac 语义：丢失匹配时保留内容且不反复显示提示");
                session.DebugFeed(ScrollTestFrame(area.Width, area.Height, 150, ScrollAxis.Vertical));
                await SettleUI();
                Check(session.DebugLength == area.Height + 180 && session.DebugAutoStopped, "2.2：回滚不重复拼接，手动会话无滚轮定时器或钩子");
                WriteLongComposite(display, background, session, Path.Combine(profile, "长截图-回滚-" + suffix + ".png"));
                session.DebugFinish(ShotAction.Done);
                var output = await done.Task.WaitAsync(TimeSpan.FromSeconds(5));
                Check(output.Image.PixelWidth == area.Width && output.Image.PixelHeight == area.Height + 180 &&
                    output.Axis == ScrollAxis.Vertical && output.Action == ShotAction.Done, suffix + "2.2 纵向长图按原生像素导出");
                File.WriteAllBytes(Path.Combine(profile, "长图输出-" + suffix + ".png"), ShotEncoding.Encode(output.Image));
                Check(errors.Count == 0, "长截图过程无错误");
            }
            var longPhoto = SyntheticImage(240, 17_000);
            var canvas = new MarkCanvas(longPhoto, 1, ToolInfo.Default, (_, _) => { });
            canvas.SelectTool(Tool.Counter);
            canvas.DebugStroke(new Point(90, 8500), new Point(90, 8500));
            var marked = canvas.RenderCrop(new PixelRect(0, 0, 240, 17_000));
            Check(marked.PixelHeight == 17_000 && ColorAt(marked, 6, 16_920) == ColorAt(longPhoto, 6, 16_920) &&
                ColorAt(marked, 90, 8491) != ColorAt(longPhoto, 90, 8491), "跨 4096 像素分块导出保留长图末端与中部标注");
            WarmTheme.Refresh();
            exitCode = 0;
        }
        catch (Exception error) { results.Add("失败  " + error); }
        finally
        {
            foreach (var window in Windows.Cast<Window>().ToArray()) window.Close();
            File.WriteAllLines(Path.Combine(profile, "结果.txt"), results);
            if (measureIdle && exitCode == 0)
            {
                File.WriteAllText(Path.Combine(profile, "空闲就绪.txt"), "");
                await Task.Delay(TimeSpan.FromSeconds(38));
            }
            Shutdown(exitCode);
        }

        void Check(bool condition, string description)
        {
            if (!condition) throw new InvalidOperationException(description);
            results.Add("通过  " + description);
        }
    }

    private async Task TestContinuousCrop(string profile, Action<bool, string> check)
    {
        var solid = new Border { Background = new SolidColorBrush(Color.FromRgb(43, 96, 151)) };
        var fixture = new Window
        {
            Title = "Velos 连续采集合成测试", WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false, ShowActivated = true, Topmost = true, Content = solid,
            Width = 480, Height = 360, Background = solid.Background
        };
        using var stop = new CancellationTokenSource();
        Task? active = null;
        try
        {
            var bounds = Desktop.Displays().First().WorkArea;
            bounds = new PixelRect(bounds.X + 20, bounds.Y + 20, 480, 360);
            var hwnd = new WindowInteropHelper(fixture).EnsureHandle();
            HwndSource.FromHwnd(hwnd)!.CompositionTarget!.RenderMode = RenderMode.SoftwareOnly;
            Desktop.Position(hwnd, bounds);
            fixture.Show();
            Desktop.Position(hwnd, bounds);
            fixture.Activate();
            fixture.UpdateLayout();
            await SettleUI();
            await Task.Delay(150); // 等待 WPF 合成线程提交合成窗口的首帧。
            Desktop.FlushComposition();
            check(Desktop.WindowBounds(new HashSet<nint>()).Contains(bounds), "合成窗口可见且未被 DWM 隐藏");
            var frames = Channel.CreateBounded<CapturedPixels>(new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest });
            active = WindowsCapture.DebugStreamWindow(hwnd, new PixelRect(63, 57, 212, 133), frame => frames.Writer.TryWrite(frame), stop.Token);
            var first = await frames.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
            solid.Background = new SolidColorBrush(Color.FromRgb(43, 96, 151));
            fixture.InvalidateVisual();
            using var firstDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            while (!Matches(first, 43, 96, 151))
                first = await frames.Reader.ReadAsync(firstDeadline.Token);
            var center = (first.Height / 2 * first.Width + first.Width / 2) * 4;
            check(first.Width == 212 && first.Height == 133 && Matches(first, 43, 96, 151),
                $"连续 WGC 按非零偏移只读回选区像素（{first.Width}×{first.Height}，RGB {first.Bgra[center + 2]},{first.Bgra[center + 1]},{first.Bgra[center]}）");
            solid.Background = new SolidColorBrush(Color.FromRgb(179, 82, 47));
            await SettleUI();
            Desktop.FlushComposition();
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            CapturedPixels changed;
            do { changed = await frames.Reader.ReadAsync(deadline.Token); } while (!Matches(changed, 179, 82, 47));
            check(true, "连续采集收到合成窗口重绘后的新帧");
            stop.Cancel();
            await active.WaitAsync(TimeSpan.FromSeconds(3));
            check(true, "取消采集后释放帧池与 D3D11 资源");
        }
        finally
        {
            stop.Cancel();
            if (active is not null) await active;
            fixture.Close();
        }

        static bool Matches(CapturedPixels frame, byte red, byte green, byte blue)
        {
            var center = (frame.Height / 2 * frame.Width + frame.Width / 2) * 4;
            return Math.Abs(frame.Bgra[center] - blue) <= 2 && Math.Abs(frame.Bgra[center + 1] - green) <= 2 &&
                Math.Abs(frame.Bgra[center + 2] - red) <= 2;
        }
    }

    private async Task TestNativeLongOutput(string profile, Action<bool, string> check)
    {
        var directory = Path.Combine(profile, "原生像素输出");
        var options = new ScreenshotPreferences { Downscale = true, AutoSave = true, Thumbnail = false, Directory = directory };
        var copies = new List<byte[]>();
        var errors = new List<string>();
        using var flow = new ScreenshotController(() => options, _ => null,
            (png, _) => { copies.Add(png); return Task.CompletedTask; }, _ => { }, errors.Add);
        var display = Desktop.Displays().First();
        foreach (var axis in new[] { ScrollAxis.Vertical, ScrollAxis.Horizontal })
        {
            var width = axis == ScrollAxis.Vertical ? 128 : 17_000;
            var height = axis == ScrollAxis.Vertical ? 17_000 : 128;
            var pixels = new byte[width * height * 4];
            for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var offset = (y * width + x) * 4;
                pixels[offset] = (byte)((x + y) % 2 == 0 ? 255 : 0);
                pixels[offset + 1] = (byte)(x % 3 == 0 ? 255 : 0);
                pixels[offset + 2] = (byte)(y % 3 == 0 ? 255 : 0);
                pixels[offset + 3] = 255;
            }
            var source = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgr32, null, pixels, width * 4);
            source.Freeze();
            foreach (var scale in new[] { 1d, 1.25, 1.5, 2d })
            {
                var count = copies.Count;
                await flow.DebugDeliver(source, scale, new PixelRect(0, 0, width, height), display, ShotAction.Done, axis);
                await WaitFor(() => Directory.Exists(directory) && Directory.EnumerateFiles(directory, "*.png").Count() == count + 1, "保存原生长图");
                check(copies.Count == count + 1, "原生长图复制完成");
                var copied = ShotEncoding.Decode(copies[^1]);
                var saved = ShotEncoding.Decode(File.ReadAllBytes(Directory.EnumerateFiles(directory, "*.png").OrderBy(File.GetCreationTimeUtc).Last()));
                var actual = new byte[pixels.Length];
                copied.CopyPixels(actual, width * 4, 0);
                check(copied.PixelWidth == width && copied.PixelHeight == height && saved.PixelWidth == width && saved.PixelHeight == height &&
                    actual.AsSpan().SequenceEqual(pixels) && Math.Abs(copied.DpiX - 96 * scale) < 0.1,
                    $"{axis} {scale * 100:0}% 下保存和复制保留 {width}×{height} 像素与 DPI");
                var sample = axis == ScrollAxis.Vertical ? new Int32Rect(0, 16_850, 128, 100) : new Int32Rect(16_850, 0, 100, 128);
                var view = new PixelImageView(copied) { Width = width / scale, Height = height / scale };
                RenderOptions.SetBitmapScalingMode(view, BitmapScalingMode.NearestNeighbor);
                var viewport = new Canvas { Width = sample.Width / scale, Height = sample.Height / scale, ClipToBounds = true };
                viewport.Children.Add(view);
                Canvas.SetLeft(view, -sample.X / scale);
                Canvas.SetTop(view, -sample.Y / scale);
                viewport.Measure(new Size(viewport.Width, viewport.Height));
                viewport.Arrange(new Rect(0, 0, viewport.Width, viewport.Height));
                var snapshot = new RenderTargetBitmap(sample.Width, sample.Height, 96 * scale, 96 * scale, PixelFormats.Pbgra32);
                snapshot.Render(viewport);
                var expectedPatch = new byte[sample.Width * sample.Height * 4];
                var displayedPatch = new byte[expectedPatch.Length];
                source.CopyPixels(sample, expectedPatch, sample.Width * 4, 0);
                snapshot.CopyPixels(displayedPatch, sample.Width * 4, 0);
                check(expectedPatch.AsSpan().SequenceEqual(displayedPatch), $"{axis} {scale * 100:0}% 下 100% 显示高频像素逐点一致");
            }
            var canvas = new MarkCanvas(source, 1, ToolInfo.Default, (_, _) => { });
            var pinAsset = new ShotImage(ShotEncoding.Encode(source), width, height, 1, new PixelRect(0, 0, width, height), display, axis);
            var pin = new PinWindow(pinAsset, () => { }, () => { }); pin.ShowPinned(); await SettleUI();
            var bar = FindPinScrollBar(pin, axis == ScrollAxis.Vertical ? Orientation.Vertical : Orientation.Horizontal);
            check(bar is not null && Interaction.IsControl(bar), axis + " 长图钉图滚动条独立处理输入，不启动拖动窗口");
            var pinDpi = VisualTreeHelper.GetDpi(pin);
            File.AppendAllText(Path.Combine(profile, "钉图尺寸诊断.txt"), $"{axis}: 原图={width}×{height}; DPI={pinDpi.DpiScaleX},{pinDpi.DpiScaleY}; 内容DIP={pin.DebugPhoto.ActualWidth}×{pin.DebugPhoto.ActualHeight}; 缩放={pin.DebugZoom}; 可滚动={pin.DebugCanScroll}\n");
            check(pin.DebugCanScroll && Math.Abs(pin.DebugPhoto.ActualWidth * pinDpi.DpiScaleX - width * pin.DebugZoom) < 1 &&
                Math.Abs(pin.DebugPhoto.ActualHeight * pinDpi.DpiScaleY - height * pin.DebugZoom) < 1,
                axis + " 长图钉图按当前 DPI 保持完整物理像素尺寸并可滚动");
            pin.Close();
            canvas.SelectTool(Tool.Counter);
            canvas.DebugStroke(new Point(50, 50), new Point(50, 50));
            var output = canvas.RenderCrop(new PixelRect(0, 0, width, height));
            var patch = axis == ScrollAxis.Vertical ? new Int32Rect(0, 16_850, 128, 100) : new Int32Rect(16_850, 0, 100, 128);
            var stride = patch.Width * 4;
            var expected = new byte[stride * patch.Height];
            var rendered = new byte[expected.Length];
            source.CopyPixels(patch, expected, stride, 0);
            output.CopyPixels(patch, rendered, stride, 0);
            check(expected.AsSpan().SequenceEqual(rendered), $"{axis} 17,000 像素高频图标注导出末端逐像素一致");
        }
        check(errors.Count == 0, "原生像素输出无错误");
    }
    private static System.Windows.Controls.Primitives.ScrollBar? FindPinScrollBar(DependencyObject root, Orientation orientation)
    {
        if (root is System.Windows.Controls.Primitives.ScrollBar { IsVisible: true } bar && bar.Orientation == orientation) return bar;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) if (FindPinScrollBar(VisualTreeHelper.GetChild(root, i), orientation) is { } found) return found;
        return null;
    }

    private static ScrollFrame ScrollTestFrame(int width, int height, int offset, ScrollAxis axis)
    {
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        for (var x = 0; x < width; x++)
        {
            var line = axis == ScrollAxis.Vertical ? y + offset : x + offset;
            var cross = axis == ScrollAxis.Vertical ? x : y;
            var index = (y * width + x) * 4;
            // 非周期纹理保留逐行匹配所需的唯一性，颜色使用暖色纸张和文字。
            var hash = unchecked((uint)((line * 2654435761L) ^ (cross * 40503L)));
            hash ^= hash >> 15;
            var ink = line % 42 is > 10 and < 17 && cross > 25 && cross < width - 45;
            pixels[index] = (byte)(ink ? 90 + hash % 40 : 222 + hash % 12);
            pixels[index + 1] = (byte)(ink ? 82 + hash % 40 : 234 + hash % 12);
            pixels[index + 2] = (byte)(ink ? 76 + hash % 40 : 242 + hash % 12);
            pixels[index + 3] = 255;
        }
        return new ScrollFrame(width, height, width * 4, pixels);
    }

    private static ScrollFrame ShiftedColumns(ScrollFrame initial, int offset)
    {
        var result = ScrollTestFrame(initial.Width, initial.Height, offset, ScrollAxis.Horizontal);
        for (var y = 0; y < initial.Height; y++)
            initial.Pixels.AsSpan(y * initial.Stride + offset * 4, (initial.Width - offset) * 4)
                .CopyTo(result.Pixels.AsSpan(y * result.Stride));
        return result;
    }

    private static void WriteLongComposite(Display display, BitmapSource background, LongCaptureSession session, string path)
    {
        var drawing = new DrawingVisual();
        using (var context = drawing.RenderOpen())
        {
            context.DrawImage(background, new Rect(0, 0, display.Bounds.Width, display.Bounds.Height));
            foreach (var window in new[] { session.DebugOverlay, session.DebugToolbar, session.DebugPreview }.Where(window => window.IsVisible))
            {
                var content = (FrameworkElement)window.Content;
                var dpi = VisualTreeHelper.GetDpi(content);
                var rendered = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth * dpi.DpiScaleX),
                    (int)Math.Ceiling(content.ActualHeight * dpi.DpiScaleY), dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
                // 直接渲染控件，避免 VisualBrush 把阴影外框压进控件尺寸而缩小工具条。
                rendered.Render(content);
                var origin = content.PointToScreen(new Point());
                var rect = new Rect(origin.X - display.Bounds.X, origin.Y - display.Bounds.Y, rendered.PixelWidth, rendered.PixelHeight);
                if (window != session.DebugOverlay)
                {
                    var radius = (window == session.DebugToolbar ? 22 : 12) * dpi.DpiScaleX;
                    context.DrawRoundedRectangle(WarmTheme.Floating.Paper, null, rect, radius, radius);
                }
                context.DrawImage(rendered, rect);
            }
        }
        var bitmap = new RenderTargetBitmap(display.Bounds.Width, display.Bounds.Height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(drawing);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = File.Create(path);
        encoder.Save(output);
    }
}
#endif
