using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace Velos.UI;

/// <summary>Mac HintBar 的模式名、操作说明与上下避让。</summary>
internal sealed class ModeHint : Border
{
    private readonly TextBlock text = new() { FontFamily = WarmTheme.Text, FontSize = 13 };
    private string? content;
    public ModeHint()
    {
        Background = WarmTheme.Floating.Surface; BorderBrush = WarmTheme.Floating.Outline; BorderThickness = new Thickness(.5);
        CornerRadius = new CornerRadius(22); Padding = new Thickness(18, 8, 18, 8); Child = text; IsHitTestVisible = false;
        if (!SystemParameters.HighContrast) Effect = new DropShadowEffect { Color = Color.FromRgb(64, 38, 20), BlurRadius = 14, ShadowDepth = 4, Opacity = .22 };
    }
    public void Set(string title, params string[] items)
    {
        var rest = string.Concat(items.Select(item => " · " + item));
        if (content == title + rest) return; content = title + rest;
        var ink = WarmTheme.Floating.Ink.Color;
        text.Inlines.Clear(); text.Inlines.Add(new Run(title) { FontWeight = FontWeights.SemiBold, Foreground = WarmTheme.Floating.Ink });
        text.Inlines.Add(new Run(rest) { FontWeight = FontWeights.Medium, Foreground = WarmTheme.Brush(ink.R, ink.G, ink.B, 166) });
    }
    public void Place(Canvas canvas, params Rect[] avoid)
    {
        if (canvas.ActualWidth < 1) return;
        Measure(new Size(Math.Max(1, canvas.ActualWidth - 8), double.PositiveInfinity));
        var frame = new Rect(Math.Max(4, (canvas.ActualWidth - DesiredSize.Width) / 2), 16, DesiredSize.Width, DesiredSize.Height);
        if (avoid.Any(area => { if (area.IsEmpty) return false; area.Inflate(12, 12); return area.IntersectsWith(frame); }))
            frame.Y = Math.Max(4, canvas.ActualHeight - 48 - frame.Height);
        Canvas.SetLeft(this, frame.X); Canvas.SetTop(this, frame.Y);
    }
}
