#if DEBUG
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Velos.Core.Settings;
using Velos.Screenshot;
using Velos.Windows.Capture;
using PixelPoint = System.Drawing.Point;
using PixelRect = System.Drawing.Rectangle;

namespace Velos;

public partial class App
{
    private async void RunScreenshotSelfTest(string profile, bool measureIdle)
    {
        var results = new List<string>();
        var exitCode = 1;
        Directory.CreateDirectory(profile);
        try
        {
            if (Environment.GetCommandLineArgs().Contains("--pin-regression")) await ReviewPinBehavior(results);
            else if (Environment.GetCommandLineArgs().Contains("--verify-pin-input")) await ReviewNativePin(profile, results);
            else if (Environment.GetCommandLineArgs().Contains("--cursor-regression"))
            {
                await VerifyCursorInteraction((ok, message) => { if (!ok) throw new InvalidOperationException(message); results.Add("通过  " + message); });
                if (Environment.GetCommandLineArgs().Contains("--verify-cursor-input")) await VerifyNativeCursorHover(profile, results);
            }
            else if (Environment.GetCommandLineArgs().Contains("--feature-audit")) await RunFeatureAudit(profile, results);
            else await RunScreenshotScenario(profile, results);
            exitCode = 0;
        }
        catch (Exception error) { results.Add("失败  " + error); }
        finally
        {
            File.WriteAllLines(Path.Combine(profile, "结果.txt"), results);
            if (measureIdle && exitCode == 0)
            {
                File.WriteAllText(Path.Combine(profile, "空闲就绪.txt"), "");
                await Task.Delay(TimeSpan.FromSeconds(38));
            }
            Shutdown(exitCode);
        }
    }

