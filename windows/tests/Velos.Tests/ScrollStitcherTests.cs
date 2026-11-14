using System.Runtime.InteropServices;
using Velos.Core.LongCapture;
using static Velos.Core.LongCapture.ScrollStitcher.EventKind;

internal static partial class ScrollStitcherTests
{
    private const int Width = 64;

    public static (string Name, Action Run)[] Cases(Action<bool, string> check)
    {
        return
        [
            ("长截图第一帧长度是一屏", () =>
            {
                var stitcher = new ScrollStitcher(ScrollAxis.Vertical);
                check(stitcher.Add(Window(0, 100)).Kind == Started && stitcher.Length == 100, "第一帧");
            }),
            ("向下滚动的每一步逐行拼接", () =>
            {
                var stitcher = new ScrollStitcher(ScrollAxis.Vertical);
                stitcher.Add(Window(0, 100));
                for (var i = 1; i <= 15; i++)
                    check(stitcher.Add(Window(i * 7, 100)) == new ScrollStitcher.Result(Appended, 7), $"第 {i} 帧");
                check(stitcher.Length == 205, "长度");
                AssertPixels(stitcher.MakeImage(), Page(0, 205), check);
            }),
            ("静止帧报告未变化", () =>
            {
                var stitcher = new ScrollStitcher(ScrollAxis.Vertical);
                stitcher.Add(Window(0, 100));
                stitcher.Add(Window(20, 100));
                check(stitcher.Add(Window(20, 100)).Kind == Unchanged, "未变化");
            }),
            ("回滚不重复拼接", () =>
            {
                var stitcher = new ScrollStitcher(ScrollAxis.Vertical);
                stitcher.Add(Window(0, 100));
                stitcher.Add(Window(40, 100));
                var length = stitcher.Length;
                check(stitcher.Add(Window(25, 100)).Kind == Moved && stitcher.Length == length, "回滚");
            }),
            ("超出一屏时报告丢失重叠", () =>
            {
                var stitcher = new ScrollStitcher(ScrollAxis.Vertical);
                stitcher.Add(Window(0, 100));
                stitcher.Add(Window(10, 100));
                check(stitcher.Add(Window(400, 100)).Kind == Lost, "对不上");
            }),
            ("固定标题和底栏只出现一次", () =>
            {
                var stitcher = new ScrollStitcher(ScrollAxis.Vertical);
                const int header = 20, footer = 12, visible = 70;
                for (var i = 0; i <= 10; i++)
                    stitcher.Add(Window(i * 9, visible, header, footer));
                var expected = Page(0, header, 1).Concat(Page(0, visible + 90)).Concat(Page(0, footer, 2)).ToArray();
                check(stitcher.Length == expected.Length, "长度");
                AssertPixels(stitcher.MakeImage(), expected, check);
            }),
            ("达到长度上限后停止拼接", () =>
            {
                var stitcher = new ScrollStitcher(ScrollAxis.Vertical, maxLength: 130);
                stitcher.Add(Window(0, 100));
                var events = Enumerable.Range(1, 10).Select(i => stitcher.Add(Window(i * 10, 100)).Kind).ToArray();
                check(events.Contains(LimitReached) && stitcher.Length <= 130, "最大长度");
            }),
            ("迟到的内容覆盖已拼接的空白", () =>
            {
                var stitcher = new ScrollStitcher(ScrollAxis.Vertical);
                const int header = 10, footer = 10, visible = 80;
                stitcher.Add(Window(0, visible, header, footer));
                for (var offset = 30; offset <= 300; offset += 30)
                {
                    var rows = Page(0, header, 1).Concat(Page(offset, visible)).Concat(Page(0, footer, 2)).ToArray();
                    for (var y = header + visible - 20; y < header + visible; y++)
                        Array.Fill(rows[y], uint.MaxValue);
                    stitcher.Add(Frame(rows));
                    stitcher.Add(Window(offset, visible, header, footer));
                }
                AssertPixels(stitcher.MakeImage(), Page(0, header, 1).Concat(Page(0, 380)).Concat(Page(0, footer, 2)).ToArray(), check);
            }),
            ("固定区域占大多数时仍能找到滚动", () =>
            {
                var stitcher = new ScrollStitcher(ScrollAxis.Vertical);
                const int header = 120, footer = 120, visible = 60;
                stitcher.Add(Window(0, visible, header, footer));
                for (var i = 1; i <= 8; i++)
                    check(stitcher.Add(Window(i * 5, visible, header, footer)) == new ScrollStitcher.Result(Appended, 5), $"第 {i} 帧");
                check(stitcher.MakeImage()?.Height == header + visible + 40 + footer, "结果长度");
            }),
            ("固定侧栏只保留在第一屏", () => CheckSidebar(false, check)),
            ("侧栏动画不会被当成滚动内容", () => CheckSidebar(true, check)),
            ("横向逐列拼接并正确转回按行布局", () =>
            {
                var stitcher = new ScrollStitcher(ScrollAxis.Horizontal);
                for (var i = 0; i <= 9; i++)
                    stitcher.Add(Transpose(Window(i * 8, 84, 12, 9)));
                var expected = Frame(Page(0, 12, 1).Concat(Page(0, 156)).Concat(Page(0, 9, 2)).ToArray());
                var actual = stitcher.MakeImage();
                var target = Transpose(expected);
                check(actual?.Width == 177 && actual.Height == Width && actual.Pixels.AsSpan().SequenceEqual(target.Pixels), "横向像素");
            }),
            ("像素轻微变化仍按亮度轮廓找到滚动", () =>
            {
                var stitcher = new ScrollStitcher(ScrollAxis.Vertical, edgeMargin: (2, 4));
                stitcher.Add(Window(0, 100));
                var rows = Page(15, 100);
                for (var y = 0; y < rows.Length; y++)
                for (var x = 0; x < Width; x += 2)
                    rows[y][x] ^= 1;
                check(stitcher.Add(Frame(rows, 16), hint: 14) == new ScrollStitcher.Result(Appended, 15), "容差和行尾填充");
            }),
            ("预览只取末端并可按需降采样", () =>
            {
                var stitcher = new ScrollStitcher(ScrollAxis.Vertical);
                stitcher.Add(Window(0, 100));
                stitcher.Add(Window(18, 100));
                var preview = stitcher.Preview(30, 2)!;
                var colors = new[] { PageRow(92)[10], PageRow(92)[11], PageRow(93)[10], PageRow(93)[11] };
                var expected = 0xff000000u | (uint)(colors.Sum(c => (c >> 16) & 255) / 4) << 16 |
                    (uint)(colors.Sum(c => (c >> 8) & 255) / 4) << 8 | (uint)(colors.Sum(c => c & 255) / 4);
                check(preview.Width == 32 && preview.Height == 15 && preview.At(5, 2) == expected, "面积平均保留细节");
            }),
            ("首帧超过长度上限时安全裁剪", () =>
            {
                foreach (var axis in new[] { ScrollAxis.Vertical, ScrollAxis.Horizontal })
                {
                    var stitcher = new ScrollStitcher(axis, maxLength: 40);
                    stitcher.Add(axis == ScrollAxis.Vertical ? Window(0, 100) : Transpose(Window(0, 100)));
                    var image = stitcher.MakeImage()!;
                    check(stitcher.ReachedLimit && stitcher.Length == 40 &&
                        (axis == ScrollAxis.Vertical ? image.Height : image.Width) == 40, "首帧截断");
                }
            }),
            ("长截图控制条避让与预览按方向放置", () =>
            {
                var work = new System.Drawing.RectangleF(-1280, 0, 1280, 900);
                var region = new System.Drawing.RectangleF(-900, 220, 400, 300);
                var bar = LongCaptureLayout.Bar(region, new(500, 40), work);
                check(work.Contains(bar) && !bar.IntersectsWith(region), "控制条在工作区内避让选区");
                var vertical = LongCaptureLayout.Preview(region, bar, work, ScrollAxis.Vertical)!.Value;
                var horizontal = LongCaptureLayout.Preview(region, bar, work, ScrollAxis.Horizontal)!.Value;
                check(vertical.Left > region.Right && horizontal.Bottom < region.Top, "竖向右侧与横向上方预览");
            }),
            .. Cases22(check)
        ];
    }

