using System.Drawing;
using Velos.Core.LongCapture;

namespace Velos.Core.Screenshot;

public readonly record struct PinPlacement(RectangleF Bounds, double Zoom, ScrollAxis? Axis);
[Flags] public enum PinEdge { None = 0, Left = 1, Top = 2, Right = 4, Bottom = 8 }

/// <summary>移植 Mac 2.4.2 PinManager / PinView；调用方传入同一坐标单位。</summary>
public static class PinLayout
{
    public static ScrollAxis? LongAxis(SizeF size) => size.Width > 0 && size.Height > 0
        ? size.Height / size.Width > 2.5 ? ScrollAxis.Vertical : size.Width / size.Height > 2.5 ? ScrollAxis.Horizontal : null : null;

    public static PinPlacement Initial(SizeF image, RectangleF source, RectangleF screen, RectangleF work)
    {
        var axis = LongAxis(image); var zoom = 1d;
        var bounds = new RectangleF(source.Location, image);
        if (axis is { } direction)
        {
            zoom = direction == ScrollAxis.Vertical ? Math.Min(1, work.Width / image.Width) : Math.Min(1, work.Height / image.Height);
            var width = Round(image.Width * zoom); var height = Round(image.Height * zoom);
            if (direction == ScrollAxis.Vertical) height = Math.Min(height, Round(work.Height * .85));
            else width = Math.Min(width, Round(work.Width * .85));
            bounds = screen.IntersectsWith(source) ? InPlace(width, height, source, work) : Center(width, height, work);
        }
        else if (!screen.Contains(bounds))
        {
            zoom = Math.Min(1, Math.Min(work.Width / image.Width, work.Height / image.Height));
            var width = Round(image.Width * zoom); var height = Round(image.Height * zoom);
            bounds = zoom < 1 || !screen.IntersectsWith(source) ? Center(width, height, work) : InPlace(width, height, source, work);
        }
        return new(bounds, zoom, axis);
    }

