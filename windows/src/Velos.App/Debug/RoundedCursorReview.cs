#if DEBUG
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velos.Core.Settings;
using Velos.Screenshot;
using Velos.UI;
using Velos.Windows.Capture;
using PixelRect = System.Drawing.Rectangle;

namespace Velos;

public partial class App
{
    private async Task VerifyRoundAndCursors(string profile, Display display, BitmapSource image, Action<bool, string> check)
    {
        foreach (var scale in new[] { 1d, 1.25, 1.5, 2 })
        {
            var raster = WarmCursors.DebugRaster(scale, 0, false, true);
            check(raster.PixelWidth == (int)Math.Ceiling(26 * scale) && WarmCursors.DebugNative(scale), $"2.2 {scale * 100:0}%：矢量光标按 DPI 原生生成，Win32 句柄有效且缓存复用");
        }
        var sheet = new DrawingVisual(); using (var dc = sheet.RenderOpen())
        {
            Brush[] backgrounds = [Brushes.White, WarmTheme.Brush(46, 46, 46), WarmTheme.Apricot, WarmTheme.Brush(33, 69, 135)];
            for (var row = 0; row < backgrounds.Length; row++) for (var col = 0; col < 5; col++)
            {
                var tile = new Rect(col * 130, row * 130, 130, 130); dc.DrawRectangle(backgrounds[row], null, tile);
                dc.DrawImage(WarmCursors.DebugRaster(5, col switch { 1 => 4, 2 => 6, 3 => 7, _ => 0 }, col is >= 1 and <= 3, col == 0), tile);
            }
        }
        var bitmap = new RenderTargetBitmap(650, 520, 96, 96, PixelFormats.Pbgra32); bitmap.Render(sheet);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap)); using (var output = File.Create(Path.Combine(profile, "暖色光标图册.png"))) encoder.Save(output);
        var wheel = new Slider { Style = CaptureChrome.SliderStyle, Minimum = 10, Maximum = 100, Value = 50, SmallChange = 5 }; wheel.ApplyTemplate();
        wheel.RaiseEvent(new MouseWheelEventArgs(Mouse.PrimaryDevice, Environment.TickCount, 120) { RoutedEvent = Mouse.PreviewMouseWheelEvent });
        check(wheel.Value == 55, "2.2：不透明度拉条滚动一格微调 5%，不使用系统默认大步长");

        var options = new ScreenshotPreferences { ScreenshotCornerRadius = 12, Copy = false, Thumbnail = false, Directory = Path.Combine(profile, "圆角输出"), Format = ScreenshotFormat.Heic };
        using var flow = new ScreenshotController(() => options, value => { options = value; return null; }, (_, _) => Task.CompletedTask, _ => { }, message => throw new InvalidOperationException(message));
        var window = flow.DebugStart(display, image, []); var canvas = window.Surface;
        try
        {
            canvas.DebugDrag(new System.Drawing.Point(50, 50), new System.Drawing.Point(350, 250));
            await SettleUI(); window.DebugCornerSlider.Value = 20;
            check(options.ScreenshotCornerRadius == 20 && canvas.CornerRadius == 20, "2.2：圆角拉条实时更新选区并写回设置");
            window.DebugCornerSlider.Value = 12;
            var crop = new PixelRect(50, 50, 300, 200); var rounded = canvas.RenderCrop(crop);
            byte Alpha(BitmapSource source, int x, int y)
            {
                var converted = source.Format == PixelFormats.Bgra32 ? source : new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
                var pixel = new byte[4]; converted.CopyPixels(new Int32Rect(x, y, 1, 1), pixel, 4, 0); return pixel[3];
            }
            check(Alpha(rounded, 0, 0) == 0 && Alpha(rounded, 299, 199) == 0 && ColorAt(rounded, 150, 100) == ColorAt(image, 200, 150), "2.2：圆角导出四角透明，中心仍为原生像素");
            var png = ShotEncoding.Encode(rounded); var decoded = ShotEncoding.Decode(png);
            check(Alpha(decoded, 0, 0) == 0 && Alpha(ShotEncoding.Resize(decoded, .5), 0, 0) < 255, "2.2：PNG 和 1x 缩小保留透明");
            var jpeg = ShotEncoding.Decode(ShotEncoding.Encode(rounded, ScreenshotFormat.Jpeg));
            check(ColorAt(jpeg, 0, 0) == "#FFFFFF", "2.2：JPEG 圆角外填白");
            var edit = new MarkCanvas(decoded, 1, ToolInfo.Default, (_, _) => { });
            check(Alpha(edit.RenderCrop(new PixelRect(0, 0, 300, 200)), 0, 0) == 0, "2.2：重新编辑圆角图片不垫不透明底板，不丢 alpha");
            var asset = new ShotImage(png, 300, 200, canvas.PixelScale, crop, display);
            var saved = await flow.DebugSaveAsset(asset);
            check(saved is not null && saved.EndsWith(".png", StringComparison.OrdinalIgnoreCase) && ShotEncoding.HasTransparency(ShotEncoding.Decode(await File.ReadAllBytesAsync(saved))),
                "2.2：Windows HEIC 不保证 alpha 时使用真实 PNG 扩展名保存透明图");
            WriteSettingsImage(window, Path.Combine(profile, "圆角截图.png"));
            var editor = flow.DebugEdit(asset)!; await SettleUI(); WriteSettingsImage(editor, Path.Combine(profile, "圆角编辑器.png")); editor.Close();
            canvas.SetFullScreen(true);
            check(!ShotEncoding.HasTransparency(canvas.RenderCrop(new PixelRect(0, 0, image.PixelWidth, image.PixelHeight))), "2.2：全屏截图保持直角，不应用区域圆角");
        }
        finally { flow.Dispose(); }

        using var multiple = new ScreenshotController(() => options, _ => null, (_, _) => Task.CompletedTask, _ => { }, message => throw new InvalidOperationException(message));
        var small = SyntheticImage(450, 320); var left = new PixelRect(display.Bounds.X, display.Bounds.Y, 450, 320);
        var right = new PixelRect(left.Right + 10, left.Top, 450, 320);
        var pair = multiple.DebugStartDisplays([(display with { Bounds = left }, small), (display with { Bounds = right }, small)]);
        pair[0].Surface.DebugDrag(new System.Drawing.Point(40, 40), new System.Drawing.Point(250, 180));
        var remembered = pair[0].Surface.Region;
        pair[0].Surface.SetFullScreen(true);
        check(pair[0].Surface.Region is not null && pair[1].Surface.Suppressed && !pair[1].Surface.IsHitTestVisible,
            "2.2：合成双屏全屏模式锁定当前屏，其他屏仅暗化且不抢选区");
        multiple.DebugMoveFullScreen(pair[1]);
        check(pair[1].Surface.FullScreen && pair[0].Surface.Suppressed, "2.2：全屏框跟随鼠标切换目标屏幕");
        pair[1].Surface.SetFullScreen(false);
        check(pair.All(window => !window.Surface.Suppressed && window.Surface.IsHitTestVisible), "2.2：退出全屏后恢复各屏框选");
        check(pair[0].Surface.Region == remembered, "2.2：全屏跨屏往返仍保留原先的区域选区");
    }
}
#endif
