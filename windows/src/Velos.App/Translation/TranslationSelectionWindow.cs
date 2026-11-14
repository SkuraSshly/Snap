using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velos.Screenshot;
using Velos.Windows.Capture;
using Velos.UI;

namespace Velos.Translation;

internal sealed class TranslationSelectionWindow : Window
{
    private readonly Action placeHint;
    public Display Display { get; }
    public CaptureSurface Surface { get; }
    public TranslationSelectionWindow(Display display, BitmapSource photo, IReadOnlyList<System.Drawing.Rectangle> windows,
        Action<TranslationSelectionWindow> confirm, Action cancel)
    {
        Display = display; Title = "Velos 截屏翻译选区"; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false; Topmost = true; Background = Brushes.Black; WindowStartupLocation = WindowStartupLocation.Manual;
        Surface = new CaptureSurface(display, photo, windows, ToolInfo.Default, (_, _) => { }, selectionAccent: Velos.UI.WarmTheme.Brush(115, 179, 120));
        Surface.ShowMagnifier = false;
        DpiChanged += (_, _) => { if (IsLoaded && IsVisible) Dispatcher.BeginInvoke(cancel); };
        var hint = new ModeHint(); var chrome = new Canvas { Children = { hint } };
        Content = new Grid { Children = { Surface, chrome } };
        void PlaceHint()
        {
            hint.Visibility = Surface.Suppressed ? Visibility.Collapsed : Visibility.Visible;
            var key = ((App)Application.Current).Settings.Translation;
            if (Surface.FullScreen) hint.Set("全屏翻译", "Enter 识别整屏", key + " 切换区域", "Esc 取消");
            else hint.Set("截屏翻译", "框选文字或单击窗口", key + " 切换全屏", "Esc 取消");
            var avoid = !Surface.FullScreen && Surface.Region is { } area ? new Rect(area.X * Surface.ViewScale, area.Y * Surface.ViewScale, area.Width * Surface.ViewScale, area.Height * Surface.ViewScale) : Rect.Empty;
            hint.Place(chrome, avoid, Surface.PointerAvoid);
        }
        placeHint = PlaceHint;
        SizeChanged += (_, _) => PlaceHint(); MouseMove += (_, _) => PlaceHint(); Surface.SelectionChanged += PlaceHint;
        Surface.SelectionCommitted += () => { if (!Surface.FullScreen && Surface.Region is { Width: > 1, Height: > 1 }) confirm(this); };
        PreviewKeyDown += (_, e) =>
        {
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            if (e.IsRepeat && key is not (Key.Left or Key.Right or Key.Up or Key.Down)) { e.Handled = true; return; }
            if (key == Key.Escape) cancel(); else if (key == Key.Enter && Surface.Target is not null) confirm(this); else return; e.Handled = true;
        };
        MouseRightButtonUp += (_, _) => cancel();
        Closed += (_, _) => Desktop.ForgetScreenshotWindow(new WindowInteropHelper(this).Handle);
    }
    public void ShowOnDisplay()
    {
        var hwnd = new WindowInteropHelper(this).EnsureHandle(); Desktop.Position(hwnd, Display.Bounds); Show(); Desktop.Position(hwnd, Display.Bounds);
        Desktop.ExcludeForScreenshots(hwnd); var scale = VisualTreeHelper.GetDpi(this).DpiScaleX; Surface.PixelScale = scale; Surface.ViewScale = 1 / scale;
    }
    internal void SetSuppressed(bool value) { Surface.Suppress(value); placeHint(); }
}
