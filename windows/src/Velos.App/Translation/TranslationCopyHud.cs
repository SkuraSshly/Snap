using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Velos.Screenshot;
using Velos.UI;
using Velos.Windows.Capture;

namespace Velos.Translation;

internal sealed class TranslationCopyHud : Window
{
    private readonly DispatcherTimer lifetime = new() { Interval = TimeSpan.FromMilliseconds(1300) };
    public TranslationCopyHud(Window owner, string message)
    {
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; AllowsTransparency = true;
        ShowActivated = false; ShowInTaskbar = false; Topmost = true; Background = Brushes.Transparent; SizeToContent = SizeToContent.WidthAndHeight;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Content = new Border { CornerRadius = new CornerRadius(12), Background = WarmTheme.Brush(46, 33, 26, 225), Padding = new Thickness(13, 9, 13, 9),
            Child = new StackPanel { Orientation = Orientation.Horizontal, Children = {
                new ActionIconView(ActionIcon.Check, 15) { Ink = Brushes.White, Margin = new Thickness(0, 0, 7, 0) },
                new TextBlock { Text = message, FontFamily = WarmTheme.Text, FontSize = 12, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap, MaxWidth = 330 } } } };
        var handle = new WindowInteropHelper(this).EnsureHandle(); var center = owner.PointToScreen(new Point(owner.ActualWidth / 2, owner.ActualHeight));
        Desktop.MakeClickThrough(handle); Show(); UpdateLayout();
        var scale = VisualTreeHelper.GetDpi(this).DpiScaleX; var width = (int)Math.Ceiling(ActualWidth * scale); var height = (int)Math.Ceiling(ActualHeight * scale);
        var displays = Desktop.Displays();
        var work = (displays.FirstOrDefault(display => display.Bounds.Contains((int)center.X, (int)center.Y - 1)) ??
            displays.OrderBy(display => Math.Abs(display.Bounds.Left + display.Bounds.Width / 2d - center.X) + Math.Abs(display.Bounds.Top + display.Bounds.Height / 2d - center.Y)).First()).WorkArea;
        Desktop.Position(handle, new System.Drawing.Rectangle(Math.Clamp((int)center.X - width / 2, work.Left, Math.Max(work.Left, work.Right - width)),
            Math.Clamp((int)center.Y + 8, work.Top, Math.Max(work.Top, work.Bottom - height)), width, height));
        Desktop.ExcludeForScreenshots(handle);
        lifetime.Tick += (_, _) => { lifetime.Stop(); Close(); }; lifetime.Start(); Closed += (_, _) => { lifetime.Stop(); Desktop.ForgetScreenshotWindow(handle); };
    }
}
