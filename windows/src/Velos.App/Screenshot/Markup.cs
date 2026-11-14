using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velos.Core.Screenshot;
using Velos.Core.Settings;

namespace Velos.Screenshot;

internal enum Tool { Rectangle, Ellipse, Arrow, Line, Pen, Highlighter, Text, Counter, Mosaic, Blur }

internal sealed record ToolInfo(string Name, string Glyph, string SizeLabel, int Min, int Max, int DefaultSize)
{
    public static ToolInfo For(Tool tool) => tool switch
    {
        Tool.Rectangle => new("矩形", "\ue739", "粗细", 1, 30, 4),
        Tool.Ellipse => new("椭圆", "\uea3a", "粗细", 1, 30, 4),
        Tool.Arrow => new("箭头", "\ue72a", "粗细", 1, 30, 4),
        Tool.Line => new("直线", "\ue738", "粗细", 1, 30, 4),
        Tool.Pen => new("画笔", "\ue76d", "粗细", 1, 30, 4),
        Tool.Highlighter => new("荧光笔", "\ue7e6", "宽度", 6, 60, 18),
        Tool.Text => new("文字", "\ue8d2", "字号", 10, 120, 20),
        Tool.Counter => new("序号", "\uf146", "大小", 8, 40, 14),
        Tool.Mosaic => new("马赛克", "\uf0e2", "强度", 4, 40, 10),
        Tool.Blur => new("模糊", "\ue7a1", "强度", 2, 40, 10),
        _ => throw new ArgumentOutOfRangeException(nameof(tool))
    };

    public static bool SupportsFill(Tool tool) => tool is Tool.Rectangle or Tool.Ellipse or Tool.Text;
    public static bool HasColor(Tool tool) => tool is not (Tool.Mosaic or Tool.Blur);
    public static ToolStyle Default(Tool tool) => new(0xff3b30u, For(tool).DefaultSize);

    public static ToolStyle Normalize(Tool tool, ToolStyle value, bool allowTransparent = false)
    {
        var info = For(tool);
        return new ToolStyle(value.Rgb & 0xffffff, Math.Clamp(value.Size, info.Min, info.Max),
            double.IsFinite(value.Opacity) ? Math.Clamp(value.Opacity, allowTransparent ? 0 : .1, 1) : 1,
            SupportsFill(tool) && value.Filled);
    }
}

