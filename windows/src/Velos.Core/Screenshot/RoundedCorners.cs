namespace Velos.Core.Screenshot;

/// <summary>对直通 BGRA 原生像素施加圆角；只改角落，透明处清零颜色，避免残留不可见内容。</summary>
public static class RoundedCorners
{
    public static double PhysicalRadius(double dip, double scale, int width, int height) =>
        double.IsFinite(dip) && double.IsFinite(scale) && scale > 0 ? Math.Min(Math.Clamp(dip, 0, 40) * scale, Math.Min(width, height) / 2d) : 0;

    public static void Apply(byte[] bgra, int width, int height, double radius)
    {
        if (width < 1 || height < 1 || bgra.Length != checked(width * height * 4)) throw new ArgumentException("圆角像素尺寸不符。");
        radius = Math.Min(Math.Max(0, radius), Math.Min(width, height) / 2d);
        if (radius == 0) return;
        var side = (int)Math.Ceiling(radius);
        for (var y = 0; y < side; y++)
        for (var x = 0; x < side; x++)
        {
            var inside = 0;
            const int samples = 4;
            for (var sy = 0; sy < samples; sy++)
            for (var sx = 0; sx < samples; sx++)
            {
                var px = x + (sx + .5) / samples; var py = y + (sy + .5) / samples;
                var dx = px - Math.Clamp(px, radius, width - radius); var dy = py - Math.Clamp(py, radius, height - radius);
                if (dx * dx + dy * dy <= radius * radius) inside++;
            }
            void Pixel(int xx, int yy)
            {
                var offset = (yy * width + xx) * 4;
                bgra[offset + 3] = (byte)((bgra[offset + 3] * inside + samples * samples / 2) / (samples * samples));
                if (bgra[offset + 3] == 0) bgra[offset] = bgra[offset + 1] = bgra[offset + 2] = 0;
            }
            Pixel(x, y);
            if (width - 1 - x != x) Pixel(width - 1 - x, y);
            if (height - 1 - y != y)
            { Pixel(x, height - 1 - y); if (width - 1 - x != x) Pixel(width - 1 - x, height - 1 - y); }
        }
    }
}