    private async Task RunScreenshotScenario(string profile, List<string> results)
    {
        OpenSettings();
        var settings = settingsWindow!;
        ((RadioButton)settings.FindName("ScreenshotTab")).IsChecked = true;
        await SettleUI();
        WriteSettingsImage(settings, Path.Combine(profile, "截图设置.png"));
        settings.Close();
        Check(!Settings.ScreenshotOptions.AutoSave && Settings.ScreenshotOptions.Copy, "截图设置默认只复制并显示缩略图");

        var monitor = Desktop.Displays().First();
        Check(await WindowsCapture.DebugMonitorSize(monitor) == monitor.Bounds.Size, "WGC 显示器目标尺寸与物理坐标一致");
        var testBounds = new PixelRect(monitor.WorkArea.Left + 28, monitor.WorkArea.Top + 28,
            Math.Min(monitor.WorkArea.Width - 56, 1120), Math.Min(monitor.WorkArea.Height - 56, 800));
        Check(testBounds.Width >= 760 && testBounds.Height >= 580, "合成测试窗口尺寸足够");
        var image = SyntheticImage(testBounds.Width, testBounds.Height);
        await VerifyAnnotationParity(profile, Check);
        await VerifyCursorInteraction(Check);
        var display = new Display(monitor.Handle, testBounds, monitor.WorkArea);
        await TestGraphicsCapture(testBounds, image, profile, Check);
        await VerifyRoundAndCursors(profile, display, image, Check);

        var outputDirectory = Path.Combine(profile, "输出");
        var options = new ScreenshotPreferences { Directory = outputDirectory };
        var copies = new List<(byte[] Png, Action? FirstRead)>();
        var errors = new List<string>();
        using var flow = new ScreenshotController(() => options, value => { options = value; return null; },
            (png, dismiss) => { copies.Add((png, dismiss)); return Task.CompletedTask; }, _ => { }, errors.Add);

        PixelRect Global(int x, int y, int width, int height) => new(testBounds.X + x, testBounds.Y + y, width, height);
        var overlay = flow.DebugStart(display, image, [Global(105, 95, 380, 240), Global(75, 55, 540, 420)]);
        await SettleUI();
        var canvas = overlay.Surface;
        Check(Desktop.DebugIsExcluded(new WindowInteropHelper(overlay).Handle), "选区窗口已启用 WDA_EXCLUDEFROMCAPTURE");
        var mapped = canvas.DebugPixelAt(canvas.PointFromScreen(new Point(testBounds.X + 59, testBounds.Y + 74)));
        Check(mapped == new PixelPoint(59, 74), $"当前 {canvas.PixelScale * 100:0}% 缩放下鼠标坐标精确映射到物理像素");
        canvas.SetPointer(new PixelPoint(160, 120));
        canvas.NotifyColorCopied(); canvas.SetPointer(new PixelPoint(160, 120));
        Check(canvas.DebugColorCopied, "2.2：复制颜色反馈在同一像素持续保留");
        canvas.SetPointer(new PixelPoint(161, 120));
        Check(!canvas.DebugColorCopied, "2.2：移到另一像素后清除已复制反馈");
        canvas.SetPointer(new PixelPoint(160, 120));
        Check(canvas.Target == new PixelRect(105, 95, 380, 240), "重叠窗口悬停选择最前面的窗口");
        canvas.SetPointer(new PixelPoint(14, 14));
        Check(canvas.PointerColor() == "#FFFFFF", "放大镜读取合成棋盘格的准确颜色");
        await SettleUI();
        WriteSettingsImage(overlay, Path.Combine(profile, "放大镜.png"));
        canvas.DebugDrag(new PixelPoint(160, 120), new PixelPoint(160, 120));
        Check(canvas.Region == new PixelRect(105, 95, 380, 240), "单击确认识别到的窗口");
        canvas.DebugDrag(new PixelPoint(30, 40), new PixelPoint(715, 515));
        Check(canvas.Region == new PixelRect(30, 40, 685, 475), "拖拽框选使用物理像素");
        canvas.DebugDrag(new PixelPoint(715, 515), new PixelPoint(727, 526));
        Check(canvas.Region == new PixelRect(30, 40, 697, 486), "右下控制点调整大小");
        canvas.Nudge(Key.Right, ModifierKeys.None);
        canvas.Nudge(Key.Down, ModifierKeys.Shift);
        Check(canvas.Region == new PixelRect(31, 50, 697, 486), "方向键分别移动 1 和 10 像素");
        flow.Toggle(false);
        Check(canvas.FullScreen && canvas.Region?.Size == testBounds.Size, "重复触发切换全屏");
        flow.Toggle(false);
        Check(!canvas.FullScreen && canvas.Region == new PixelRect(31, 50, 697, 486), "全屏切回区域保留原选区");

        var region = canvas.Region!.Value;
        var clean = canvas.RenderCrop(region);
        Check(clean.PixelWidth == region.Width && clean.PixelHeight == region.Height &&
              ColorAt(clean, 2, 3) == ColorAt(image, region.X + 2, region.Y + 3), "输出仅包含选区的原生像素");

        canvas.SelectTool(Tool.Rectangle);
        canvas.SetStyle(ToolInfo.Default(Tool.Rectangle) with { Filled = true });
        Check(canvas.DebugStroke(new Point(67, 90), new Point(129, 138), shift: true), "绘制实心矩形");
        Check(canvas.DebugMarks[0].Bounds.Width == canvas.DebugMarks[0].Bounds.Height, "Shift 绘制正方形");
        canvas.DebugStroke(new Point(92, 115), new Point(92, 115));
        var before = canvas.DebugMarks[0].Bounds;
        canvas.HandleEditingKey(Key.Right, ModifierKeys.None);
        canvas.HandleEditingKey(Key.Up, ModifierKeys.Shift);
        Check(canvas.DebugMarks[0].Bounds.TopLeft == before.TopLeft + new Vector(1, -10), "方向键微调选中的标注");
        Check(!canvas.HandleEditingKey(Key.Right, ModifierKeys.Control), "Ctrl+方向键交给宿主");
        var originalStyle = canvas.DebugMarks[0].Style;
        canvas.BeginStyleEdit(); canvas.SetStyle(originalStyle with { Size = 5 }); canvas.SetStyle(originalStyle with { Size = 8 }); canvas.EndStyleEdit();
        Check(canvas.DebugMarks[0].Style.Size == 8, "拖动属性滑块时标注实时预览");
        canvas.Undo(); Check(canvas.DebugMarks[0].Style == originalStyle, "一次撤销恢复整段滑块调整");
        canvas.DebugStroke(new Point(93, 105), new Point(93, 105));
        canvas.HandleEditingKey(Key.Delete, ModifierKeys.None);
        Check(canvas.DebugMarks.Count == 0, "Delete 删除选中的标注");
        canvas.HandleEditingKey(Key.Z, ModifierKeys.Control);
        Check(canvas.DebugMarks.Count == 1, "Ctrl+Z 撤销删除");
        canvas.HandleEditingKey(Key.Z, ModifierKeys.Control | ModifierKeys.Shift);
        Check(canvas.DebugMarks.Count == 0, "Ctrl+Shift+Z 重做删除");
        canvas.Undo();

        (Tool Tool, Point Start, Point End)[] marks =
        [
            (Tool.Ellipse, new(170, 90), new(240, 143)), (Tool.Arrow, new(275, 90), new(355, 152)),
            (Tool.Line, new(385, 90), new(465, 135)), (Tool.Pen, new(525, 92), new(590, 150)),
            (Tool.Highlighter, new(82, 228), new(163, 240)), (Tool.Text, new(209, 224), new(209, 224)),
            (Tool.Counter, new(550, 242), new(550, 242)), (Tool.Mosaic, new(77, 348), new(232, 432)),
            (Tool.Blur, new(294, 348), new(450, 430))
        ];
        foreach (var item in marks)
        {
            var count = canvas.DebugMarks.Count;
            canvas.SelectTool(item.Tool);
            canvas.DebugStroke(item.Start, item.End);
            if (item.Tool == Tool.Text) canvas.DebugText("Velos 合成测试");
            Check(canvas.DebugMarks.Count == count + 1 && canvas.DebugMarks[^1].Tool == item.Tool, $"绘制{ToolInfo.For(item.Tool).Name}");
        }
        Check(canvas.DebugMarks.Count == 10 && canvas.DebugMarks.Any(mark => mark.Text == "Velos 合成测试"), "十种标注均已提交");
        canvas.SelectTool(Tool.Rectangle);
        await SettleUI();
        WriteSettingsImage(overlay, Path.Combine(profile, "框选和标注.png"));
        var marked = canvas.RenderCrop(region);
        Check(ColorAt(marked, 90 - region.X, 107 - region.Y) == "#FF3B30", "导出保留标注颜色");
        Check(ColorAt(marked, 90 - region.X, 370 - region.Y) != ColorAt(clean, 90 - region.X, 370 - region.Y),
            "马赛克改变原图像素");
        Check(ColorAt(marked, 315 - region.X, 371 - region.Y) != ColorAt(clean, 315 - region.X, 371 - region.Y),
            "模糊改变原图像素");
        flow.DebugAction(overlay, ShotAction.Done);
        await WaitFor(() => copies.Count == 1 && flow.DebugThumbnails.Count == 1, "生成剪贴板和缩略图");
        Check(!Directory.Exists(outputDirectory), "默认完成只复制，磁盘没有生成截图");
        var thumbnail = flow.DebugThumbnails[0];
        await Task.Delay(240);
        await SettleUI();
        WriteSettingsImage(thumbnail, Path.Combine(profile, "缩略图.png"));
        var asset = thumbnail.Image;
        Check(ScreenshotDrag.DebugVirtualPng(asset), "未保存的缩略图提供可拖出的 OLE PNG 流");
        Check(ShotEncoding.Decode(copies[0].Png).PixelWidth == region.Width, "剪贴板 PNG 保留物理像素");
        var dib = ShotEncoding.Dib(copies[0].Png);
        Check(BitConverter.ToInt32(dib, 4) == region.Width && BitConverter.ToInt32(dib, 8) == -region.Height,
            "Windows DIB 兼容格式尺寸正确");
        await flow.DebugSave(asset);
        Check(asset.SavedPath is { } saved && File.Exists(saved), "显式保存生成 PNG 文件");
        Check(thumbnail.DebugSaveAction == "在文件资源管理器中显示", "Mac 语义：缩略图保存后切换为显示文件");
        Check(Encoding.ASCII.GetString(asset.Png).Contains("iCCP", StringComparison.Ordinal), "PNG 嵌入 ICC 色彩配置");
        copies[0].FirstRead!();
        await WaitFor(() => flow.DebugThumbnails.Count == 0, "读取剪贴板后缩略图收起");
        Check(thumbnail.IsClosed, "粘贴回调关闭原缩略图");

        var editor = flow.DebugEdit(asset)!;
        await SettleUI();
        editor.DebugZoomTo(6);
        Check(editor.DebugZoom == 4, "编辑器缩放上限为 400%");
        editor.DebugZoomTo(0.8);
        editor.DebugCanvas.SelectTool(Tool.Counter);
        editor.DebugCanvas.DebugStroke(new Point(530, 200), new Point(530, 200));
        await SettleUI();
        WriteSettingsImage(editor, Path.Combine(profile, "编辑窗口.png"));
        await Task.Delay(1600); Check(!editor.DebugZoomHudVisible && !editor.DebugZoomTimerRunning, "Mac 语义：编辑器比例提示 1.2 秒后淡出且停止计时");
        editor.DebugPerform(ShotAction.Pin);
        await WaitFor(() => Windows.OfType<PinWindow>().Any(), "编辑后的截图可钉图");
        var pin = Windows.OfType<PinWindow>().Single();
        Check(pin.Topmost && pin.IsVisible, "钉图置顶可见");
        await SettleUI();
        WriteSettingsImage(pin, Path.Combine(profile, "钉图.png"));
        var pinDpi = VisualTreeHelper.GetDpi(pin).DpiScaleX;
        Check(Math.Abs(pin.DebugPhoto.ActualWidth * pinDpi - asset.Width) < 2, "Mac 语义：钉图描边不挤占原图像素宽度");
        pin.DebugZoomTo(2); await SettleUI(); Check(pin.DebugZoom == 2, "Mac 语义：钉图可缩放超过原始大小");
        pin.Close();
        var nativeOptions = options; options = options with { Downscale = true };
        await flow.DebugCopyNative(asset); Check(ShotEncoding.Decode(copies[^1].Png).PixelWidth == asset.Width, "Mac 语义：钉图复制原生图片，不套用输出 1x 设置");
        var nativePath = Path.Combine(outputDirectory, "钉图另存.png"); await flow.DebugSaveNative(asset, nativePath);
        Check(ShotEncoding.Decode(File.ReadAllBytes(nativePath)).PixelWidth == asset.Width, "Mac 语义：钉图另存保留原生像素"); options = nativeOptions;

        options = options with { Format = ScreenshotFormat.Jpeg, Copy = false, Thumbnail = false };
        var second = flow.DebugStart(display, image, []);
        second.Surface.DebugDrag(new PixelPoint(32, 55), new PixelPoint(218, 172));
        flow.DebugAction(second, ShotAction.Save);
        await WaitFor(() => Directory.EnumerateFiles(outputDirectory, "*.jpg").Any(), "保存 JPEG 文件");
        var jpeg = File.ReadAllBytes(Directory.EnumerateFiles(outputDirectory, "*.jpg").Single());
        Check(jpeg[0] == 0xff && jpeg[1] == 0xd8 &&
              Encoding.ASCII.GetString(jpeg).Contains("ICC_PROFILE", StringComparison.Ordinal), "JPEG 格式和 ICC 正确");
        if (ShotEncoding.SupportsHeic)
        {
            var heic = await ShotEncoding.EncodeHeic(ShotEncoding.Resize(clean, 0.25), 90);
            Check(heic.Length > 12 && Encoding.ASCII.GetString(heic, 4, 4) == "ftyp", "系统 HEIC 编码器生成有效容器");
        }
        else
        {
            results.Add("环境  当前系统未枚举到 HEIC 编码器");
        }
        Check(errors.Count == 0, errors.Count == 0 ? "截图流程无输出错误" : string.Join("；", errors));

        void Check(bool condition, string text)
        {
            if (!condition) throw new InvalidOperationException(text);
            results.Add("通过  " + text);
        }
    }