    public static PinPlacement Zoom(SizeF image, RectangleF current, double previous, double requested, PointF anchor, RectangleF work, ScrollAxis? axis, double minimum = 20, double minimumZoom = .1)
    {
        var zoom = Math.Clamp(requested, Math.Min(minimumZoom, previous), 8); var width = Round(image.Width * zoom); var height = Round(image.Height * zoom);
        // 极小原图可以从原尺寸逐步放大；下限只阻止继续缩小，不能把放大也锁住。
        if ((width < minimum || height < minimum) && zoom <= previous) return new(current, previous, axis);
        if (axis == ScrollAxis.Vertical) height = Math.Min(height, Round(work.Height * .85));
        else if (axis == ScrollAxis.Horizontal) width = Math.Min(width, Round(work.Width * .85));
        var x = current.X + anchor.X - (current.Width > 0 ? anchor.X / current.Width : .5f) * width;
        var y = current.Y + anchor.Y - (current.Height > 0 ? anchor.Y / current.Height : .5f) * height;
        return new(new RectangleF(x, y, width, height), zoom, axis);
    }
    public static double WheelOpacity(double opacity, int delta) => Math.Clamp(opacity + delta / 120d * .04, .2, 1);
    public static double WheelZoom(double zoom, int delta, double minimumZoom = .1) => Math.Clamp(zoom * Math.Exp(Math.Clamp(delta / 120d, -60, 60) * .08), Math.Min(minimumZoom, zoom), 8);
    /// <summary>边缘只提供命中区，不要求显示控制点。单位由调用方统一，UI 通常传 DIP。</summary>
    public static PinEdge EdgeAt(PointF point, SizeF size, float grip = 6, float corner = 14)
    {
        if (size.Width <= 0 || size.Height <= 0 || point.X < 0 || point.Y < 0 || point.X > size.Width || point.Y > size.Height) return PinEdge.None;
        var thickness = Math.Min(grip, Math.Min(size.Width, size.Height) / 4);
        var corners = Math.Min(corner, Math.Min(size.Width, size.Height) / 3);
        if (point.X > thickness && point.X < size.Width - thickness && point.Y > thickness && point.Y < size.Height - thickness) return PinEdge.None;
        var left = point.X <= corners; var right = point.X >= size.Width - corners;
        var top = point.Y <= corners; var bottom = point.Y >= size.Height - corners;
        if ((left || right) && (top || bottom)) return (left ? PinEdge.Left : PinEdge.Right) | (top ? PinEdge.Top : PinEdge.Bottom);
        if (point.X <= thickness) return PinEdge.Left;
        if (point.X >= size.Width - thickness) return PinEdge.Right;
        if (point.Y <= thickness) return PinEdge.Top;
        if (point.Y >= size.Height - thickness) return PinEdge.Bottom;
        return PinEdge.None;
    }
    /// <summary>按下时的矩形和全局指针位移决定结果；固定对边／对角，图像始终统一比例缩放。</summary>
    public static PinPlacement ResizeFromEdge(SizeF image, RectangleF start, double initialZoom, PinEdge edge, PointF delta,
        RectangleF work, ScrollAxis? axis, double minimum = 40, double minimumZoom = .1)
    {
        var original = new PinPlacement(start, initialZoom, axis);
        if (edge == PinEdge.None || image.Width <= 0 || image.Height <= 0 || start.Width <= 0 || start.Height <= 0 || initialZoom <= 0 ||
            !float.IsFinite(delta.X) || !float.IsFinite(delta.Y)) return original;
        var horizontal = (edge & (PinEdge.Left | PinEdge.Right)) != 0; var vertical = (edge & (PinEdge.Top | PinEdge.Bottom)) != 0;
        if ((edge & (PinEdge.Left | PinEdge.Right)) == (PinEdge.Left | PinEdge.Right) || (edge & (PinEdge.Top | PinEdge.Bottom)) == (PinEdge.Top | PinEdge.Bottom)) return original;
        var dx = edge.HasFlag(PinEdge.Left) ? -delta.X : delta.X; var dy = edge.HasFlag(PinEdge.Top) ? -delta.Y : delta.Y;
        // 长图沿长轴拖单边只裁切视口，原图像素比例不变；用户可以展开整张图。
        if (axis == ScrollAxis.Vertical && !horizontal || axis == ScrollAxis.Horizontal && !vertical)
        {
            var length = axis == ScrollAxis.Vertical ? start.Height + dy : start.Width + dx;
            var full = (axis == ScrollAxis.Vertical ? image.Height : image.Width) * initialZoom;
            var shown = Math.Max(1, Round(Math.Clamp(length, Math.Min(minimum, full), full)));
            var viewport = axis == ScrollAxis.Vertical
                ? new RectangleF(start.X, edge.HasFlag(PinEdge.Top) ? start.Bottom - shown : start.Y, start.Width, shown)
                : new RectangleF(edge.HasFlag(PinEdge.Left) ? start.Right - shown : start.X, start.Y, shown, start.Height);
            return new(viewport, initialZoom, axis);
        }
        var sx = 1 + dx / (double)start.Width; var sy = 1 + dy / (double)start.Height;
        var factor = horizontal && vertical ? Math.Abs(sx - 1) >= Math.Abs(sy - 1) ? sx : sy : horizontal ? sx : sy;
        var lower = Math.Min(initialZoom, Math.Max(minimumZoom, minimum / Math.Min(image.Width, image.Height)));
        var zoom = Math.Clamp(initialZoom * factor, lower, 8);
        var width = Math.Max(1, Round(image.Width * zoom)); var height = Math.Max(1, Round(image.Height * zoom));
        if (axis == ScrollAxis.Vertical) height = Math.Max(1, Math.Min(height, Round(work.Height * .85)));
        if (axis == ScrollAxis.Horizontal) width = Math.Max(1, Math.Min(width, Round(work.Width * .85)));
        var fx = edge.HasFlag(PinEdge.Left) ? 1 : edge.HasFlag(PinEdge.Right) ? 0 : .5f;
        var fy = edge.HasFlag(PinEdge.Top) ? 1 : edge.HasFlag(PinEdge.Bottom) ? 0 : .5f;
        return new(new RectangleF(start.Left + (start.Width - width) * fx, start.Top + (start.Height - height) * fy, width, height), zoom, axis);
    }
    private static float Round(double value) => (float)Math.Round(value, MidpointRounding.AwayFromZero);
    private static RectangleF InPlace(float width, float height, RectangleF source, RectangleF work) => new(
        Round(Math.Min(Math.Max(source.Left, work.Left), work.Right - width)), Round(Math.Min(Math.Max(source.Top, work.Top), work.Bottom - height)), width, height);
    private static RectangleF Center(float width, float height, RectangleF work) => new(Round(work.X + (work.Width - width) / 2), Round(work.Y + (work.Height - height) / 2), width, height);
}