internal sealed record Mark(Tool Tool, ToolStyle Style, double Scale, Point[] Points, string Text = "", int Number = 0)
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public double Size => Style.Size * Scale;
    public Point First => Points[0];
    public Point Last => Points[^1];
    public bool IsBox => Tool is Tool.Rectangle or Tool.Ellipse or Tool.Mosaic or Tool.Blur;
    public bool IsLine => Tool is Tool.Arrow or Tool.Line;
    public Rect Frame => new(First, Last);
    public Rect Bounds
    {
        get
        {
            if (Tool == Tool.Counter)
                return new Rect(First.X - Size, First.Y - Size, Size * 2, Size * 2);
            if (Tool == Tool.Text)
            {
                var text = MarkRenderer.Text(Text, Size, Brushes.Black);
                var bounds = new Rect(First, new Size(Math.Max(1, text.WidthIncludingTrailingWhitespace), text.Height));
                if (Style.Filled)
                    bounds.Inflate(Math.Round(Style.Size * .3, MidpointRounding.AwayFromZero) * Scale,
                        Math.Round(Style.Size * .12, MidpointRounding.AwayFromZero) * Scale);
                return bounds;
            }
            var result = IsBox || IsLine ? Frame : new Rect(new Point(Points.Min(p => p.X), Points.Min(p => p.Y)),
                new Point(Points.Max(p => p.X), Points.Max(p => p.Y)));
            var padding = Tool switch { Tool.Mosaic or Tool.Blur => 0, Tool.Rectangle or Tool.Ellipse when Style.Filled => 0,
                Tool.Arrow => Math.Max(12 * Scale, Size * 4) * .45, _ => Size / 2 };
            result.Inflate(padding, padding);
            return result;
        }
    }

    public Mark Move(Vector delta) => this with { Points = Points.Select(point => point + delta).ToArray() };

    public IEnumerable<(RegionHandle Handle, Point Point)> Handles()
    {
        if (IsLine)
        {
            yield return (RegionHandle.TopLeft, First);
            yield return (RegionHandle.BottomRight, Last);
        }
        else if (IsBox)
        {
            var bounds = Frame;
            foreach (var handle in Enum.GetValues<RegionHandle>())
                yield return (handle, HandlePoint(bounds, handle));
        }
    }

    public Mark Resize(RegionHandle handle, Point at, bool constrained)
    {
        if (IsLine)
        {
            return handle == RegionHandle.TopLeft
                ? this with { Points = [Constrain(Last, at, false, constrained), Last] }
                : this with { Points = [First, Constrain(First, at, false, constrained)] };
        }

        var bounds = Frame;
        var opposite = (RegionHandle)(((int)handle + 4) % 8);
        var anchor = HandlePoint(bounds, opposite);
        if ((int)handle % 2 == 0)
        {
            if (constrained && bounds.Width > 0 && bounds.Height > 0)
            {
                var delta = at - anchor;
                var ratio = bounds.Width / bounds.Height;
                at = Math.Abs(delta.X) / ratio >= Math.Abs(delta.Y)
                    ? new Point(at.X, anchor.Y + Math.CopySign(Math.Abs(delta.X) / ratio, delta.Y))
                    : new Point(anchor.X + Math.CopySign(Math.Abs(delta.Y) * ratio, delta.X), at.Y);
            }
            return this with { Points = [anchor, at] };
        }

        var newBounds = handle switch
        {
            RegionHandle.Left => new Rect(new Point(at.X, bounds.Top), bounds.BottomRight),
            RegionHandle.Right => new Rect(bounds.TopLeft, new Point(at.X, bounds.Bottom)),
            RegionHandle.Top => new Rect(new Point(bounds.Left, at.Y), bounds.BottomRight),
            _ => new Rect(bounds.TopLeft, new Point(bounds.Right, at.Y))
        };
        return this with { Points = [newBounds.TopLeft, newBounds.BottomRight] };
    }

    public bool Hit(Point at, double tolerance)
    {
        var pen = new Pen(Brushes.Black, Size + tolerance * 2) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        var frame = Frame;
        switch (Tool)
        {
            case Tool.Text: return Bounds.Contains(at);
            case Tool.Mosaic: case Tool.Blur: return frame.Contains(at);
            case Tool.Counter: return (at - First).Length <= Size + tolerance;
            case Tool.Rectangle:
                if (Style.Filled) { frame.Inflate(tolerance, tolerance); return frame.Contains(at); }
                pen.LineJoin = PenLineJoin.Miter;
                return new RectangleGeometry(frame).StrokeContains(pen, at);
            case Tool.Ellipse:
                if (Style.Filled) { frame.Inflate(tolerance, tolerance); return new EllipseGeometry(frame).FillContains(at); }
                return new EllipseGeometry(frame).StrokeContains(pen, at);
            case Tool.Pen: case Tool.Highlighter:
                if (Tool == Tool.Highlighter) pen.StartLineCap = pen.EndLineCap = PenLineCap.Square;
                return MarkRenderer.StrokeGeometry(Points).StrokeContains(pen, at);
            default:
                if (Tool == Tool.Arrow)
                {
                    var head = MarkRenderer.ArrowHead(First, Last, Size, Scale);
                    if (head.FillContains(at) || head.StrokeContains(new Pen(Brushes.Black, tolerance * 2), at)) return true;
                }
                return new LineGeometry(First, Last).StrokeContains(pen, at);
        }
    }

    public static Point Constrain(Point origin, Point end, bool square, bool constrain)
    {
        if (!constrain)
            return end;
        var delta = end - origin;
        if (square)
        {
            var side = Math.Max(Math.Abs(delta.X), Math.Abs(delta.Y));
            return origin + new Vector(Math.CopySign(side, delta.X), Math.CopySign(side, delta.Y));
        }
        var angle = Math.Round(Math.Atan2(delta.Y, delta.X) / (Math.PI / 4), MidpointRounding.AwayFromZero) * (Math.PI / 4);
        return origin + new Vector(Math.Cos(angle), Math.Sin(angle)) * delta.Length;
    }

    internal static Point HandlePoint(Rect rect, RegionHandle handle) => handle switch
    {
        RegionHandle.TopLeft => rect.TopLeft,
        RegionHandle.Top => new(rect.X + rect.Width / 2, rect.Top),
        RegionHandle.TopRight => rect.TopRight,
        RegionHandle.Right => new(rect.Right, rect.Y + rect.Height / 2),
        RegionHandle.BottomRight => rect.BottomRight,
        RegionHandle.Bottom => new(rect.X + rect.Width / 2, rect.Bottom),
        RegionHandle.BottomLeft => rect.BottomLeft,
        _ => new(rect.Left, rect.Y + rect.Height / 2)
    };
}

