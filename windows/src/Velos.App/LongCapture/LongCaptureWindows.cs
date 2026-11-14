using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shell;
using Velos.Core.LongCapture;
using Velos.Screenshot;
using Velos.UI;
using Velos.Windows.Capture;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.LongCapture;

internal sealed class LongCaptureOverlay : Window
{
#if DEBUG
    internal bool DebugHintVisible => hint.Visibility == Visibility.Visible;
#endif
    private readonly Canvas artwork;
    private readonly Border hint;
    private readonly PixelRect screen;
    private readonly PixelRect area;
    private readonly double scale;

    public LongCaptureOverlay(PixelRect screen, PixelRect area, double scale)
    {
        this.screen = screen;
        this.area = area;
        this.scale = scale;
        Title = "Velos 长截图选区";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowActivated = false;
        ShowInTaskbar = false;
        Topmost = true;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        WindowStartupLocation = WindowStartupLocation.Manual;
        artwork = new Canvas { ClipToBounds = true };
        hint = new Border { Background = WarmTheme.Brush(46, 33, 26, 209), CornerRadius = new CornerRadius(12), Padding = new Thickness(18, 11, 18, 11),
            Child = new TextBlock { FontFamily = WarmTheme.Text, FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, TextWrapping = TextWrapping.Wrap, MaxWidth = 520 } };
        var canvas = new Grid { Children = { new Shade(screen, area, scale), artwork } };
        artwork.Children.Add(hint);
        Content = canvas;
        SetHint(null);
    }

    public void ShowOverlay()
    {
        var handle = new WindowInteropHelper(this).EnsureHandle();
        Desktop.MakeClickThrough(handle);
        Desktop.Position(handle, screen);
        Show();
        Desktop.Position(handle, screen);
        Desktop.ExcludeFromCapture(handle, true);
    }

    public void SetHint(string? text)
    {
        hint.Visibility = Visibility.Collapsed;
        if (text is null) return;
        ((TextBlock)hint.Child).Text = text;
        hint.Visibility = Visibility.Visible; hint.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var region = new Rect((area.Left - screen.Left) / scale, (area.Top - screen.Top) / scale, area.Width / scale, area.Height / scale);
        var usable = new Rect(8, 8, Math.Max(0, screen.Width / scale - 16), Math.Max(0, screen.Height / scale - 16));
        var size = hint.DesiredSize;
        if (size.Width > usable.Width || size.Height > usable.Height) { hint.Visibility = Visibility.Collapsed; return; }
        var x = Math.Clamp(region.Left + (region.Width - size.Width) / 2, usable.Left, usable.Right - size.Width);
        var y = Math.Clamp(region.Top + (region.Height - size.Height) / 2, usable.Top, usable.Bottom - size.Height);
        var candidates = new[] { new Rect(x, region.Top - 12 - size.Height, size.Width, size.Height),
            new Rect(region.Left - 12 - size.Width, y, size.Width, size.Height), new Rect(region.Right + 12, y, size.Width, size.Height) };
        var location = candidates.FirstOrDefault(candidate => usable.Contains(candidate));
        if (location.IsEmpty || location.Width == 0) { hint.Visibility = Visibility.Collapsed; return; }
        Canvas.SetLeft(hint, location.Left); Canvas.SetTop(hint, location.Top);
    }

    private sealed class Shade(PixelRect screen, PixelRect area, double scale) : FrameworkElement
    {
        private static readonly Brush Tint = WarmTheme.Brush(0, 0, 0, 82);

        protected override void OnRender(DrawingContext drawing)
        {
            var screenRect = new Rect(0, 0, screen.Width / scale, screen.Height / scale);
            var region = new Rect((area.Left - screen.Left) / scale, (area.Top - screen.Top) / scale,
                area.Width / scale, area.Height / scale);
            drawing.DrawGeometry(Tint, null, new CombinedGeometry(GeometryCombineMode.Exclude,
                new RectangleGeometry(screenRect), new RectangleGeometry(region)));
            // 边框完全在选区之外，即使分层遮罩无法设 WDA，选区里的像素也不会沾上颜色。
            region.Inflate(1, 1);
            drawing.DrawRectangle(null, new Pen(WarmTheme.Apricot, 2), region);
        }
    }
}

internal sealed class LongFloatingWindow : Window
{
    private readonly Border panel;
    private readonly bool clickThrough;
    private bool excluded;

    public LongFloatingWindow(string title, Border panel, bool clickThrough = false)
    {
        Title = title;
        this.panel = panel;
        this.clickThrough = clickThrough;
        panel.HorizontalAlignment = HorizontalAlignment.Stretch;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowActivated = false;
        ShowInTaskbar = false;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Background = CaptureChrome.Paper;
        Content = panel;
    }

    public bool Place(PixelRect bounds, int radius)
    {
        var handle = new WindowInteropHelper(this).EnsureHandle();
        if (clickThrough) Desktop.MakeClickThrough(handle);
        else Desktop.MakeNonActivating(handle);
        Desktop.Position(handle, bounds);
        if (!IsVisible)
        {
            Show();
            Desktop.Position(handle, bounds);
            if (!SystemParameters.HighContrast && Desktop.TryAcrylic(handle, WarmTheme.IsDark))
            {
                WindowChrome.SetWindowChrome(this, new WindowChrome
                {
                    GlassFrameThickness = new Thickness(-1), CaptionHeight = 0,
                    ResizeBorderThickness = new Thickness(0), CornerRadius = new CornerRadius(0)
                });
                if (HwndSource.FromHwnd(handle)?.CompositionTarget is { } target)
                    target.BackgroundColor = Colors.Transparent;
                Background = Brushes.Transparent;
                panel.Background = WarmTheme.Floating.Tint;
                Desktop.Position(handle, bounds);
            }
            excluded = Desktop.ExcludeFromCapture(handle, true);
        }
        Desktop.RoundWindow(handle, bounds.Width, bounds.Height, radius);
        return excluded;
    }
}

internal sealed class LongPreviewCanvas : FrameworkElement
{
    private BitmapSource? image;
    private ScrollAxis axis;

    public LongPreviewCanvas()
    {
        ClipToBounds = true;
        RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.HighQuality);
    }

    public void Update(BitmapSource? next, ScrollAxis direction)
    {
        image = next;
        axis = direction;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext drawing)
    {
        if (image is null || ActualWidth < 1 || ActualHeight < 1)
            return;
        var scale = axis == ScrollAxis.Vertical ? ActualWidth / image.PixelWidth : ActualHeight / image.PixelHeight;
        var width = image.PixelWidth * scale;
        var height = image.PixelHeight * scale;
        var x = axis == ScrollAxis.Horizontal ? Math.Min(0, ActualWidth - width) : 0;
        var y = axis == ScrollAxis.Vertical ? Math.Min(0, ActualHeight - height) : 0;
        drawing.PushClip(new RectangleGeometry(new Rect(0, 0, ActualWidth, ActualHeight), 7, 7));
        drawing.DrawImage(image, new Rect(x, y, width, height));
        drawing.Pop();
    }
}