    private static uint[] PageRow(int row, int seed = 0)
    {
        var pixels = new uint[Width];
        for (var x = 0; x < Width; x++)
        {
            var value = unchecked((uint)((row * 2654435761L) ^ ((x / 6 + seed * 97) * 40503L)));
            value ^= value >> 15;
            pixels[x] = 0xff000000 | (value & 0xffffff);
        }
        return pixels;
    }

    private static uint[][] Page(int start, int count, int seed = 0) =>
        Enumerable.Range(start, count).Select(y => PageRow(y, seed)).ToArray();

    private static ScrollFrame Window(int offset, int height, int header = 0, int footer = 0) =>
        Frame(Page(0, header, 1).Concat(Page(offset, height)).Concat(Page(0, footer, 2)).ToArray());

    private static ScrollFrame Frame(uint[][] rows, int padding = 0)
    {
        var stride = Width * 4 + padding;
        var bytes = new byte[stride * rows.Length];
        for (var y = 0; y < rows.Length; y++)
            MemoryMarshal.AsBytes(rows[y].AsSpan()).CopyTo(bytes.AsSpan(y * stride));
        return new ScrollFrame(Width, rows.Length, stride, bytes);
    }

    private static ScrollFrame Transpose(ScrollFrame source)
    {
        var bytes = new byte[source.Width * source.Height * 4];
        var dst = MemoryMarshal.Cast<byte, uint>(bytes.AsSpan());
        for (var x = 0; x < source.Width; x++)
        for (var y = 0; y < source.Height; y++)
            dst[x * source.Height + y] = source.At(x, y);
        return new ScrollFrame(source.Height, source.Width, source.Height * 4, bytes);
    }

