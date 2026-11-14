using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using Velos.Screenshot;

namespace Velos.UI;

/// <summary>对应 Mac WarmSegmented：共用轨道，杏色选中块在选项间滑动。</summary>
internal sealed class WarmSegments<T> : Grid
{
    private readonly IReadOnlyList<(T Value, string Text)> choices;
    private readonly Func<T> read;
    private readonly List<Button> buttons = [];
    private readonly TranslateTransform selection = new();
    private readonly double segmentWidth;

    public WarmSegments(IReadOnlyList<(T Value, string Text)> choices, Func<T> read, Action<T> choose, double segmentWidth = 62, Func<T, bool>? available = null)
    {
        this.choices = choices; this.read = read; this.segmentWidth = segmentWidth;
        Width = choices.Count * segmentWidth; Height = 26; VerticalAlignment = VerticalAlignment.Center;
        UseLayoutRounding = true; SnapsToDevicePixels = true;
        Children.Add(new Border { Background = WarmTheme.IsDark ? WarmTheme.Brush(255, 230, 204, 33) : WarmTheme.Brush(115, 84, 56, 31), CornerRadius = new CornerRadius(13), IsHitTestVisible = false });
        Children.Add(new Border { Width = segmentWidth - 4, Height = 22, Margin = new Thickness(2), HorizontalAlignment = HorizontalAlignment.Left,
            CornerRadius = new CornerRadius(11), IsHitTestVisible = false, RenderTransform = selection,
            Background = new LinearGradientBrush(Color.FromArgb(224, 245, 148, 92), Color.FromRgb(245, 148, 92), 90),
            Effect = SystemParameters.HighContrast ? null : new DropShadowEffect { Color = Color.FromRgb(245, 148, 92), BlurRadius = 6, ShadowDepth = 1, Opacity = .4 } });
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (value, text) in choices)
        {
            var button = CaptureChrome.Button(text, text, () => { choose(value); Refresh(); });
            button.IsEnabled = available?.Invoke(value) ?? true;
            if (!button.IsEnabled) { button.ToolTip = "当前系统不支持此选项"; ToolTipService.SetShowOnDisabled(button, true); }
            button.Width = segmentWidth; button.MinWidth = 0; button.Height = 26; button.Padding = button.Margin = new Thickness(0);
            button.Background = Brushes.Transparent; button.Resources["CaptureRadius"] = new CornerRadius(13); button.FocusVisualStyle = CaptureChrome.MenuFocus;
            buttons.Add(button); row.Children.Add(button);
        }
        Children.Add(row); Refresh(false);
    }

    public void Refresh(bool animate = true)
    {
        var index = 0;
        for (var i = 0; i < choices.Count; i++) if (EqualityComparer<T>.Default.Equals(choices[i].Value, read())) { index = i; break; }
        WarmMotion.SelectNavigation(selection, index * segmentWidth, animate && IsLoaded, horizontal: true);
        for (var i = 0; i < buttons.Count; i++)
        {
            buttons[i].Foreground = i == index ? Brushes.White : WarmTheme.Floating.Ink;
            buttons[i].FontWeight = i == index ? FontWeights.SemiBold : FontWeights.Medium;
            AutomationProperties.SetItemStatus(buttons[i], i == index ? "已选中" : "未选中");
        }
    }
}
