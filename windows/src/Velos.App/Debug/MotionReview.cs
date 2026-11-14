#if DEBUG
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using Shape = System.Windows.Shapes.Shape;

namespace Velos;

public partial class App
{
    private async Task VerifyNativeMotion(SettingsWindow window, string profile, Action<bool, string> check)
    {
        window.Title = "Velos 动效验收";
        var login = (CheckBox)window.FindName("LoginSwitch"); var trayToggle = (CheckBox)window.FindName("TraySwitch");
        var clicks = 0; var keys = 0;
        login.PreviewMouseLeftButtonDown += (_, _) => clicks++;
        trayToggle.PreviewMouseLeftButtonDown += (_, _) => clicks++;
        window.PreviewKeyDown += (_, _) => keys++;
        trayToggle.IsChecked = false; await Task.Delay(600); trayToggle.IsChecked = true;
        var clock = Stopwatch.StartNew();
        foreach (var sample in new[] { 20, 65, 120, 200, 550 }) {
            var wait = sample - (int)clock.ElapsedMilliseconds; if (wait > 0) await Task.Delay(wait);
            WriteSettingsImage(window, Path.Combine(profile, $"开关-{sample:000}ms.png"));
        }
        login.Focus();
        File.WriteAllText(Path.Combine(profile, "等待动效验收.txt"), "实际点击开关，Tab 切换焦点，空格切换；创建继续动效验收.txt 完成。");
        for (var i = 0; i < 1800 && !File.Exists(Path.Combine(profile, "继续动效验收.txt")); i++) await Task.Delay(100);
        await Task.Delay(600);
        check(clicks > 0 && keys > 0, "原生鼠标和键盘实际操作设置开关");
        foreach (var toggle in new[] { login, trayToggle }) {
            check(ReferenceEquals(toggle.FocusVisualStyle, window.FindResource("SwitchKeyboardFocus")), "原生开关使用圆润暖色焦点样式");
            var knob = (FrameworkElement)toggle.Template.FindName("Knob", toggle);
            var translation = (TranslateTransform)knob.RenderTransform;
            check(translation.X == (toggle.IsChecked == true ? 15 : 0) && !translation.HasAnimatedProperties, "原生切换后圆钮准确归位且无残留动画");
        }
        var layer = AdornerLayer.GetAdornerLayer(login);
        if (layer is not null) check(!HasDashedShape(layer), "实际键盘焦点装饰层没有黑色虚线框");
        WriteSettingsImage(window, Path.Combine(profile, "原生输入后.png"));
        window.Close();
    }
    private static bool HasDashedShape(DependencyObject visual)
    {
        if (visual is Shape { StrokeDashArray.Count: > 0 }) return true;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(visual); i++) if (HasDashedShape(VisualTreeHelper.GetChild(visual, i))) return true;
        return false;
    }
}
#endif
