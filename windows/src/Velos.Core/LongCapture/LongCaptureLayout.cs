using System.Drawing;

namespace Velos.Core.LongCapture;

public static class LongCaptureLayout
{
    public static RectangleF Bar(RectangleF region, SizeF size, RectangleF workArea)
    {
        var x = region.Right - size.Width;
        var y = region.Bottom + 8;
        if (y + size.Height > workArea.Bottom - 4)
        {
            y = region.Top - 8 - size.Height;
            if (y < workArea.Top + 4) y = region.Bottom - 8 - size.Height;
        }
        x = Math.Clamp(x, workArea.Left + 4, Math.Max(workArea.Left + 4, workArea.Right - size.Width - 4));
        y = Math.Clamp(y, workArea.Top + 4, Math.Max(workArea.Top + 4, workArea.Bottom - size.Height - 4));
        return new RectangleF(x, y, size.Width, size.Height);
    }

    public static RectangleF? Preview(RectangleF region, RectangleF bar, RectangleF workArea, ScrollAxis axis)
    {
        const float gap = 12;
        if (axis == ScrollAxis.Vertical)
        {
            var height = Math.Clamp(region.Height, 160, 420);
            var right = new RectangleF(region.Right + gap, region.Top, 150, height);
            var left = new RectangleF(region.Left - gap - 150, region.Top, 150, height);
            if (workArea.Contains(right) && !bar.IntersectsWith(right)) return right;
            if (workArea.Contains(left) && !bar.IntersectsWith(left)) return left;
        }
        else
        {
            var width = Math.Clamp(region.Width, 200, 420);
            var above = new RectangleF(region.Left, region.Top - gap - 110, width, 110);
            var below = new RectangleF(region.Left, Math.Max(region.Bottom, bar.Bottom) + gap, width, 110);
            if (workArea.Contains(above) && !bar.IntersectsWith(above)) return above;
            if (workArea.Contains(below) && !bar.IntersectsWith(below)) return below;
        }
        return null;
    }
}
