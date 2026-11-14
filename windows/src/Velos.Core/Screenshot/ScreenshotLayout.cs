using System.Drawing;
using Velos.Core.Hotkeys;

namespace Velos.Core.Screenshot;

public static class ScreenshotLayout
{
    // 工具栏位置与 Mac 版相同，坐标从屏幕左上角开始。
    public static PointF ToolbarOrigin(SizeF size, RectangleF? selection, RectangleF bounds)
    {
        const float margin = 8;
        float x, y;
        if (selection is { } area)
        {
            x = area.Right - size.Width;
            y = area.Bottom + margin;
            if (y + size.Height > bounds.Bottom - 4)
            {
                y = area.Top - margin - 22 - size.Height;
                if (y < bounds.Top + 4)
                    y = area.Bottom - margin - size.Height;
            }
        }
        else
        {
            x = bounds.Left + (bounds.Width - size.Width) / 2;
            y = bounds.Bottom - 28 - size.Height;
        }

        x = Math.Clamp(x, bounds.Left + 4, Math.Max(bounds.Left + 4, bounds.Right - size.Width - 4));
        return new PointF(MathF.Round(x, MidpointRounding.AwayFromZero), MathF.Round(y, MidpointRounding.AwayFromZero));
    }

    public static double FitScale(SizeF image, SizeF viewport, FitAxis axis = FitAxis.Both)
    {
        if (image.Width <= 0 || image.Height <= 0 || viewport.Width <= 0 || viewport.Height <= 0)
            return 1;
        double horizontal = (double)viewport.Width / image.Width;
        double vertical = (double)viewport.Height / image.Height;
        return axis switch
        {
            FitAxis.Width => horizontal,
            FitAxis.Height => vertical,
            _ => Math.Min(horizontal, vertical)
        };
    }
    public static FitAxis EditorFitAxis(SizeF image, SizeF viewport)
    {
        var width = Math.Min(1, FitScale(image, viewport, FitAxis.Width));
        var height = Math.Min(1, FitScale(image, viewport, FitAxis.Height));
        return image.Height * width > viewport.Height * 1.3 ? FitAxis.Width : image.Width * height > viewport.Width * 1.3 ? FitAxis.Height : FitAxis.Both;
    }

    public static int? ArrowStep(HotkeyModifiers modifiers) => modifiers switch
    {
        HotkeyModifiers.None => 1,
        HotkeyModifiers.Shift => 10,
        _ => null
    };

    public static double ThumbnailScale(SizeF pixels, double pixelsPerDip) =>
        Math.Min(1 / pixelsPerDip, Math.Min(240d / pixels.Width, 150d / pixels.Height));

    // ThumbnailManager.fittedSize：很长或很小的图片也保留足够的操作空间。
    public static SizeF ThumbnailSize(SizeF pixels, double pixelsPerDip)
    {
        var width = pixels.Width / pixelsPerDip; var height = pixels.Height / pixelsPerDip;
        var factor = Math.Min(1, Math.Min(240 / Math.Max(width, 1), 150 / Math.Max(height, 1)));
        return new((float)Math.Min(240, Math.Max(60, Math.Max(Math.Round(width * factor, MidpointRounding.AwayFromZero), Math.Min(150, width)))),
            (float)Math.Min(150, Math.Max(40, Math.Max(Math.Round(height * factor, MidpointRounding.AwayFromZero), Math.Min(100, height)))));
    }
}

public enum FitAxis { Both, Width, Height }