    private async Task TestGraphicsCapture(PixelRect bounds, BitmapSource synthetic, string profile, Action<bool, string> check)
    {
        var fixture = new Window
        {
            Title = "Velos 合成采集测试", WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false, ShowActivated = true, Topmost = true,
            Content = new Image { Source = synthetic, Stretch = Stretch.Fill, SnapsToDevicePixels = true }
        };
        var hwnd = new WindowInteropHelper(fixture).EnsureHandle();
        // 保持已知的合成图实际呈现；部分远程显示驱动不提交 WPF 的硬件窗口表面。
        HwndSource.FromHwnd(hwnd)!.CompositionTarget!.RenderMode = RenderMode.SoftwareOnly;
        try
        {
            Desktop.Position(hwnd, bounds);
            fixture.Show();
            Desktop.Position(hwnd, bounds);
            fixture.UpdateLayout();
            await SettleUI();
            Desktop.FlushComposition();
            check(!Desktop.DebugIsExcluded(hwnd), "合成窗口本身没有启用采集排除");
            check(Desktop.WindowBounds(new HashSet<nint>()).Contains(bounds), "系统窗口枚举取得合成窗口的物理边界");
            check(!Desktop.WindowBounds(new HashSet<nint> { hwnd }).Contains(bounds), "临时窗口从自动识别列表中排除");
            var captured = await WindowsCapture.DebugFreezeWindow(hwnd, CancellationToken.None);
            check(captured.Width == bounds.Width && captured.Height == bounds.Height, "WGC 原生读回合成窗口的物理尺寸");
            var offset = (22 * captured.Width + 22) * 4;
            var readback = BitmapSource.Create(captured.Width, captured.Height, 96, 96, PixelFormats.Bgra32, null, captured.Bgra, captured.Width * 4);
            File.WriteAllBytes(Path.Combine(profile, "WGC合成帧.png"), ShotEncoding.Encode(readback));
            check(captured.Bgra[offset] == captured.Bgra[offset + 1] && captured.Bgra[offset] >= 245,
                $"D3D11 读取真实 WGC 帧中的合成白色像素（BGRA {string.Join(',', captured.Bgra.AsSpan(offset, 4).ToArray())}）");
        }
        finally { fixture.Close(); }
    }

