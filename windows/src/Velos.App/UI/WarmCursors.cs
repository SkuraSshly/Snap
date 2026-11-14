using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Velos.Windows.Capture;
using ShapePath = System.Windows.Shapes.Path;

namespace Velos.UI;

/// <summary>移植 Mac 2.2 WarmCursors 的原创几何；每个 DPI、方向和深浅状态独立栅格化并按需缓存。</summary>
public static class WarmCursors
{
    private sealed record Entry(Cursor Cursor, NativeCursor Handle);
    private static readonly Dictionary<(int Dpi, int Direction, bool Outward, bool Move), Entry> cache = [];
    private sealed record Part(Geometry Shape, Brush Fill, Brush Edge);
    private static readonly Brush edge = WarmTheme.Brush(204, 107, 56), pale = WarmTheme.Brush(252, 214, 186), paleEdge = WarmTheme.Brush(230, 168, 133);
    internal static Cursor Move(Visual visual) => Get(visual, 0, false, true);
    internal static Cursor Resize(Visual visual, Vector direction, bool outward = true)
    {
        var octant = ((int)Math.Round(Math.Atan2(direction.Y, direction.X) / (Math.PI / 4), MidpointRounding.AwayFromZero) + 8) % 8;
        return Get(visual, octant, outward, false);
    }
    private static Cursor Get(Visual visual, int direction, bool outward, bool move)
    {
        var dpi = (int)Math.Round(VisualTreeHelper.GetDpi(visual).PixelsPerInchX);
        return Get(dpi, direction, outward, move);
    }
    private static Cursor Get(int dpi, int direction, bool outward, bool move)
    {
        var key = (dpi, direction, outward, move);
        if (!cache.TryGetValue(key, out var entry))
        {
            var bitmap = Raster(dpi / 96d, direction, outward, move);
            var pixels = new byte[bitmap.PixelWidth * bitmap.PixelHeight * 4]; bitmap.CopyPixels(pixels, bitmap.PixelWidth * 4, 0);
            var native = NativeCursor.Create(pixels, bitmap.PixelWidth, bitmap.PixelHeight, bitmap.PixelWidth / 2, bitmap.PixelHeight / 2);
            try { entry = new Entry(CursorInteropHelper.Create(native), native); cache.Add(key, entry); }
            catch { native.Dispose(); throw; }
        }
        return entry.Cursor;
    }
    private static Geometry Polygon(IEnumerable<Point> points)
    {
        var all = points.ToArray(); var geometry = new StreamGeometry();
        using (var dc = geometry.Open()) { dc.BeginFigure(all[0], true, true); foreach (var p in all.Skip(1)) dc.LineTo(p, true, false); }
        geometry.Freeze(); return geometry;
    }
    private static Canvas Art(int direction, bool outward, bool move)
    {
        var parts = new List<Part>();
        Point P(double angle, double along, double side) => new(13 + Math.Cos(angle) * along - Math.Sin(angle) * side, 13 + Math.Sin(angle) * along + Math.Cos(angle) * side);
        if (move)
        {
            var group = new GeometryGroup();
            for (var k = 0; k < 4; k++)
            {
                var a = k * Math.PI / 2;
                group.Children.Add(Polygon([P(a, 0, -.85), P(a, 7.9, -.85), P(a, 7.9, .85), P(a, 0, .85)]));
                group.Children.Add(Polygon([P(a, 11.2, 0), P(a, 7.4, -3.1), P(a, 7.4, 3.1)]));
            }
            Geometry merged = Geometry.Empty;
            foreach (var shape in group.Children) merged = Geometry.Combine(merged, shape, GeometryCombineMode.Union, null);
            parts.Add(new Part(merged, WarmTheme.Apricot, edge));
        }
        else
        {
            var angle = direction * Math.PI / 4;
            foreach (var sign in new[] { 1, -1 })
                parts.Add(new Part(Polygon([P(angle, sign * 9.4, 0), P(angle, sign * 2.2, -3.3), P(angle, sign * 2.2, 3.3)]),
                    sign == 1 || !outward ? WarmTheme.Apricot : pale, sign == 1 || !outward ? edge : paleEdge));
        }
        var result = new Canvas { Width = 26, Height = 26 };
        var outline = new GeometryGroup(); foreach (var part in parts) outline.Children.Add(part.Shape);
        result.Children.Add(new ShapePath { Data = outline, Stroke = Brushes.White, StrokeThickness = 2.6, StrokeLineJoin = PenLineJoin.Round,
            Effect = new DropShadowEffect { Color = Colors.Black, Opacity = .38, BlurRadius = 1.8, ShadowDepth = .6, Direction = 270 } });
        foreach (var part in parts) result.Children.Add(new ShapePath { Data = part.Shape, Fill = part.Fill, Stroke = part.Edge, StrokeThickness = .7, StrokeLineJoin = PenLineJoin.Round });
        if (move)
        {
            foreach (var (size, brush) in new[] { (5.2, Brushes.White as Brush), (3.4, WarmTheme.Brush(84, 61, 46) as Brush) })
            { var circle = new Ellipse { Width = size, Height = size, Fill = brush }; Canvas.SetLeft(circle, 13 - size / 2); Canvas.SetTop(circle, 13 - size / 2); result.Children.Add(circle); }
        }
        result.Measure(new Size(26, 26)); result.Arrange(new Rect(0, 0, 26, 26)); result.UpdateLayout(); return result;
    }
    private static RenderTargetBitmap Raster(double scale, int direction, bool outward, bool move)
    {
        var result = new RenderTargetBitmap((int)Math.Ceiling(26 * scale), (int)Math.Ceiling(26 * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
        result.Render(Art(direction, outward, move)); result.Freeze(); return result;
    }
    internal static void DisposeCache() { foreach (var value in cache.Values) { value.Cursor.Dispose(); value.Handle.Dispose(); } cache.Clear(); }

    public static readonly DependencyProperty SliderProperty = DependencyProperty.RegisterAttached("Slider", typeof(bool), typeof(WarmCursors), new PropertyMetadata(false, EnableSlider));
    public static void SetSlider(DependencyObject target, bool value) => target.SetValue(SliderProperty, value);
    public static bool GetSlider(DependencyObject target) => (bool)target.GetValue(SliderProperty);
    private static void EnableSlider(DependencyObject target, DependencyPropertyChangedEventArgs e)
    {
        if (target is not Slider slider || e.NewValue is not true) return;
        void UpdateCursor(object? _, MouseEventArgs args)
        {
            slider.ApplyTemplate();
            var track = slider.Template.FindName("PART_Track", slider) as Track;
            var thumb = track?.Thumb; var at = args.GetPosition(slider);
            var near = thumb is not null && new Rect(thumb.TranslatePoint(new Point(-4, -4), slider), new Size(thumb.ActualWidth + 8, thumb.ActualHeight + 8)).Contains(at);
            slider.Cursor = slider.IsMouseCaptureWithin || near ? Resize(slider, new Vector(1, 0), false) : Cursors.Arrow;
        }
        slider.PreviewMouseMove += UpdateCursor;
        slider.PreviewMouseLeftButtonDown += (_, _) => slider.Cursor = Resize(slider, new Vector(1, 0), false);
        slider.PreviewMouseWheel += (_, args) => { if (args.Delta == 0) return; slider.Value = Math.Clamp(slider.Value + Math.Sign(args.Delta) * slider.SmallChange, slider.Minimum, slider.Maximum); args.Handled = true; };
    }
#if DEBUG
    internal static BitmapSource DebugRaster(double scale, int direction, bool outward, bool move) => Raster(scale, direction, outward, move);
    internal static bool DebugNative(double scale)
    {
        var dpi = (int)Math.Round(scale * 96);
        var first = Get(dpi, 0, false, true);
        for (var direction = 0; direction < 8; direction++) { Get(dpi, direction, true, false); Get(dpi, direction, false, false); }
        return ReferenceEquals(first, Get(dpi, 0, false, true)) && cache.Where(pair => pair.Key.Dpi == dpi).All(pair => !pair.Value.Handle.IsInvalid && !pair.Value.Handle.IsClosed);
    }
#endif
}
