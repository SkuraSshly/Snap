using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Effects;
using Velos.UI;

namespace Velos.Screenshot;

internal sealed class CornerRadiusControl : Border
{
    private readonly Slider slider;
    public CornerRadiusControl(double radius, Action<double> changed)
    {
        Width = 176; Height = 26; CornerRadius = new CornerRadius(13); Padding = new Thickness(5, 0, 5, 0);
        Background = WarmTheme.Floating.Surface; BorderBrush = CaptureChrome.Line; BorderThickness = new Thickness(.5);
        if (!SystemParameters.HighContrast) Effect = new DropShadowEffect { Color = Color.FromRgb(64, 38, 20), BlurRadius = 8, ShadowDepth = 2, Opacity = .18 };
        var row = new DockPanel();
        TextBlock Label(string text) => new() { Text = text, Foreground = CaptureChrome.Ink, FontFamily = WarmTheme.Text, FontSize = 12,
            FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        var title = Label("圆角"); title.Margin = new Thickness(2, 0, 5, 0); DockPanel.SetDock(title, Dock.Left); row.Children.Add(title);
        var number = Label(radius == 0 ? "直角" : $"{radius:0}"); number.Width = 30; number.TextAlignment = TextAlignment.Right;
        Typography.SetNumeralAlignment(number, FontNumeralAlignment.Tabular); DockPanel.SetDock(number, Dock.Right); row.Children.Add(number);
        slider = new Slider { Minimum = 0, Maximum = 40, Value = radius, SmallChange = 1, LargeChange = 5, TickFrequency = 1,
            IsSnapToTickEnabled = true, IsMoveToPointEnabled = true, Style = CaptureChrome.SliderStyle, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(2, 0, 4, 0) };
        slider.Resources["CaptureDivider"] = WarmTheme.Floating.Divider;
        System.Windows.Automation.AutomationProperties.SetName(slider, "截图圆角");
        slider.ValueChanged += (_, _) => { number.Text = slider.Value < .5 ? "直角" : $"{slider.Value:0}"; changed(slider.Value); };
        row.Children.Add(slider); Child = row; ToolTip = "截图的圆角（0–40 点，可以在上面滚动微调）";
    }
#if DEBUG
    internal Slider DebugSlider => slider;
#endif
}
