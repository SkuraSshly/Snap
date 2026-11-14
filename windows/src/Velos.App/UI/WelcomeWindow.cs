using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using Velos.Screenshot;
using Velos.Windows.Capture;

namespace Velos.UI;

internal sealed class WelcomeWindow : Window
{
    public WelcomeWindow(Action settings)
    {
        Title = "欢迎使用 Velos"; Width = 500; Height = 500; ResizeMode = ResizeMode.NoResize;
        WindowStyle = WindowStyle.None; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = WarmTheme.Text; Foreground = WarmTheme.Floating.Ink; Background = WarmTheme.Floating.Paper;
        WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 34, GlassFrameThickness = new Thickness(0), ResizeBorderThickness = new Thickness(0), CornerRadius = new CornerRadius(20), UseAeroCaptionButtons = false });
        var stack = new StackPanel { Margin = new Thickness(30, 30, 30, 24) };
        stack.Children.Add(new Image { Source = WarmTheme.Image("wordmark-3x"), Height = 60, Width = 146, Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left });
        stack.Children.Add(new TextBlock { Text = "让灵感，轻快落下。", FontSize = 25, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 12, 0, 8) });
        stack.Children.Add(new TextBlock { Text = "截图、标注、长截图、录屏和截屏翻译。\nVelos 会留在托盘，随时等你按下快捷键。", FontSize = 13, LineHeight = 22 });
        foreach (var (key, text) in new[] { ("Alt+A", "截图 · 再按一次切换全屏"), ("Alt+S", "录屏 · 系统声音与麦克风"), ("Alt+D", "截屏翻译 · 先在本机识别文字") })
        {
            var row = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
            row.Children.Add(new Border { Width = 78, CornerRadius = new CornerRadius(7), Background = WarmTheme.Floating.Hover, Padding = new Thickness(8, 5, 8, 5), Child = new TextBlock { Text = key, FontWeight = FontWeights.SemiBold } });
            row.Children.Add(new TextBlock { Text = text, Margin = new Thickness(14, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center }); stack.Children.Add(row);
        }
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 24, 0, 0) };
        actions.Children.Add(CaptureChrome.Button("设置…", "自定义快捷键与偏好", () => { Close(); settings(); }));
        var done = CaptureChrome.IconButton("\ue73e", "开始使用", Close, "开始使用"); actions.Children.Add(done); stack.Children.Add(actions);
        var close = CaptureChrome.IconButton("\ue711", "关闭欢迎页", Close); close.HorizontalAlignment = HorizontalAlignment.Right; close.VerticalAlignment = VerticalAlignment.Top; close.Margin = new Thickness(0, 6, 6, 0);
        WindowChrome.SetIsHitTestVisibleInChrome(close, true);
        var root = new Grid { Background = WarmTheme.Floating.Surface, Children = { stack, close } }; Content = root;
        Loaded += (_, _) =>
        {
            var dpi = VisualTreeHelper.GetDpi(this); root.Clip = new RectangleGeometry(new Rect(0, 0, ActualWidth, ActualHeight), 20, 20);
            Desktop.RoundWindow(new WindowInteropHelper(this).Handle, (int)Math.Round(ActualWidth * dpi.DpiScaleX), (int)Math.Round(ActualHeight * dpi.DpiScaleY), (int)Math.Round(20 * dpi.DpiScaleX));
        };
    }
}