internal sealed class MarkRenderer(BitmapSource source)
{
    private readonly Dictionary<Mark, (BitmapSource Image, Rect Destination)> patches = [];
    private static readonly Typeface TextTypeface = new(new FontFamily("Microsoft YaHei UI, Segoe UI"),
        FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);

    public void Draw(DrawingContext drawing, IReadOnlyList<Mark> marks, Mark? preview = null, int replaced = -1)
    {
        foreach (var obsolete in patches.Keys.Where(mark => !marks.Contains(mark)).ToArray())
            patches.Remove(obsolete);
        for (var i = 0; i < marks.Count; i++)
        {
            if (i == replaced)
            {
                if (preview is not null)
                    Draw(drawing, preview, true);
                continue;
            }
            Draw(drawing, marks[i], false);
        }
        if (preview is not null && replaced < 0)
            Draw(drawing, preview, true);
    }

    private void Draw(DrawingContext drawing, Mark mark, bool preview)
    {
        var color = Color.FromRgb((byte)(mark.Style.Rgb >> 16), (byte)(mark.Style.Rgb >> 8), (byte)mark.Style.Rgb);
        var brush = new SolidColorBrush(color);
        var size = mark.Size;
        var pen = new Pen(brush, size) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round };
        var bounds = mark.IsBox ? mark.Frame : mark.Bounds;
        var opacity = mark.Tool == Tool.Highlighter ? mark.Style.Opacity * 0.38 : mark.Style.Opacity;
        drawing.PushOpacity(ToolInfo.HasColor(mark.Tool) ? opacity : 1);
        switch (mark.Tool)
        {
            case Tool.Rectangle:
                pen.LineJoin = PenLineJoin.Miter;
                drawing.DrawRectangle(mark.Style.Filled ? brush : null, mark.Style.Filled ? null : pen, bounds);
                break;
            case Tool.Ellipse:
                drawing.DrawEllipse(mark.Style.Filled ? brush : null, mark.Style.Filled ? null : pen,
                    new Point(bounds.X + bounds.Width / 2, bounds.Y + bounds.Height / 2), bounds.Width / 2, bounds.Height / 2);
                break;
            case Tool.Line:
                drawing.DrawLine(pen, mark.First, mark.Last);
                break;
            case Tool.Arrow:
                DrawArrow(drawing, mark.First, mark.Last, pen, mark.Scale);
                break;
            case Tool.Pen:
            case Tool.Highlighter:
                if (mark.Tool == Tool.Highlighter)
                    pen.StartLineCap = pen.EndLineCap = PenLineCap.Square;
                DrawStroke(drawing, mark.Points, pen);
                break;
            case Tool.Text:
                if (mark.Style.Filled)
                    drawing.DrawRoundedRectangle(brush, null, bounds, size * 0.22, size * 0.22);
                drawing.DrawText(Text(mark.Text, size, mark.Style.Filled ? TextContrast(color) : brush), mark.First);
                break;
            case Tool.Counter:
                drawing.DrawEllipse(brush, null, mark.First, size, size);
                var number = Text(mark.Number.ToString(CultureInfo.InvariantCulture), size * 1.15, CounterContrast(color), true);
                drawing.DrawText(number, new Point(mark.First.X - number.Width / 2, mark.First.Y - number.Height / 2));
                break;
            case Tool.Mosaic:
            case Tool.Blur:
                DrawPatch(drawing, mark, preview);
                break;
        }
        drawing.Pop();
    }

    internal static FontFamily TextFont => TextTypeface.FontFamily;
    public static FormattedText Text(string value, double size, Brush foreground, bool bold = false) =>
        new(value, CultureInfo.GetCultureInfo("zh-CN"), FlowDirection.LeftToRight,
            bold ? new Typeface(TextFont, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal) : TextTypeface, size, foreground, 1);

    internal static Brush TextContrast(Color color) =>
        color.R * 0.2126 + color.G * 0.7152 + color.B * 0.0722 > 255 * .6 ? Brushes.Black : Brushes.White;
    internal static Brush CounterContrast(Color color)
    {
        var maximum = Math.Max(color.R, Math.Max(color.G, color.B));
        var minimum = Math.Min(color.R, Math.Min(color.G, color.B));
        var light = maximum > .85 * 255 && maximum - minimum < .9 * maximum;
        return light || color is { R: 255, G: 204, B: 0 } ? Brushes.Black : Brushes.White;
    }

    private static void DrawArrow(DrawingContext drawing, Point first, Point last, Pen pen, double scale)
    {
        var direction = last - first;
        if (direction.Length <= 1)
            return;
        var length = Math.Min(Math.Max(12 * scale, pen.Thickness * 4), direction.Length / 2);
        direction.Normalize();
        var basis = last - direction * length;
        drawing.DrawLine(pen, first, basis + direction);
        drawing.DrawGeometry(pen.Brush, null, ArrowHead(first, last, pen.Thickness, scale));
    }
    internal static Geometry ArrowHead(Point first, Point last, double width, double scale)
    {
        var direction = last - first;
        if (direction.Length <= scale) return Geometry.Empty;
        var length = Math.Min(Math.Max(12 * scale, width * 4), direction.Length / 2);
        direction.Normalize();
        var basis = last - direction * length;
        var perpendicular = new Vector(-direction.Y, direction.X) * (length * .45);
        var triangle = new StreamGeometry();
        using (var path = triangle.Open())
        {
            path.BeginFigure(last, true, true);
            path.LineTo(basis + perpendicular, true, false);
            path.LineTo(basis - perpendicular, true, false);
        }
        return triangle;
    }

    private static void DrawStroke(DrawingContext drawing, Point[] points, Pen pen)
    {
        drawing.DrawGeometry(null, pen, StrokeGeometry(points));
    }
    internal static Geometry StrokeGeometry(Point[] points)
    {
        var geometry = new StreamGeometry();
        using (var path = geometry.Open())
        {
            path.BeginFigure(points[0], false, false);
            for (var i = 1; i < points.Length; i++)
            {
                var middle = points[i - 1] + (points[i] - points[i - 1]) / 2;
                path.QuadraticBezierTo(points[i - 1], middle, true, true);
            }
            path.LineTo(points[^1], true, true);
        }
        return geometry;
    }

    private void DrawPatch(DrawingContext drawing, Mark mark, bool preview)
    {
        if (!patches.TryGetValue(mark, out var patch))
        {
            var bounds = mark.Bounds;
            var left = Math.Clamp((int)Math.Floor(bounds.Left), 0, source.PixelWidth);
            var top = Math.Clamp((int)Math.Floor(bounds.Top), 0, source.PixelHeight);
            var right = Math.Clamp((int)Math.Ceiling(bounds.Right), 0, source.PixelWidth);
            var bottom = Math.Clamp((int)Math.Ceiling(bounds.Bottom), 0, source.PixelHeight);
            var width = right - left;
            var height = bottom - top;
            if (width < 1 || height < 1)
                return;
            var pixels = new byte[checked(width * height * 4)];
            source.CopyPixels(new Int32Rect(left, top, width, height), pixels, width * 4, 0);
            var radius = Math.Max(1, (int)Math.Round(mark.Size));
            if (mark.Tool == Tool.Mosaic)
                PixelEffects.Mosaic(pixels, width, height, radius);
            else
                PixelEffects.Blur(pixels, width, height, radius);
            var image = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgr32, null, pixels, width * 4);
            image.Freeze();
            patch = (image, new Rect(left, top, width, height));
            if (!preview) patches.Add(mark, patch);
        }
        drawing.DrawImage(patch.Image, patch.Destination);
    }
}
