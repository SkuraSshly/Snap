using System.Drawing;

namespace Velos.Core.Screenshot;

public enum RegionHandle { TopLeft, Top, TopRight, Right, BottomRight, Bottom, BottomLeft, Left }

public static class RegionGeometry
{
    public static Rectangle Between(Point start, Point end) => Rectangle.FromLTRB(
        Math.Min(start.X, end.X), Math.Min(start.Y, end.Y), Math.Max(start.X, end.X), Math.Max(start.Y, end.Y));

    public static Point HandlePoint(Rectangle rect, RegionHandle handle)
    {
        var centerX = rect.Left + rect.Width / 2;
        var centerY = rect.Top + rect.Height / 2;
        return handle switch
        {
            RegionHandle.TopLeft => new(rect.Left, rect.Top),
            RegionHandle.Top => new(centerX, rect.Top),
            RegionHandle.TopRight => new(rect.Right, rect.Top),
            RegionHandle.Right => new(rect.Right, centerY),
            RegionHandle.BottomRight => new(rect.Right, rect.Bottom),
            RegionHandle.Bottom => new(centerX, rect.Bottom),
            RegionHandle.BottomLeft => new(rect.Left, rect.Bottom),
            RegionHandle.Left => new(rect.Left, centerY),
            _ => throw new ArgumentOutOfRangeException(nameof(handle))
        };
    }

    public static Rectangle Move(Rectangle rect, int dx, int dy, Rectangle bounds) => new(
        Math.Clamp(rect.X + dx, bounds.Left, bounds.Right - rect.Width),
        Math.Clamp(rect.Y + dy, bounds.Top, bounds.Bottom - rect.Height), rect.Width, rect.Height);

    public static Rectangle Resize(Rectangle rect, RegionHandle handle, Point point, Rectangle bounds)
    {
        int left = rect.Left, top = rect.Top, right = rect.Right, bottom = rect.Bottom;
        if (handle is RegionHandle.TopLeft or RegionHandle.Left or RegionHandle.BottomLeft)
            left = Math.Clamp(point.X, bounds.Left, right - 1);
        if (handle is RegionHandle.TopRight or RegionHandle.Right or RegionHandle.BottomRight)
            right = Math.Clamp(point.X, left + 1, bounds.Right);
        if (handle is RegionHandle.TopLeft or RegionHandle.Top or RegionHandle.TopRight)
            top = Math.Clamp(point.Y, bounds.Top, bottom - 1);
        if (handle is RegionHandle.BottomLeft or RegionHandle.Bottom or RegionHandle.BottomRight)
            bottom = Math.Clamp(point.Y, top + 1, bounds.Bottom);
        return Rectangle.FromLTRB(left, top, right, bottom);
    }
}
