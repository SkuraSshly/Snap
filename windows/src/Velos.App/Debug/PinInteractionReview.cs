#if DEBUG
using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Automation;
using System.Windows.Input;
using System.Windows.Media;
using Velos.Core.LongCapture;
using Velos.Core.Screenshot;
using Velos.Core.Settings;
using Velos.Core.Animation;
using Velos.Screenshot;
using Velos.Windows.Capture;
using Velos.UI;
using PixelRect = System.Drawing.Rectangle;

namespace Velos;

public partial class App
{
    private async Task ReviewPinBehavior(List<string> results)
    {
        var display = Desktop.Displays().First();
        foreach (var (width, height) in new[] { (600, 400), (240, Math.Max(3000, display.WorkArea.Height * 2)), (Math.Max(3000, display.WorkArea.Width * 2), 240) })
        {
            var asset = new ShotImage(ShotEncoding.Encode(SyntheticImage(width, height)), width, height, 1,
                new PixelRect(display.WorkArea.X + 100, display.WorkArea.Y + 100, Math.Min(width, 600), Math.Min(height, 400)), display);
            var pin = new PinWindow(asset, () => { }, () => { }); pin.ShowPinned(); await SettleUI();
            try
            {
                var longAxis = PinLayout.LongAxis(new(width, height)); var before = pin.DebugZoom;
                await Task.Delay(800); Check(pin.IsActive, "P00", "钉上后 0.8 秒仍选中，无需先点一下");
                var anchor = new Point(pin.ActualWidth * .4, pin.ActualHeight * .4);
                if (longAxis is not null) { pin.DebugWheel(-120, ModifierKeys.None, anchor); await SettleUI(); Check(pin.DebugZoom == before && pin.DebugScrollOffset > 0, "P01L", "长图普通滚轮只翻看"); }
                pin.DebugWheel(120, longAxis is null ? ModifierKeys.None : ModifierKeys.Alt, anchor);
                await SettleUI(); Check(pin.DebugZoom > before, "P01", $"{width}×{height} {(longAxis is null ? "普通" : "Alt")}滚轮缩放生效");
                pin.DebugZoomTo(1); await SettleUI(); before = pin.DebugZoom;
                var input = PresentationSource.FromVisual(pin)!;
                pin.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, input, 0, Key.OemPlus) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
                Check(pin.DebugZoom == before, "P02", "+ 按键不会缩放");
                var bounds = Desktop.WindowRectangle(new WindowInteropHelper(pin).Handle);
                var pointer = new System.Drawing.Point(bounds.Right - 1, bounds.Top + bounds.Height / 2);
                var scaleEdge = longAxis == ScrollAxis.Horizontal ? PinEdge.Bottom : PinEdge.Right;
                pin.DebugBeginEdge(scaleEdge, pointer);
                Check(pin.DebugResizing && pin.IsMouseCaptured && pin.ForceCursor, "P03", "边缘按下捕获鼠标并显示双三角光标");
                var heldZoom = pin.DebugZoom;
                pin.DebugWheel(120, longAxis is null ? ModifierKeys.None : ModifierKeys.Alt, anchor);
                Check(pin.DebugZoom == heldZoom, "P03W", "拖边过程中滚轮不改写缩放起点");
                pin.DebugResizeEdge(new(pointer.X + (scaleEdge == PinEdge.Right ? bounds.Width / 4 : 0), pointer.Y + (scaleEdge == PinEdge.Bottom ? bounds.Height / 4 : 0))); pin.DebugEndEdge(); await SettleUI();
                var next = Desktop.WindowRectangle(new WindowInteropHelper(pin).Handle);
                Check(Math.Abs(pin.DebugZoom - before * 1.25) < .005 && (scaleEdge == PinEdge.Right ? next.Left == bounds.Left : next.Top == bounds.Top), "P04", "拖出原窗口仍缩放，固定对边");
                Check(!pin.DebugResizing && !pin.IsMouseCaptured, "P05", "松手释放捕获，不锁定缩放状态");
                var menu = pin.ContextMenu!;
                Check(!menu.Items.OfType<MenuItem>().Any(item => AutomationProperties.GetAutomationId(item) is "PinZoomIn" or "PinZoomOut"), "P06", "菜单不再提供步进缩放");
                var resized = pin.DebugZoom;
                var opacity = pin.Opacity;
                pin.DebugWheel(-120, ModifierKeys.Control, anchor); await SettleUI();
                Check(pin.Opacity < opacity && pin.DebugZoom == resized, "P07", "Ctrl+滚轮仍只调透明度");
                bounds = Desktop.WindowRectangle(new WindowInteropHelper(pin).Handle);
                pin.DebugBeginEdge(PinEdge.Left | PinEdge.Top, pointer); pin.DebugResizeEdge(new(pointer.X + 80, pointer.Y + 80));
                pin.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, input, 0, Key.Escape) { RoutedEvent = Keyboard.PreviewKeyDownEvent }); await SettleUI();
                Check(pin.DebugZoom == resized && Desktop.WindowRectangle(new WindowInteropHelper(pin).Handle) == bounds && !pin.DebugResizing && pin.IsVisible, "P08", "Esc 取消本次缩放，恢复尺寸且保留钉图");
                pin.DebugBeginEdge(PinEdge.Bottom, pointer); pin.DebugResizeEdge(new(pointer.X, pointer.Y + 30)); pin.ReleaseMouseCapture();
                Check(!pin.DebugResizing, "P09", "捕获丢失清理状态");
                var reset = menu.Items.OfType<MenuItem>().Single(item => AutomationProperties.GetAutomationId(item) == "PinZoomReset");
                reset.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); await SettleUI();
                Check(pin.DebugZoom == 1 && string.IsNullOrEmpty(reset.InputGestureText), "P10", "菜单原始大小恢复 100%，没有缩放快捷键");
                if (longAxis is not null)
                {
                    pin.DebugScrollTo(250); await SettleUI();
                    var offset = pin.DebugScrollOffset;
                    pin.DebugWheel(-120, ModifierKeys.None, anchor); await SettleUI();
                    Check(pin.DebugScrollOffset > offset && pin.DebugZoom == 1, "P11", "长图普通滚轮只翻看，不误改比例");
                    offset = pin.DebugScrollOffset;
                    for (var tick = 0; tick < 6; tick++) pin.DebugWheel(-120, ModifierKeys.None, anchor);
                    await SettleUI(); Check(Math.Abs(pin.DebugScrollOffset - offset - 72) < .5, "P17", "快速连续翻看累积全部滚轮步长");
                    var screenAnchor = pin.PointToScreen(new Point(pin.ActualWidth * .5, pin.ActualHeight * .45));
                    var sourceAtPointer = SourceAtPointer();
                    for (var tick = 0; tick < 6; tick++) pin.DebugWheel(120, ModifierKeys.Alt, pin.PointFromScreen(screenAnchor));
                    await SettleUI();
                    var drift = Math.Abs(SourceAtPointer() - sourceAtPointer);
                    Check(drift < 2, "P16", $"长图连续快速滚轮保持鼠标下原图位置（误差 {drift:0.00} 像素）");
                    double SourceAtPointer() {
                        var local = pin.PointFromScreen(screenAnchor); var scale = VisualTreeHelper.GetDpi(pin).DpiScaleX;
                        return (pin.DebugScrollOffset + (longAxis == ScrollAxis.Vertical ? local.Y : local.X)) * scale / pin.DebugZoom;
                    }
                    pin.DebugZoomTo(1); await SettleUI(); pin.DebugScrollTo(250); await SettleUI();
                    var dpi = VisualTreeHelper.GetDpi(pin).DpiScaleX;
                    bounds = Desktop.WindowRectangle(new WindowInteropHelper(pin).Handle);
                    var sourcePoint = pin.DebugScrollOffset * dpi / pin.DebugZoom;
                    pin.DebugBeginEdge(longAxis == ScrollAxis.Vertical ? PinEdge.Right : PinEdge.Bottom, pointer);
                    pin.DebugResizeEdge(new(pointer.X + (longAxis == ScrollAxis.Vertical ? bounds.Width / 4 : 0), pointer.Y + (longAxis == ScrollAxis.Horizontal ? bounds.Height / 4 : 0)));
                    pin.DebugEndEdge(); await SettleUI();
                    next = Desktop.WindowRectangle(new WindowInteropHelper(pin).Handle); dpi = VisualTreeHelper.GetDpi(pin).DpiScaleX;
                    var nextSource = pin.DebugScrollOffset * dpi / pin.DebugZoom;
                    Check(Math.Abs(nextSource - sourcePoint) < 2, "P12", "长图边缘缩放按比例保留已滚过的图像距离");
                    bounds = next; var previousZoom = pin.DebugZoom;
                    pin.DebugBeginEdge(longAxis == ScrollAxis.Vertical ? PinEdge.Bottom : PinEdge.Right, pointer);
                    pin.DebugResizeEdge(new(pointer.X + (longAxis == ScrollAxis.Horizontal ? -60 : 0), pointer.Y + (longAxis == ScrollAxis.Vertical ? -60 : 0))); pin.DebugEndEdge(); await SettleUI();
                    next = Desktop.WindowRectangle(new WindowInteropHelper(pin).Handle);
                    Check(pin.DebugZoom == previousZoom && (longAxis == ScrollAxis.Vertical ? next.Height < bounds.Height && next.Width == bounds.Width : next.Width < bounds.Width && next.Height == bounds.Height), "P14", "沿长轴拖单边只收视口，像素比例不变");
                }
                bounds = Desktop.WindowRectangle(new WindowInteropHelper(pin).Handle);
                pin.DebugBeginEdge(scaleEdge, pointer); pin.DebugResizeEdge(new(pointer.X + (scaleEdge == PinEdge.Right ? bounds.Width * 20 : 0), pointer.Y + (scaleEdge == PinEdge.Bottom ? bounds.Height * 20 : 0))); pin.DebugEndEdge();
                await SettleUI(); Check(pin.DebugZoom == 8, "P13", "边缘缩放保持 800% 上限");
                bounds = Desktop.WindowRectangle(new WindowInteropHelper(pin).Handle);
                pin.DebugWheel(int.MaxValue, longAxis is null ? ModifierKeys.None : ModifierKeys.Alt, new Point(10, 10));
                Check(pin.DebugZoom == 8 && Desktop.WindowRectangle(new WindowInteropHelper(pin).Handle) == bounds, "P18", "已到缩放上限时视口不再跳变");
            }
            finally { pin.Close(); }
        }
        var tinyAsset = new ShotImage(ShotEncoding.Encode(SyntheticImage(8, 8)), 8, 8, 1,
            new PixelRect(display.WorkArea.Left + 100, display.WorkArea.Top + 100, 8, 8), display);
        var tinyPin = new PinWindow(tinyAsset, () => { }, () => { }); tinyPin.ShowPinned(); await SettleUI();
        try {
            for (var tick = 0; tick < 25; tick++) tinyPin.DebugWheel(120, ModifierKeys.None, new Point(2, 2));
            Check(tinyPin.DebugZoom > 1, "P19", "极小钉图仍可用滚轮逐步放大");
            tinyPin.DebugWheel(-10000, ModifierKeys.None, new Point(2, 2)); await SettleUI();
            var dpi = VisualTreeHelper.GetDpi(tinyPin).DpiScaleX;
            Check(Math.Abs(tinyPin.DebugZoom * 8 - 20 * dpi) < 1, "P20", "大幅滚轮缩小夹到最小可操作尺寸，不整次忽略输入");
            tinyPin.DebugZoomTo(1); await SettleUI(); Check(tinyPin.DebugZoom == 1, "P21", "极小钉图仍可恢复原始像素比例");
        } finally { tinyPin.Close(); }
        using (var flow = new ScreenshotController(() => new ScreenshotPreferences(), _ => null, (_, _) => Task.CompletedTask, _ => { }, message => throw new InvalidOperationException(message)))
        {
            var bounds = new PixelRect(display.WorkArea.Left + 100, display.WorkArea.Top + 100, 600, 400);
            var overlay = flow.DebugStart(new Display(display.Handle, bounds, display.WorkArea), SyntheticImage(600, 400), [], trackFocus: true);
            overlay.Surface.SetFullScreen(true); await SettleUI();
            flow.DebugAction(overlay, ShotAction.Pin);
            await WaitFor(() => Windows.OfType<PinWindow>().Any(), "从截图工具栏钉图");
            var pinned = Windows.OfType<PinWindow>().Single();
            try { await Task.Delay(800); Check(pinned.IsActive && pinned.IsVisible && !flow.IsActive, "P15", "从截图工具栏钉上 0.8 秒后仍选中，选区已关闭"); }
            finally { pinned.Close(); }
        }
        var transform = new TranslateTransform();
        var motionHost = new Window { Title = "Velos 动效合成检查", Width = 180, Height = 100,
            Content = new Border { Width = 40, Height = 20, Background = WarmTheme.Apricot, RenderTransform = transform } };
        motionHost.Show(); await SettleUI();
        try {
        // 给独立测试足够的采样窗口，不把渲染繁忙时已结束的动画误当成中间帧。
        WarmMotion.Spring(transform, TranslateTransform.XProperty, 13, 1, .7, from: 0); await Task.Delay(65);
        var current = transform.X;
        Check(!WarmMotion.Allowed || transform.HasAnimatedProperties && current > 0 && Math.Abs(current - 13) > .01,
            "A00", "可视元素确实采样到中间动画状态");
        var velocity = WarmMotion.SpringVelocity(transform, TranslateTransform.XProperty);
        WarmMotion.Spring(transform, TranslateTransform.XProperty, 0, .2, .7);
        Check(!WarmMotion.Allowed || Math.Abs(transform.X - current) < .01, "A01", $"动画中途反向从当前值接续（动画={WarmMotion.Allowed}，前={current:0.000}，后={transform.X:0.000}）");
        Check(!WarmMotion.Allowed || Math.Abs(WarmMotion.SpringVelocity(transform, TranslateTransform.XProperty) - velocity) < .01, "A04", "快速反向同时继承弹簧速度");
        await Task.Delay(650);
        Check(transform.X == 0 && !transform.HasAnimatedProperties, "A02", "弹簧结束准确归位且移除时钟");
        var switchMotion = new SpringMotion(0, 1, 0, .3, .68);
        Check(switchMotion.Sample(.2).Value > 1 && Math.Abs(switchMotion.Sample(1).Value - 1) < .001,
            "A03", "Mac 开关参数产生轻微回弹并收敛");
        } finally { motionHost.Close(); }
        void Check(bool condition, string id, string message) { if (!condition) throw new InvalidOperationException($"[{id}] {message}"); results.Add($"通过  [{id}] {message}"); }
    }
    private async Task ReviewNativePin(string profile, List<string> results)
    {
        var display = Desktop.Displays().First();
        var isLong = Environment.GetCommandLineArgs().Contains("--pin-long");
        var wheelReview = Environment.GetCommandLineArgs().Contains("--verify-pin-wheel");
        var width = isLong ? 300 : 600; var height = isLong ? 3000 : 400;
        var source = SyntheticImage(width, height);
        var asset = new ShotImage(ShotEncoding.Encode(source), width, height, 1, new PixelRect(display.WorkArea.X + 180, display.WorkArea.Y + 180, width, Math.Min(400, height)), display);
        using var flow = new ScreenshotController(() => new ScreenshotPreferences(), _ => null, (_, _) => Task.CompletedTask, _ => { }, message => throw new InvalidOperationException(message));
        PinWindow pin;
        if (!isLong)
        {
            var area = new Display(display.Handle, asset.Source, display.WorkArea);
            var overlay = flow.DebugStart(area, source, [], trackFocus: true); overlay.Surface.SetFullScreen(true); await SettleUI();
            flow.DebugAction(overlay, ShotAction.Pin); await WaitFor(() => Windows.OfType<PinWindow>().Any(), "从截图工具栏钉图");
            pin = Windows.OfType<PinWindow>().Single();
        }
        else { pin = new PinWindow(asset, () => { }, () => { }); pin.ShowPinned(); }
        pin.Title = wheelReview ? "Velos 钉图滚轮验收" : "Velos 钉图边缘验收"; pin.ShowInTaskbar = true; await SettleUI();
        try
        {
            var before = pin.DebugZoom;
            var wheelChanges = 0; var scrollChanges = 0; var lastOffset = pin.DebugScrollOffset;
            pin.DebugWheelInput += (delta, modifiers, oldZoom, newZoom, offset) => {
                if (Math.Abs(newZoom - oldZoom) > .000001) wheelChanges++;
                if (Math.Abs(offset - lastOffset) > .001) scrollChanges++;
                lastOffset = offset;
                File.AppendAllText(Path.Combine(profile, "实际滚轮输入.txt"), $"delta={delta}; modifiers={modifiers}; zoom={oldZoom:F6}->{newZoom:F6}; offset={offset:F3}; bounds={Desktop.WindowRectangle(new WindowInteropHelper(pin).Handle)}\n");
            };
            await Task.Delay(800); if (!pin.IsActive) throw new InvalidOperationException("钉图创建后未保持选中");
            File.WriteAllText(Path.Combine(profile, wheelReview ? "等待钉图滚轮.txt" : "等待钉图边缘.txt"), wheelReview
                ? "普通图直接滚轮缩放；长图普通滚轮翻看。创建继续钉图验收.txt 结束。"
                : "实际拖动边缘或角缩小。创建继续钉图验收.txt 结束。");
            for (var i = 0; i < 2400 && !File.Exists(Path.Combine(profile, "继续钉图验收.txt")); i++) await Task.Delay(100);
            var dpi = VisualTreeHelper.GetDpi(pin).DpiScaleX;
            File.WriteAllText(Path.Combine(profile, "钉图原生输入诊断.txt"), $"before={before}; after={pin.DebugZoom}; bounds={Desktop.WindowRectangle(new WindowInteropHelper(pin).Handle)}; DPI={dpi}");
            if (pin.DebugResizing || pin.IsMouseCaptured) throw new InvalidOperationException("钉图未释放捕获");
            if (wheelReview) {
                if (isLong ? scrollChanges == 0 || pin.DebugZoom != before : wheelChanges == 0) throw new InvalidOperationException("实际滚轮输入没有改变缩放或长图滚动位置");
                results.Add("通过  " + (isLong ? "长图实际滚轮翻看，缩放比例不变" : "普通钉图实际滚轮缩放"));
            } else {
                if (pin.DebugZoom >= before) throw new InvalidOperationException("边缘原生拖动没有缩小钉图");
                results.Add("通过  " + (isLong ? "长图" : "普通图") + "实际从边缘拖动缩小并松手");
            }
        }
        finally { pin.Close(); }
    }
}
#endif
