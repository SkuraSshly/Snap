using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velos.Core.Screenshot;
using Velos.Core.Settings;
using Velos.Windows.Capture;
using Velos.UI;
using PixelPoint = System.Drawing.Point;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.Screenshot;

internal sealed class CaptureWindow : Window
{
    private readonly MarkupToolbar toolbar;
    private readonly Canvas chrome = new();
    private readonly ModeHint hint;
    private readonly CornerRadiusControl cornerBar;
    private readonly Action<ShotAction> action;
    private readonly Func<string, bool> copyColor;

    public CaptureWindow(Display display, BitmapSource image, IReadOnlyList<PixelRect> windows,
        Func<Tool, ToolStyle> style, Action<Tool, ToolStyle> remember, Action<ShotAction> action, Func<string, bool> copyColor,
        double cornerRadius = 0, Action<double>? rememberCorner = null)
    {
        Display = display;
        this.action = action;
        this.copyColor = copyColor;
        Title = "Velos 截图";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.Manual;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Background = Brushes.Black;
        Surface = new CaptureSurface(display, image, windows, style, remember) { Cursor = Cursors.Cross };
        Surface.CornerRadius = cornerRadius;
        cornerBar = new CornerRadiusControl(Surface.CornerRadius, value => { Surface.CornerRadius = value; rememberCorner?.Invoke(value); });
        toolbar = new MarkupToolbar(Surface, action, () => Surface.Region is not null && !Surface.HasMarks);
        toolbar.MetricsChanged += UpdateChrome;
        hint = new ModeHint();
        hint.IsHitTestVisible = false;
        chrome.Children.Add(hint);
        chrome.Children.Add(toolbar);
        chrome.Children.Add(cornerBar);
        var layout = new Grid { Children = { Surface, chrome } };
        Content = layout;
        Surface.SelectionChanged += UpdateChrome;
        layout.SizeChanged += (_, _) => UpdateChrome();
        MouseMove += (_, _) => UpdateChrome();
        PreviewKeyDown += KeyDownInCapture;
        DpiChanged += (_, _) => { if (IsLoaded && IsVisible) Dispatcher.BeginInvoke(() => action(ShotAction.Cancel)); };
        MouseRightButtonUp += (_, e) =>
        {
            if (Surface.EditingText)
                return;
            e.Handled = true;
            if (Surface.CancelTool()) return;
            if (!Surface.FullScreen && Surface.Region is not null) { Surface.ClearRegion(); return; }
            action(ShotAction.Cancel);
        };
        Closed += (_, _) => Desktop.ForgetScreenshotWindow(new WindowInteropHelper(this).Handle);
    }

    public Display Display { get; }
    public CaptureSurface Surface { get; }

