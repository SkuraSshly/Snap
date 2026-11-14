using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using Velos.Core.Screenshot;
using Velos.Core.Settings;
using Velos.Core.LongCapture;
using Velos.UI;
using Velos.Windows.Capture;
using PixelRect = System.Drawing.Rectangle;
using PixelSize = System.Drawing.SizeF;

namespace Velos.Screenshot;

internal sealed class EditorWindow : Window
{
    private readonly ShotImage image;
    private readonly MarkCanvas canvas;
    private readonly MarkupToolbar toolbar;
    private readonly ScrollViewer scroll;
    private readonly TextBlock zoomText, persistentZoom;
    private readonly Border zoomHud;
    private readonly DispatcherTimer zoomTimer = new() { Interval = TimeSpan.FromMilliseconds(1200) };
    private readonly Action<ShotImage, System.Windows.Media.Imaging.BitmapSource, ShotAction> output;
    private bool autoFit = true;
    private double zoom = 1;
    private double minimumZoom = .05;
    private FitAxis? fitAxis;

    public EditorWindow(ShotImage image, Func<Tool, ToolStyle> style, Action<Tool, ToolStyle> remember,
        Action<ShotImage, System.Windows.Media.Imaging.BitmapSource, ShotAction> output)
    {
        this.image = image;
        this.output = output;
        Title = "Velos 截图编辑";
        Width = 850;
        Height = 640;
        MinWidth = 400;
        MinHeight = 220;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Icon = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/Assets/Velos.ico"));
        Background = WarmTheme.IsDark ? WarmTheme.Brush(41, 33, 28) : WarmTheme.Brush(232, 219, 204);
        UseLayoutRounding = true; SnapsToDevicePixels = true;
        canvas = new MarkCanvas(ShotEncoding.Decode(image.Png), image.Scale, style, remember)
        {
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
        };
        // 整图 Effect 会再次把分块内容合成到离屏纹理；大图不能套整图阴影。
        var smallImage = image.LongAxis is null && Math.Max(image.Width, image.Height) <= 4096;
        var art = new Border
        {
            Child = new Border { Child = canvas, Effect = smallImage ? new DropShadowEffect { BlurRadius = 3, ShadowDepth = 1, Opacity = .26, Color = Color.FromRgb(56, 33, 18) } : null },
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Effect = smallImage ? new DropShadowEffect { BlurRadius = 18, ShadowDepth = 5, Opacity = .18, Color = Color.FromRgb(56, 33, 18) } : null
        };
        var photo = new Border { Child = art, Padding = new Thickness(30) };
        scroll = new ScrollViewer
        {
            Content = photo, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            Style = CaptureChrome.OverlayScrollStyle,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(10, 6, 10, 0)
        };
        scroll.ScrollChanged += (_, e) =>
        {
            if (autoFit && (e.ViewportHeightChange != 0 || e.ViewportWidthChange != 0))
                ApplyFit();
        };
        scroll.PreviewMouseWheel += (_, e) =>
        {
            if ((Keyboard.Modifiers & (ModifierKeys.Alt | ModifierKeys.Control)) == 0)
                return;
            ChangeZoom(zoom * Math.Pow(1.15, e.Delta / 120d), e.GetPosition(scroll));
            e.Handled = true;
        };
        scroll.IsManipulationEnabled = true;
        scroll.ManipulationStarting += (_, e) => e.Mode = ManipulationModes.Scale;
        scroll.ManipulationDelta += (_, e) =>
        {
            var factor = e.DeltaManipulation.Scale.X;
            if (factor > 0 && Math.Abs(factor - 1) > 0.001)
                ChangeZoom(zoom * factor, e.ManipulationOrigin);
        };
        toolbar = new MarkupToolbar(canvas, Perform) { HorizontalAlignment = HorizontalAlignment.Center };
        canvas.SelectTool(Tool.Rectangle);
        zoomText = new TextBlock
        {
            Text = "100%", Foreground = Brushes.White, FontSize = 13, FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center
        };
        zoomHud = new Border { Child = zoomText, Background = WarmTheme.Brush(46, 33, 26, 204), CornerRadius = new CornerRadius(11),
            Padding = new Thickness(11, 2, 11, 2), MinWidth = 64, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 10, 0, 0), IsHitTestVisible = false, Opacity = 0 };
        var footer = new Grid { Height = 142, Margin = new Thickness(8, 0, 8, 0) };
        footer.RowDefinitions.Add(new RowDefinition { Height = new GridLength(36) }); footer.RowDefinitions.Add(new RowDefinition());
        Grid.SetRow(toolbar, 1); footer.Children.Add(toolbar); toolbar.VerticalAlignment = VerticalAlignment.Bottom; toolbar.Margin = new Thickness(0, 0, 0, 16);
        persistentZoom = new TextBlock { Text = "100%", FontFamily = WarmTheme.Text, FontSize = 11, Foreground = CaptureChrome.Ink, VerticalAlignment = VerticalAlignment.Center, MinWidth = 42, TextAlignment = TextAlignment.Right, Margin = new Thickness(8, 0, 8, 0) };
        var native = CaptureChrome.Button("100% 原像素", "一个图片像素对应一个屏幕像素（Ctrl+1）", () => ChangeZoom(1, new Point(scroll.ActualWidth / 2, scroll.ActualHeight / 2)));
        var fit = CaptureChrome.Button("适合窗口", "按图片方向适合窗口（Ctrl+0）", () => { autoFit = true; ApplyFit(); });
        foreach (var button in new[] { native, fit }) { button.Height = 24; button.Resources["CaptureRadius"] = new CornerRadius(8); button.FocusVisualStyle = CaptureChrome.RectFocus; }
        var viewControls = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 8, 0, 0) };
        viewControls.Children.Add(new TextBlock { Text = $"{image.Width:N0} × {image.Height:N0} 像素", FontFamily = WarmTheme.Text, FontSize = 11, Foreground = CaptureChrome.Ink, Opacity = .65, VerticalAlignment = VerticalAlignment.Center });
        viewControls.Children.Add(persistentZoom); viewControls.Children.Add(native); viewControls.Children.Add(fit); footer.Children.Add(viewControls);
        DockPanel.SetDock(footer, Dock.Bottom);
        Content = new Grid { Background = Background, Children = { new DockPanel { Children = { footer, scroll } }, zoomHud } };
        zoomTimer.Tick += (_, _) => { zoomTimer.Stop(); WarmMotion.Fade(zoomHud, 0, 300); };
        Closed += (_, _) => zoomTimer.Stop();
        PreviewKeyDown += EditorKey;
        Loaded += (_, _) =>
        {
            var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX; var work = image.Display.WorkArea;
            toolbar.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            MinWidth = Math.Min(work.Width / dpi, Math.Max(560, toolbar.DesiredSize.Width + 32));
            Width = Math.Min(work.Width / dpi * .9, Math.Max(MinWidth, image.Width / image.Scale + 80));
            var desiredHeight = Math.Min(work.Height / dpi * .9, Math.Max(220, image.Height / image.Scale + 142 + 88));
            MinHeight = Math.Min(desiredHeight, 321); Height = desiredHeight;
            Desktop.Position(new WindowInteropHelper(this).Handle, new PixelRect((int)(work.X + (work.Width - Width * dpi) / 2), (int)(work.Y + (work.Height - Height * dpi) / 2), (int)(Width * dpi), (int)(Height * dpi)));
            ApplyFit();
        };
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        if (autoFit) ApplyFit();
        else ResizeCanvas(zoom);
    }

    private void ApplyFit()
    {
        if (!IsLoaded || scroll.ViewportWidth <= 60 || scroll.ViewportHeight <= 60) return;
        var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var viewport = new PixelSize((float)Math.Max(1, (scroll.ViewportWidth - 60) * dpi), (float)Math.Max(1, (scroll.ViewportHeight - 60) * dpi));
        var full = new PixelSize(image.Width, image.Height);
        fitAxis ??= ScreenshotLayout.EditorFitAxis(full, viewport);
        minimumZoom = Math.Min(1, ScreenshotLayout.FitScale(full, viewport));
        ResizeCanvas(Math.Min(1, ScreenshotLayout.FitScale(full, viewport, fitAxis.Value)));
    }

    private void ResizeCanvas(double value)
    {
        zoom = value;
        canvas.ViewScale = zoom / VisualTreeHelper.GetDpi(this).DpiScaleX;
        canvas.Width = image.Width * canvas.ViewScale;
        canvas.Height = image.Height * canvas.ViewScale;
        zoomText.Text = $"{Math.Round(zoom * 100):0}%";
        persistentZoom.Text = zoomText.Text;
        RenderOptions.SetBitmapScalingMode(canvas, zoom < 1 ? BitmapScalingMode.HighQuality : BitmapScalingMode.NearestNeighbor);
        WarmMotion.Fade(zoomHud, 1, 0); zoomTimer.Stop(); zoomTimer.Start();
    }

    private void ChangeZoom(double target, Point anchor)
    {
        var oldScale = canvas.ViewScale;
        var at = scroll.TranslatePoint(anchor, canvas);
        autoFit = false;
        ResizeCanvas(Math.Clamp(target, Math.Min(minimumZoom, 4), 4));
        scroll.UpdateLayout();
        var factor = canvas.ViewScale / oldScale;
        var updated = canvas.TranslatePoint(new Point(at.X * factor, at.Y * factor), scroll);
        scroll.ScrollToHorizontalOffset(scroll.HorizontalOffset + updated.X - anchor.X);
        scroll.ScrollToVerticalOffset(scroll.VerticalOffset + updated.Y - anchor.Y);
    }

    private void EditorKey(object sender, KeyEventArgs e)
    {
        if (toolbar.IsPickingColor || e.Key == Key.ImeProcessed) return;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (e.IsRepeat && key is not (Key.Left or Key.Right or Key.Up or Key.Down)) { e.Handled = true; return; }
        var modifiers = Keyboard.Modifiers;
        if (Keyboard.FocusedElement is Slider && key is Key.Left or Key.Right or Key.Up or Key.Down or Key.Home or Key.End)
            return;
        if (canvas.HandleEditingKey(key, modifiers))
        {
            e.Handled = true;
            return;
        }
        if (canvas.EditingText && !(key == Key.S && modifiers == ModifierKeys.Control))
            return;
        if (key == Key.OemPlus && modifiers == (ModifierKeys.Control | ModifierKeys.Shift))
            ChangeZoom(zoom * 1.25, new Point(scroll.ActualWidth / 2, scroll.ActualHeight / 2));
        else if (modifiers == ModifierKeys.Control)
        {
            var center = new Point(scroll.ActualWidth / 2, scroll.ActualHeight / 2);
            switch (key)
            {
                case Key.S: Perform(ShotAction.Save); break;
                case Key.C: Perform(ShotAction.Copy); break;
                case Key.OemPlus:
                case Key.Add: ChangeZoom(zoom * 1.25, center); break;
                case Key.OemMinus:
                case Key.Subtract: ChangeZoom(zoom * .8, center); break;
                case Key.W: Close(); break;
                case Key.D1:
                case Key.NumPad1: ChangeZoom(1, center); break;
                case Key.D0:
                case Key.NumPad0:
                    autoFit = true;
                    ApplyFit();
                    break;
                default: return;
            }
        }
        else if (key == Key.Enter && modifiers == ModifierKeys.None)
            Perform(ShotAction.Done);
        else if (key == Key.Escape && modifiers == ModifierKeys.None)
            Close();
        else
            return;
        e.Handled = true;
    }

    private void Perform(ShotAction action)
    {
        if (action == ShotAction.Cancel)
        {
            Close();
            return;
        }
        var result = canvas.RenderCrop(new PixelRect(0, 0, image.Width, image.Height));
        Close();
        output(image, result, action);
    }

#if DEBUG
    internal bool DebugZoomHudVisible => zoomHud.Opacity > .01;
    internal bool DebugZoomTimerRunning => zoomTimer.IsEnabled;
    internal MarkCanvas DebugCanvas => canvas;
    internal void DebugPerform(ShotAction action) => Perform(action);
    internal double DebugZoom => zoom;
    internal void DebugZoomTo(double value) => ChangeZoom(value, new Point(scroll.ActualWidth / 2, scroll.ActualHeight / 2));
#endif
}
