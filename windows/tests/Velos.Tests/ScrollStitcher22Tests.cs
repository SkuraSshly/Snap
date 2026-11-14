using System.Drawing;
using Velos.Core.LongCapture;
using static Velos.Core.LongCapture.ScrollStitcher.EventKind;

internal static partial class ScrollStitcherTests
{
    private static (string Name, Action Run)[] Cases22(Action<bool, string> check) =>
    [
        ("2.2：大片固定栏下甩太远不把错位画面当重绘", () =>
        {
            var s = new ScrollStitcher(ScrollAxis.Vertical);
            foreach (var offset in new[] { 0, 5, 10 }) s.Add(Window(offset, 60, 120, 120));
            check(s.Add(Window(300, 60, 120, 120)).Kind == Lost && s.Add(Window(305, 60, 120, 120)).Kind == Lost, "不覆盖旧内容");
            check(s.Add(Window(15, 60, 120, 120)).Added == 5 && s.Add(Window(20, 60, 120, 120)).Added == 5, "回到重叠继续");
            AssertPixels(s.MakeImage(), Page(0, 120, 1).Concat(Page(0, 80)).Concat(Page(0, 120, 2)).ToArray(), check);
        }),
        ("2.2：首下无重叠、页面加载和过渡画面更新起点", () =>
        {
            var s = new ScrollStitcher(ScrollAxis.Vertical); s.Add(Frame(Page(0, 100, 9))); s.Add(Frame(Page(0, 100, 4)));
            check(s.Add(Window(400, 100)).Kind == Unchanged, "等待真实滚动");
            check(s.Add(Window(408, 100)).Added == 8, "从最新起点拼接"); AssertPixels(s.MakeImage(), Page(400, 108), check);
        }),
        ("2.2：回滚预览跟随当前位置而非缓冲末尾", () =>
        {
            var s = new ScrollStitcher(ScrollAxis.Vertical); for (var i = 0; i <= 200; i += 10) s.Add(Window(i, 100));
            AssertPixels(s.Preview(50), Page(250, 50), check); check(s.Add(Window(160, 100)).Kind == Moved, "回滚");
            AssertPixels(s.Preview(50), Page(210, 50), check);
            AssertPixels(s.PreviewSized(64, 50), Page(210, 50), check);
            var resized = s.PreviewSized(37, 77)!; check(resized.Width == 37 && resized.Height == 77, "按面板真实像素直接生成");
        }),
        ("2.2：连续 15 帧跟丢且精确前进后接回，明确跳过漏掉的段", () =>
        {
            var s = new ScrollStitcher(ScrollAxis.Vertical); foreach (var i in new[] { 0, 10, 20 }) s.Add(Window(i, 100));
            for (var i = 0; i < 15; i++) check(s.Add(Window(600 + i * 4, 100)).Kind == (i == 14 ? Appended : Lost), "只在稳定滚动后接回");
            check(s.Add(Window(663, 100)).Added == 7, "恢复后相邻拼接"); AssertPixels(s.MakeImage(), Page(0, 120).Concat(Page(656, 107)).ToArray(), check);
        }),
        ("2.2：向后甩远不能重复接回", () =>
        {
            var s = new ScrollStitcher(ScrollAxis.Vertical); for (var i = 0; i <= 400; i += 20) s.Add(Window(i, 100));
            for (var i = 0; i < 30; i++) s.Add(Window(150 - i * 3, 100));
            check(s.Length == 500 && s.Add(Window(420, 100)).Added == 20, "保持已有长度直到回到重叠"); AssertPixels(s.MakeImage(), Page(0, 520), check);
        }),
        ("2.2：任务视图式带抖动动画不算稳定前进", () =>
        {
            var s = new ScrollStitcher(ScrollAxis.Vertical); for (var i = 0; i <= 60; i += 10) s.Add(Window(i, 100));
            for (var k = 0; k < 40; k++)
                check(s.Add(Frame(Jitter(Page(5000 + k * 6, 100, 9), k))).Kind is Lost or Unchanged, "不接入过渡动画");
            s.Add(Window(60, 100)); for (var i = 70; i <= 120; i += 10) check(s.Add(Window(i, 100)).Added == 10, "返回页面继续");
            AssertPixels(s.MakeImage(), Page(0, 220), check);
        }),
        ("2.2：半透明顶栏只在开头出现一次", () =>
        {
            var s = new ScrollStitcher(ScrollAxis.Vertical);
            for (var k = 0; k <= 12; k++) s.Add(Frame(Enumerable.Range(0, 100).Select(y => y < 10 ? PageRow(y * 13 + k * 9 * 101, 7) : PageRow(k * 9 + y)).ToArray()));
            AssertPixels(s.MakeImage(), Enumerable.Range(0, 10).Select(y => PageRow(y * 13, 7)).Concat(Page(10, 198)).ToArray(), check);
        }),
        ("2.2：每帧两像素时半透明标题栏不进入正文", () =>
        {
            var s = new ScrollStitcher(ScrollAxis.Vertical);
            for (var k = 0; k <= 40; k++)
            {
                var rows = Enumerable.Range(0, 100).Select(y => y < 12 ? PageRow(y / 6, 7) : PageRow(k * 2 + y)).ToArray();
                for (var y = 0; y < 12; y++) for (var x = 0; x < Width; x++) if (k > 0 && (y * Width + x + k) % 3 == 0) rows[y][x] = Nudge(rows[y][x]);
                s.Add(Frame(rows));
            }
            var result = s.MakeImage()!; check(result.Height == 180, "长度");
            for (var y = 12; y < 180; y++) for (var x = 0; x < Width; x++) check((result.At(x, y) & 0xffffff00) == (PageRow(y)[x] & 0xffffff00), "细滚动正文");
        }),
        ("2.2：带细微抖动的正文仍可识别固定侧栏", () =>
        {
            var s = new ScrollStitcher(ScrollAxis.Vertical);
            for (var k = 0; k <= 12; k++)
            {
                var rows = Enumerable.Range(0, 100).Select(y => PageRow(k * 9 + y).Take(40).Concat(PageRow(y, 3).Skip(40)).ToArray()).ToArray();
                s.Add(Frame(Jitter(rows, k, 40)));
            }
            var result = s.MakeImage()!; check(result.Height == 208, "长度");
            for (var x = 40; x < 58; x++) check(Enumerable.Range(100, result.Height - 100).Select(y => result.At(x, y) & 0xffffff00).Distinct().Count() == 1, "侧栏只填背景");
        }),
        ("2.2：侧栏中途吸顶后停止重复，正文逐像素连续", () =>
        {
            var s = new ScrollStitcher(ScrollAxis.Vertical);
            for (var k = 0; k <= 30; k++) s.Add(Frame(Enumerable.Range(0, 100).Select(y => PageRow(k * 9 + y).Take(40).Concat(PageRow(Math.Min(k, 3) * 9 + y, 3).Skip(40)).ToArray()).ToArray()));
            var result = s.MakeImage()!; check(result.Height == 370, "长度");
            for (var x = 40; x < 58; x++) check(Enumerable.Range(181, result.Height - 181).Select(y => result.At(x, y)).Distinct().Count() == 1, "中途吸顶");
            for (var y = 0; y < result.Height; y++) for (var x = 0; x < 40; x++) check(result.At(x, y) == PageRow(y)[x], "正文连续");
        }),
        ("2.2：自动滚动移出暂停、移回继续并保持限速", () =>
        {
            var auto = new AutoScroll(new RectangleF(0, 0, 400, 600)); var point = new PointF(20, 20);
            auto.Start(point, 0); var total = Enumerable.Range(0, 60).Sum(i => auto.Tick(point, i / 60d));
            check(total is >= 197 and <= 198 && auto.State == AutoScroll.Status.Running, "每秒三分之一高");
            check(auto.Tick(new PointF(500, 0), 2) == 0 && auto.State == AutoScroll.Status.Paused, "移出暂停");
            check(auto.Tick(point, 3) > 0 && auto.State == AutoScroll.Status.Running, "移回立即继续");
            auto.Stop(AutoScroll.Reason.Limit); check(!auto.Active && auto.Tick(point, 4) == 0 && auto.StopReason == AutoScroll.Reason.Limit, "长度上限停止");
        }),
        ("2.2：到底只在曾有进展的同一指针位置认定", () =>
        {
            var auto = new AutoScroll(new RectangleF(0, 0, 400, 600)); var p = new PointF(20, 20); auto.Start(p, 0);
            auto.Tick(p, 5); check(auto.Active, "开始没滚动不能误认为到底"); auto.NoteMotion(2, p, 5);
            auto.Tick(new PointF(100, 100), 7); check(auto.Active, "移到不可滚区域不结束");
            auto.Tick(p, 7.1); check(!auto.Active && auto.StopReason == AutoScroll.Reason.ReachedEnd, "同位置停止");
        }),
        ("2.2：连续三帧反向才纠正自动方向，速度有上下限", () =>
        {
            var auto = new AutoScroll(new RectangleF(0, 0, 400, 200)); var p = new PointF(20, 20); auto.Start(p, 0);
            auto.NoteMotion(-2, p, .1); auto.NoteMotion(-2, p, .2); check(auto.Tick(p, .2) > 0, "两帧不反转");
            auto.NoteMotion(-2, p, .3); check(auto.Tick(p, .3) < 0, "三帧反转");
            check(auto.Speed == 150 && new AutoScroll(new RectangleF(0, 0, 400, 3000)).Speed == 450, "速度界限");
        })
    ];

    private static uint Nudge(uint p) => (p & 0xffffff00) | ((p & 255) == 255 ? 254 : (p & 255) + 1);
    private static uint[][] Jitter(uint[][] rows, int seed, int columns = int.MaxValue)
    {
        for (var y = 0; y < rows.Length; y++) for (var x = 0; x < Width; x++)
            if ((y * Width + x + seed) % 3 == 0 && x < columns) rows[y][x] = Nudge(rows[y][x]);
        return rows;
    }
}
