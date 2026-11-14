using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Interop;
using Velos.Core.Screenshot;
using Velos.UI;
using Velos.Windows.Capture;

namespace Velos.Screenshot;

/// <summary>与 Mac 调色盘相同：实时 HSV、颜色代码、可选剪贴板颜色，关闭时保留已应用的修改。</summary>
internal sealed class AnnotationColorPicker : Popup
{
    private readonly TextBox code;
    private readonly Border preview;
    private readonly PaintField square;
    private readonly PaintField hueBar;
    private readonly Action<AnnotationColor> apply;
    private double hue, saturation, brightness;
    private bool syncing;

    public AnnotationColorPicker(FrameworkElement anchor, uint rgb, Action<AnnotationColor> apply, Func<string?>? clipboard = null)
    {
        this.apply = apply;
#if DEBUG
        // 自测仅使用合成内容，不读取用户剪贴板；显式提供的假剪贴板仍可验证按钮。
        if (clipboard is null && Environment.GetCommandLineArgs().Any(arg => arg == "--self-test" || arg.EndsWith("-self-test", StringComparison.Ordinal))) clipboard = () => null;
#endif
        PlacementTarget = anchor; Placement = PlacementMode.Top; VerticalOffset = -4;
        HorizontalOffset = -(244 - anchor.ActualWidth) / 2;
        AllowsTransparency = true; StaysOpen = false; PopupAnimation = PopupAnimation.Fade;
        SetRgb(rgb);
        square = new PaintField(204, 132, DrawSquare, p => { saturation = Math.Clamp(p.X / 204, 0, 1); brightness = 1 - Math.Clamp(p.Y / 132, 0, 1); Emit(); });
        hueBar = new PaintField(204, 14, DrawHue, p => { hue = Math.Clamp(p.X / 204, 0, 1); Emit(); }) { Margin = new Thickness(0, 10, 0, 12) };
        preview = new Border { Width = 26, Height = 26, CornerRadius = new CornerRadius(13), BorderThickness = new Thickness(1.5), BorderBrush = Brushes.White, Margin = new Thickness(0, 0, 8, 0) };
        code = new TextBox { FontFamily = WarmTheme.Text, FontWeight = FontWeights.SemiBold, FontSize = 13,
            Background = Brushes.Transparent, Foreground = CaptureChrome.Ink, BorderThickness = new Thickness(0), Padding = new Thickness(6, 3, 6, 3),
            ToolTip = "#FF5533、#F53、#RRGGBBAA、rgb(255,85,51)、rgba(255,85,51,0.5)" };
        System.Windows.Automation.AutomationProperties.SetName(code, "颜色代码");
        var field = new Border { CornerRadius = new CornerRadius(8), Background = WarmTheme.Floating.Hover, Child = code };
        var entry = new DockPanel { LastChildFill = true }; DockPanel.SetDock(preview, Dock.Left); entry.Children.Add(preview); entry.Children.Add(field);
        var content = new StackPanel { Children = { square, hueBar, entry } };
        AnnotationColor? clipboardColor = null;
        try { if ((clipboard?.Invoke() ?? (clipboard is null && Clipboard.ContainsText() ? Clipboard.GetText() : null)) is { Length: <= 40 } text) clipboardColor = AnnotationColorCode.Parse(text); }
        catch (System.Runtime.InteropServices.ExternalException) { }
        if (clipboardColor is { } saved && saved.Rgb != rgb)
        {
            var useClipboard = CaptureChrome.Button("使用剪贴板颜色 " + AnnotationColorCode.Hex(saved.Rgb), "使用剪贴板颜色", () => { ApplyCode(saved, true); IsOpen = false; });
            useClipboard.Height = 26; useClipboard.FontSize = 11; useClipboard.Margin = new Thickness(0, 8, 0, 0); content.Children.Add(useClipboard);
        }
        Child = new Border { Width = 228, Padding = new Thickness(12), Background = WarmTheme.Floating.Surface, BorderBrush = CaptureChrome.Line,
            BorderThickness = new Thickness(.5), CornerRadius = new CornerRadius(16), Margin = new Thickness(8), Child = content,
            Effect = SystemParameters.HighContrast ? null : new DropShadowEffect { Color = Color.FromRgb(64, 38, 20), BlurRadius = 12, ShadowDepth = 3, Opacity = .22 } };
        code.TextChanged += (_, _) => { if (!syncing && AnnotationColorCode.Parse(code.Text) is { } value) ApplyCode(value, false); };
        Child.PreviewKeyDown += (_, e) => { if (e.Key is Key.Escape or Key.Enter) { IsOpen = false; e.Handled = true; } };
        nint excluded = 0;
        if (Window.GetWindow(anchor) is CaptureWindow)
        {
            Opened += (_, _) => { if (PresentationSource.FromVisual(Child) is HwndSource source) { excluded = source.Handle; Desktop.ExcludeForScreenshots(excluded); } };
            Closed += (_, _) => { if (excluded != 0) Desktop.ForgetScreenshotWindow(excluded); };
        }
        Sync(true);
    }
    private void ApplyCode(AnnotationColor color, bool updateField) { SetRgb(color.Rgb); Sync(updateField); apply(color); }
    private void SetRgb(uint rgb)
    {
        var r = (rgb >> 16 & 255) / 255d; var g = (rgb >> 8 & 255) / 255d; var b = (rgb & 255) / 255d;
        var max = Math.Max(r, Math.Max(g, b)); var min = Math.Min(r, Math.Min(g, b)); var d = max - min;
        brightness = max; saturation = max == 0 ? 0 : d / max;
        hue = d == 0 ? 0 : ((max == r ? (g - b) / d : max == g ? (b - r) / d + 2 : (r - g) / d + 4) / 6 + 1) % 1;
    }
    private static Color Hsv(double h, double s, double v)
    {
        h = (h % 1) * 6; var c = v * s; var x = c * (1 - Math.Abs(h % 2 - 1)); var m = v - c;
        var (r, g, b) = (int)h switch { 0 => (c, x, 0d), 1 => (x, c, 0d), 2 => (0d, c, x), 3 => (0d, x, c), 4 => (x, 0d, c), _ => (c, 0d, x) };
        return Color.FromRgb((byte)Math.Round((r + m) * 255), (byte)Math.Round((g + m) * 255), (byte)Math.Round((b + m) * 255));
    }
    private uint Rgb { get { var c = Hsv(hue, saturation, brightness); return (uint)c.R << 16 | (uint)c.G << 8 | c.B; } }
    private void Emit() { Sync(true); apply(new AnnotationColor(Rgb, null)); }
    private void Sync(bool updateField)
    {
        syncing = true; preview.Background = new SolidColorBrush(Hsv(hue, saturation, brightness));
        if (updateField) code.Text = AnnotationColorCode.Hex(Rgb);
        syncing = false; square.InvalidateVisual(); hueBar.InvalidateVisual();
    }
    private void DrawSquare(DrawingContext dc, Size size)
    {
        var rect = new Rect(size); dc.PushClip(new RectangleGeometry(rect, 8, 8));
        dc.DrawRectangle(new SolidColorBrush(Hsv(hue, 1, 1)), null, rect);
        dc.DrawRectangle(new LinearGradientBrush(Colors.White, Colors.Transparent, 0), null, rect);
        dc.DrawRectangle(new LinearGradientBrush(Colors.Transparent, Colors.Black, 90), null, rect); dc.Pop();
        dc.DrawEllipse(null, new Pen(Brushes.Black, 3), new Point(saturation * size.Width, (1 - brightness) * size.Height), 5, 5);
        dc.DrawEllipse(null, new Pen(Brushes.White, 1.5), new Point(saturation * size.Width, (1 - brightness) * size.Height), 5, 5);
    }
    private void DrawHue(DrawingContext dc, Size size)
    {
        var gradient = new LinearGradientBrush { StartPoint = new Point(0, .5), EndPoint = new Point(1, .5) }; for (var i = 0; i <= 6; i++) gradient.GradientStops.Add(new GradientStop(Hsv(i == 6 ? 0 : i / 6d, 1, 1), i / 6d));
        dc.DrawRoundedRectangle(gradient, null, new Rect(size), 7, 7);
        dc.DrawEllipse(Brushes.White, new Pen(CaptureChrome.Line, 1), new Point(hue * size.Width, size.Height / 2), 7, 7);
    }
    private sealed class PaintField : FrameworkElement
    {
        private readonly Action<DrawingContext, Size> draw;
        private readonly Action<Point> change;
        public PaintField(double width, double height, Action<DrawingContext, Size> draw, Action<Point> change)
        { Width = width; Height = height; this.draw = draw; this.change = change; Cursor = Cursors.Hand; }
        protected override void OnRender(DrawingContext dc) => draw(dc, RenderSize);
        protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e) { CaptureMouse(); change(e.GetPosition(this)); e.Handled = true; }
        protected override void OnMouseMove(MouseEventArgs e) { if (IsMouseCaptured && e.LeftButton == MouseButtonState.Pressed) change(e.GetPosition(this)); }
        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e) { if (IsMouseCaptured) { change(e.GetPosition(this)); ReleaseMouseCapture(); e.Handled = true; } }
    }
#if DEBUG
    internal TextBox DebugCode => code;
#endif
}