    private static void AssertPixels(ScrollFrame? image, uint[][] expected, Action<bool, string> check)
    {
        var target = Frame(expected);
        check(image?.Width == Width && image.Height == target.Height, "像素尺寸");
        for (var y = 0; y < expected.Length; y++)
            check(image!.Pixels.AsSpan(y * image.Stride, Width * 4).SequenceEqual(target.Pixels.AsSpan(y * target.Stride, Width * 4)),
                $"第 {y} 行像素");
    }

    private static void CheckSidebar(bool animated, Action<bool, string> check)
    {
        const int height = 100;
        var stitcher = new ScrollStitcher(ScrollAxis.Vertical);
        for (var step = 0; step <= 12; step++)
        {
            var rows = new uint[height][];
            for (var y = 0; y < height; y++)
            {
                rows[y] = PageRow(step * 9 + y);
                PageRow(y, 3).AsSpan(40).CopyTo(rows[y].AsSpan(40));
                if (animated && y >= 5 && y < 9)
                    Array.Fill(rows[y], 0xff000000 | ((uint)(step * 7919) & 0xffffff), 58, 4);
            }
            stitcher.Add(Frame(rows));
        }
        var image = stitcher.MakeImage()!;
        check(image.Height == height + 108, "边栏场景的长度");
        for (var y = 0; y < image.Height; y++)
        {
            var expected = PageRow(y);
            for (var x = 0; x < 40; x++)
                check(image.At(x, y) == expected[x], $"正文像素 ({x}, {y})");
            if (y >= height)
                for (var x = 40; x < 58; x++)
                    check(image.At(x, y) == image.At(x, height), $"边栏像素 ({x}, {y})");
        }
    }
}
