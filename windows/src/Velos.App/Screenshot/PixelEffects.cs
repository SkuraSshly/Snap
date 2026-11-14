namespace Velos.Screenshot;

internal static class PixelEffects
{
    public static void Mosaic(byte[] pixels, int width, int height, int block)
    {
        for (var top = 0; top < height; top += block)
        for (var left = 0; left < width; left += block)
        {
            var bottom = Math.Min(top + block, height);
            var right = Math.Min(left + block, width);
            int blue = 0, green = 0, red = 0;
            for (var y = top; y < bottom; y++)
            for (var x = left; x < right; x++)
            {
                var offset = (y * width + x) * 4;
                blue += pixels[offset];
                green += pixels[offset + 1];
                red += pixels[offset + 2];
            }
            var count = (bottom - top) * (right - left);
            for (var y = top; y < bottom; y++)
            for (var x = left; x < right; x++)
            {
                var offset = (y * width + x) * 4;
                pixels[offset] = (byte)(blue / count);
                pixels[offset + 1] = (byte)(green / count);
                pixels[offset + 2] = (byte)(red / count);
            }
        }
    }

    public static void Blur(byte[] pixels, int width, int height, int radius)
    {
        var scratch = new byte[pixels.Length];
        // Swift 的参数是高斯 sigma，而非方框半径。三次方框的方差之和与 sigma 匹配。
        var ideal = Math.Sqrt(4d * radius * radius + 1);
        var lower = (int)Math.Floor(ideal); if (lower % 2 == 0) lower--;
        var upper = lower + 2;
        var lowerPasses = (int)Math.Round((12d * radius * radius - 3 * lower * lower - 12 * lower - 9) / (-4d * lower - 4));
        for (var pass = 0; pass < 3; pass++)
        {
            var boxRadius = ((pass < lowerPasses ? lower : upper) - 1) / 2;
            Smooth(pixels, scratch, height, width, width * 4, 4, boxRadius);
            Smooth(scratch, pixels, width, height, 4, width * 4, boxRadius);
        }
    }

    private static void Smooth(byte[] input, byte[] output, int lines, int length, int lineStride, int step, int radius)
    {
        var denominator = radius * 2 + 1;
        for (var line = 0; line < lines; line++)
        for (var channel = 0; channel < 3; channel++)
        {
            var start = line * lineStride + channel;
            var sum = 0;
            for (var offset = -radius; offset <= radius; offset++)
                sum += input[start + Math.Clamp(offset, 0, length - 1) * step];
            for (var index = 0; index < length; index++)
            {
                output[start + index * step] = (byte)(sum / denominator);
                var leaving = Math.Max(0, index - radius);
                var entering = Math.Min(length - 1, index + radius + 1);
                sum += input[start + entering * step] - input[start + leaving * step];
            }
        }
    }
}
