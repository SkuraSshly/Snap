using System.Drawing;

namespace Velos.Core.Recording;

internal static class GifQuantizer
{
    private sealed record Box(int Low, int High, long Count, int Range, int Channel);

    public static (uint[] Palette, byte[] Indices) Quantize(uint[] pixels, int width, Rectangle rect, bool[] changed)
    {
        const int binCount = 1 << 15;
        var counts = new int[binCount];
        var sumR = new long[binCount];
        var sumG = new long[binCount];
        var sumB = new long[binCount];
        var first = new uint[binCount];
        var mixed = new bool[binCount];
        var used = new List<int>();
        for (var y = 0; y < rect.Height; y++)
        for (var x = 0; x < rect.Width; x++)
        {
            if (!changed[y * rect.Width + x]) continue;
            var color = pixels[(rect.Y + y) * width + rect.X + x] & 0xffffff;
            var bin = Bin(color);
            if (counts[bin] == 0) { used.Add(bin); first[bin] = color; }
            else if (first[bin] != color) mixed[bin] = true;
            counts[bin]++;
            sumR[bin] += color & 255;
            sumG[bin] += (color >> 8) & 255;
            sumB[bin] += (color >> 16) & 255;
        }
        uint[] palette;
        var lookup = new byte[binCount];
        if (used.Count <= 255 && !used.Any(bin => mixed[bin]))
        {
            palette = used.Select(bin => first[bin]).ToArray();
            for (var i = 0; i < used.Count; i++) lookup[used[i]] = (byte)i;
        }
        else
        {
            var items = used.ToArray();
            Box MakeBox(int low, int high)
            {
                int[] minimum = [31, 31, 31], maximum = [0, 0, 0];
                long count = 0;
                for (var i = low; i < high; i++)
                {
                    var bin = items[i];
                    count += counts[bin];
                    for (var c = 0; c < 3; c++)
                    {
                        var component = (bin >> (c * 5)) & 31;
                        minimum[c] = Math.Min(minimum[c], component);
                        maximum[c] = Math.Max(maximum[c], component);
                    }
                }
                int[] weighted = [(maximum[0] - minimum[0]) * 3, (maximum[1] - minimum[1]) * 4, (maximum[2] - minimum[2]) * 2];
                var channel = Array.IndexOf(weighted, weighted.Max());
                return new(low, high, count, weighted[channel], channel);
            }
            var boxes = new List<Box> { MakeBox(0, items.Length) };
            while (boxes.Count < 255)
            {
                var box = boxes.Where(candidate => candidate.High - candidate.Low > 1)
                    .MaxBy(candidate => (double)candidate.Count * candidate.Range);
                if (box is null || box.Range == 0) break;
                Array.Sort(items, box.Low, box.High - box.Low, Comparer<int>.Create((a, b) =>
                    ((a >> (box.Channel * 5)) & 31).CompareTo((b >> (box.Channel * 5)) & 31)));
                long accumulated = 0;
                var split = box.Low + 1;
                for (var i = box.Low; i < box.High; i++)
                {
                    accumulated += counts[items[i]];
                    if (accumulated * 2 < box.Count) continue;
                    split = Math.Clamp(i + 1, box.Low + 1, box.High - 1);
                    break;
                }
                var index = boxes.IndexOf(box);
                boxes[index] = MakeBox(box.Low, split);
                boxes.Add(MakeBox(split, box.High));
            }
            palette = boxes.Select(box =>
            {
                long red = 0, green = 0, blue = 0, count = 0;
                for (var i = box.Low; i < box.High; i++)
                {
                    var bin = items[i];
                    red += sumR[bin]; green += sumG[bin]; blue += sumB[bin]; count += counts[bin];
                }
                count = Math.Max(count, 1);
                return (uint)(red / count) | (uint)(green / count) << 8 | (uint)(blue / count) << 16;
            }).ToArray();
            foreach (var bin in used)
            {
                var red = (int)(sumR[bin] / counts[bin]);
                var green = (int)(sumG[bin] / counts[bin]);
                var blue = (int)(sumB[bin] / counts[bin]);
                var best = 0;
                var distance = int.MaxValue;
                for (var i = 0; i < palette.Length; i++)
                {
                    var color = palette[i];
                    var dr = red - (int)(color & 255);
                    var dg = green - (int)((color >> 8) & 255);
                    var db = blue - (int)((color >> 16) & 255);
                    var current = 3 * dr * dr + 4 * dg * dg + 2 * db * db;
                    if (current >= distance) continue;
                    distance = current;
                    best = i;
                }
                lookup[bin] = (byte)best;
            }
        }
        if (palette.Length == 0) palette = [0];
        var indices = new byte[rect.Width * rect.Height];
        for (var y = 0; y < rect.Height; y++)
        for (var x = 0; x < rect.Width; x++)
        {
            var index = y * rect.Width + x;
            indices[index] = changed[index] ? lookup[Bin(pixels[(rect.Y + y) * width + rect.X + x])] : (byte)255;
        }
        return (palette, indices);
    }

    private static int Bin(uint color) => (int)(((color & 0xf8) >> 3) | ((color & 0xf800) >> 6) | ((color & 0xf80000) >> 9));
}
