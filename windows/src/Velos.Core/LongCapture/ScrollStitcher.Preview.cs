using System.Runtime.InteropServices;

namespace Velos.Core.LongCapture;

public sealed partial class ScrollStitcher
{
    /// <summary>直接按预览面板的物理像素大小采样，随当前滚动位置回看，不复制大图。</summary>
    public ScrollFrame? PreviewSized(int pixelWidth, int pixelHeight)
    {
        if (last is null || pixelWidth < 1 || pixelHeight < 1 || axis != ScrollAxis.Vertical) return null;
        var ratio = (double)pixelWidth / cross;
        var fitting = Math.Max(1, (int)(pixelHeight / ratio));
        var end = first is not null ? LineCount(first) : Math.Min(committedEnd, Math.Max(fitting, position + LineCount(last) - footerLength));
        var start = Math.Max(0, end - fitting); var lines = end - start;
        if (lines < 1) return null;
        var fullHeight = Math.Max(1, (int)Math.Round(lines * ratio));
        var height = Math.Min(pixelHeight, fullHeight);
        // 与 Mac scaled() 一样等比画出整张，再裁掉上面超出的部分；首屏也不能压扁进面板。
        var top = start + (fullHeight - height) * (double)lines / fullHeight;
        var stepY = (double)lines / fullHeight;
        var pixels = new byte[checked(pixelWidth * height * 4)];
        var source = MemoryMarshal.Cast<byte, uint>(content.AsSpan()); var output = MemoryMarshal.Cast<byte, uint>(pixels.AsSpan());
        if (ratio <= 1)
        {
            // 缩小预览需要覆盖像素面积的低通采样；只取四点会漏掉细字、细线并产生摩尔纹。
            // 直接读可见片段，不生成整张长图，也不修改最终输出缓冲。
            var stepX = (double)cross / pixelWidth;
            var sums = new double[pixelWidth * 3];
            for (var y = 0; y < height; y++)
            {
                Array.Clear(sums);
                var yLow = top + y * stepY; var yHigh = Math.Min(end, yLow + stepY);
                for (var sy = (int)Math.Floor(yLow); sy < Math.Ceiling(yHigh); sy++)
                {
                    var weightY = Math.Min(yHigh, sy + 1) - Math.Max(yLow, sy);
                    var row = first is null ? source.Slice(sy * cross, cross) : first.Row(sy);
                    for (var x = 0; x < pixelWidth; x++)
                    {
                        var xLow = x * stepX; var xHigh = Math.Min(cross, xLow + stepX);
                        double blue = 0, green = 0, red = 0;
                        for (var sx = (int)Math.Floor(xLow); sx < Math.Ceiling(xHigh); sx++)
                        {
                            var weight = (Math.Min(xHigh, sx + 1) - Math.Max(xLow, sx)) * weightY;
                            var pixel = row[sx]; blue += (pixel & 255) * weight; green += ((pixel >> 8) & 255) * weight; red += ((pixel >> 16) & 255) * weight;
                        }
                        sums[x * 3] += blue; sums[x * 3 + 1] += green; sums[x * 3 + 2] += red;
                    }
                }
                var area = stepX * (yHigh - yLow);
                for (var x = 0; x < pixelWidth; x++)
                    output[y * pixelWidth + x] = 0xff000000 | (uint)Math.Clamp(Math.Round(sums[x * 3] / area), 0, 255) |
                        (uint)Math.Clamp(Math.Round(sums[x * 3 + 1] / area), 0, 255) << 8 | (uint)Math.Clamp(Math.Round(sums[x * 3 + 2] / area), 0, 255) << 16;
            }
            return new ScrollFrame(pixelWidth, height, pixelWidth * 4, pixels);
        }
        for (var y = 0; y < height; y++) for (var x = 0; x < pixelWidth; x++)
        {
            var sx = Math.Clamp((x + .5) * cross / pixelWidth - .5, 0, cross - 1);
            var sy = Math.Clamp(top + (y + .5) * stepY - .5, start, end - 1);
            var x0 = (int)sx; var x1 = Math.Min(cross - 1, x0 + 1); var y0 = (int)sy; var y1 = Math.Min(end - 1, y0 + 1);
            var fx = sx - x0; var fy = sy - y0;
            var a = first is null ? source[y0 * cross + x0] : first.At(x0, y0);
            var b = first is null ? source[y0 * cross + x1] : first.At(x1, y0);
            var c = first is null ? source[y1 * cross + x0] : first.At(x0, y1);
            var d = first is null ? source[y1 * cross + x1] : first.At(x1, y1);
            uint result = 0xff000000;
            for (var k = 0; k < 24; k += 8)
            {
                var upper = ((a >> k) & 255) * (1 - fx) + ((b >> k) & 255) * fx;
                var lower = ((c >> k) & 255) * (1 - fx) + ((d >> k) & 255) * fx;
                result |= (uint)Math.Round(upper * (1 - fy) + lower * fy) << k;
            }
            output[y * pixelWidth + x] = result;
        }
        return new ScrollFrame(pixelWidth, height, pixelWidth * 4, pixels);
    }
}