    public void ShowOnDisplay()
    {
        var handle = new WindowInteropHelper(this).EnsureHandle();
        if (!Desktop.Position(handle, Display.Bounds))
            throw new InvalidOperationException("无法将选区定位到目标显示器。");
        Show();
        if (!Desktop.Position(handle, Display.Bounds))
            throw new InvalidOperationException("无法将选区定位到目标显示器。");
        Desktop.ExcludeForScreenshots(handle);
        ApplyDpi();
        var pointer = Desktop.Pointer();
        Surface.SetPointer(new PixelPoint(pointer.X - Display.Bounds.X, pointer.Y - Display.Bounds.Y));
    }

    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        ApplyDpi();
    }

    private void ApplyDpi()
    {
        var dpi = VisualTreeHelper.GetDpi(Surface);
        Surface.PixelScale = dpi.DpiScaleX;
        Surface.ViewScale = 1 / dpi.DpiScaleX;
        UpdateChrome();
    }

    internal void SetSuppressed(bool value) { Surface.Suppress(value); UpdateChrome(); }
    private void UpdateChrome()
    {
        if (Surface.Suppressed) { toolbar.Visibility = hint.Visibility = cornerBar.Visibility = Visibility.Collapsed; return; }
        var width = chrome.ActualWidth;
        var height = chrome.ActualHeight;
        if (width < 1 || height < 1)
            return;
        var showToolbar = Surface.Region is not null && !Surface.IsSelecting;
        toolbar.Visibility = showToolbar ? Visibility.Visible : Visibility.Collapsed;
        cornerBar.Visibility = showToolbar && !Surface.FullScreen ? Visibility.Visible : Visibility.Collapsed;
        if (cornerBar.Visibility == Visibility.Visible && Surface.Region is { } area)
        {
            var label = Surface.SizeLabelBounds(area); var x = label.Right + 8; var y = label.Top - 2.5;
            if (x + 176 > width - 4) { x = label.Left; y = label.Bottom + 6; }
            Canvas.SetLeft(cornerBar, Math.Clamp(x, 4, Math.Max(4, width - 180)));
            Canvas.SetTop(cornerBar, Math.Clamp(y, 4, Math.Max(4, height - 30)));
        }
        hint.Visibility = Visibility.Visible;
        hint.Set(Surface.FullScreen ? "全屏截图" : "区域截图", ((App)Application.Current).Settings.Screenshot + (Surface.FullScreen ? " 切换区域" : " 切换全屏"), "Enter 完成", "Esc 取消");
        var avoid = !Surface.FullScreen && Surface.Region is { } chosen ? new Rect(chosen.X * Surface.ViewScale, chosen.Y * Surface.ViewScale, chosen.Width * Surface.ViewScale, chosen.Height * Surface.ViewScale) : Rect.Empty;
        if (!showToolbar)
        {
            hint.Place(chrome, avoid, Surface.PointerAvoid, Surface.MagnifierAvoid);
            return;
        }
        toolbar.MaxWidth = Math.Max(1, width - 8);
        toolbar.UpdateLongCapture();
        toolbar.Measure(new Size(toolbar.MaxWidth, double.PositiveInfinity));
        var size = toolbar.DesiredSize;
        System.Drawing.RectangleF? selection = null;
        if (!Surface.FullScreen && Surface.Region is { } region)
        {
            var factor = (float)Surface.ViewScale;
            selection = new System.Drawing.RectangleF(region.X * factor, region.Y * factor, region.Width * factor, region.Height * factor);
        }
        var position = ScreenshotLayout.ToolbarOrigin(new System.Drawing.SizeF((float)size.Width, (float)size.Height),
            selection, new System.Drawing.RectangleF(0, 0, (float)width, (float)height));
        Canvas.SetLeft(toolbar, position.X);
        Canvas.SetTop(toolbar, Math.Clamp(position.Y, 4, Math.Max(4, height - size.Height - 4)));
        hint.Place(chrome, avoid, new Rect(Canvas.GetLeft(toolbar), Canvas.GetTop(toolbar), size.Width, size.Height), Surface.PointerAvoid, Surface.MagnifierAvoid);
    }

    private void KeyDownInCapture(object sender, KeyEventArgs e)
    {
        if (toolbar.IsPickingColor || e.Key == Key.ImeProcessed) return;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var modifiers = Keyboard.Modifiers;
        if (e.IsRepeat && key is not (Key.Left or Key.Right or Key.Up or Key.Down)) { e.Handled = true; return; }
        if (Keyboard.FocusedElement is Slider && key is Key.Left or Key.Right or Key.Up or Key.Down or Key.Home or Key.End)
            return;
        if (Surface.HandleEditingKey(key, modifiers))
        {
            e.Handled = true;
            return;
        }
        if (Surface.EditingText && !(modifiers == ModifierKeys.Control && key == Key.S))
            return;
        if (modifiers == ModifierKeys.None && key == Key.Escape)
            action(ShotAction.Cancel);
        else if (modifiers == ModifierKeys.None && key == Key.Enter)
            action(ShotAction.Done);
        else if (modifiers == ModifierKeys.Control && key == Key.S)
            action(ShotAction.Save);
        else if (modifiers == ModifierKeys.Control && key == Key.C)
            action(ShotAction.Copy);
        else if (modifiers == ModifierKeys.None && key == Key.C && Surface.PointerColor() is { } color)
        { Surface.NotifyColorCopied(copyColor(color)); }
        else if (!Surface.Nudge(key, modifiers))
            return;
        e.Handled = true;
    }
#if DEBUG
    internal Slider DebugCornerSlider => cornerBar.DebugSlider;
    internal void DebugKey(Key key) => RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(this), Environment.TickCount, key) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
#endif
}