    private static BitmapSource SyntheticImage(int width, int height)
    {
        var data = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
        for (var x = 0; x < width; x++)
        {
            var offset = (y * width + x) * 4;
            if (x < 38 && y < 38 || y is > 340 and < 435)
            {
                var value = (byte)(((x + y) % 2 == 0) ? 255 : 0);
                data[offset] = data[offset + 1] = data[offset + 2] = value;
            }
            else
            {
                data[offset] = (byte)(228 + x % 16);
                data[offset + 1] = (byte)(214 + y % 29);
                data[offset + 2] = (byte)(197 + x % 35);
            }
        }
        var image = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgr32, null, data, width * 4);
        image.Freeze();
        return image;
    }

    private static string ColorAt(BitmapSource source, int x, int y)
    {
        var bitmap = source.Format.BitsPerPixel == 32 ? source : new FormatConvertedBitmap(source, PixelFormats.Bgr32, null, 0);
        var bytes = new byte[4];
        bitmap.CopyPixels(new Int32Rect(x, y, 1, 1), bytes, 4, 0);
        return $"#{bytes[2]:X2}{bytes[1]:X2}{bytes[0]:X2}";
    }

    private static async Task WaitFor(Func<bool> condition, string operation)
    {
        var deadline = DateTime.UtcNow.AddSeconds(7);
        while (!condition())
        {
            if (DateTime.UtcNow >= deadline)
                throw new TimeoutException(operation);
            await Task.Delay(25);
        }
    }
}
#endif
