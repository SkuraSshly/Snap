using System.Drawing;
using Velos.Core.Hotkeys;
using Velos.Core.LongCapture;
using Velos.Core.Screenshot;
using Velos.Core.Translation;
using Velos.Core.Animation;

internal static class ParityTests
{
    // 期望值直接来自 Mac CaptureCoordinator / PinManager / PinView / ThumbnailManager 的规则。
    internal static IEnumerable<(string, Action)> Cases(Action<bool, string> check)
    {
        yield return ("钉图大图：适配低于 10% 时仍可逐步缩放", () =>
        {
            var work = new RectangleF(0, 0, 1000, 800);
            var initial = PinLayout.Initial(new(20000, 20000), new(0, 0, 20000, 20000), work, work);
            var next = PinLayout.Zoom(new(20000, 20000), initial.Bounds, initial.Zoom, initial.Zoom * Math.Exp(.08), new(400, 400), work, null);
            check(next.Zoom > initial.Zoom && next.Zoom < initial.Zoom * 1.1, "一次滚动不能从 4% 突跳至 10%");
            var floor = Math.Min(initial.Zoom, .1);
            var backward = PinLayout.Zoom(new(20000, 20000), next.Bounds, next.Zoom, PinLayout.WheelZoom(next.Zoom, -120, floor), new(433, 433), work, null, minimumZoom: floor);
            check(Math.Abs(backward.Zoom - initial.Zoom) < 1e-8, "可以反向缩回初始适配比例");
        });
        yield return ("钉图滚轮：高精度分段、方向与极端输入", () =>
        {
            var split = 1d; for (var i = 0; i < 120; i++) split = PinLayout.WheelZoom(split, 1);
            check(Math.Abs(split - PinLayout.WheelZoom(1, 120)) < 1e-10, "高精度滚轮不吞小增量");
            check(Math.Abs(PinLayout.WheelZoom(PinLayout.WheelZoom(1, 240), -240) - 1) < 1e-10, "反向恢复比例");
            check(PinLayout.WheelZoom(1, int.MaxValue) == 8 && PinLayout.WheelZoom(1, int.MinValue) == .1 && PinLayout.WheelZoom(1, 0) == 1, "上下限与零输入");
        });
        yield return ("Mac 动效：开关弹簧从静止开始，轻微回弹并收敛", () =>
        {
            var motion = new SpringMotion(0, 15, 0, .3, .68);
            check(motion.Sample(0) == new SpringSample(0, 0), "初始状态");
            check(motion.Sample(.05).Value is > 0 and < 15, "可见滑动中间帧");
            check(motion.Sample(.2).Value is > 15 and < 16, "回弹不超过圆钮边缘");
            check(Math.Abs(motion.Sample(1).Value - 15) < .001 && motion.SettlingDuration is > .3 and < .7, "阻尼收敛，有界时长");
        });
        yield return ("Mac 动效：连续反向保留位置与速度", () =>
        {
            var first = new SpringMotion(0, 15, 0, .3, .68).Sample(.08);
            var reverse = new SpringMotion(first.Value, 0, first.Velocity, .3, .68);
            check(reverse.Sample(0) == first, "切换瞬间不跳位、不清零速度");
            var derivative = (reverse.Sample(.000001).Value - first.Value) / .000001;
            check(Math.Abs(derivative - first.Velocity) < .01, "位置导数与继承速度一致");
            check(Math.Abs(reverse.Sample(1).Value) < .001, "连续切换最后准确归零");
        });
        yield return ("Mac 缩略图：easeOut 单调且无回弹", () =>
        {
            var samples = Enumerable.Range(0, 101).Select(i => SpringMotion.EaseOut(i / 100d)).ToArray();
            check(samples[0] == 0 && samples[^1] == 1 && samples.Zip(samples.Skip(1)).All(pair => pair.First <= pair.Second), "起终点准确、无过冲");
            check(Math.Abs(SpringMotion.EaseOut(.5) - .684643) < .00001, "Core Animation easeOut 中点");
        });
        yield return ("Mac 2.4 OCR：候选不能丢失原文的非拉丁文字", () =>
        {
            check(!OcrCandidateRules.KeepsScripts("Velos translate test / 截屏翻译自测", "Velos translate test / ÄMì·áN"), "中字不能被拉丁乱码替代");
            check(OcrCandidateRules.KeepsScripts("Velos translate test / 截屏翻译自测", "Velos translate test / 截屏翻译自测"), "中英混排完整结果保留");
            foreach (var text in new[] { "仮名", "한국어", "Русский", "Ελληνικά", "العربية", "עברית", "ภาษาไทย", "हिन्दी", "\U00020000" })
                check(!OcrCandidateRules.KeepsScripts(text, "Abcdefghijklmnop"), "独立保护文字系统与补充平面汉字");
            check(OcrCandidateRules.KeepsScripts("一二三四五六七八九十", "一二三四五六七八九") && !OcrCandidateRules.KeepsScripts("一二三四五六七八九十", "一二三四五六七八"), "九成阈值");
        });
        yield return ("Mac 会话规则：其他选区快捷键不取消正在进行的选区", () =>
        {
            check(!CaptureSessionRules.Accept(HotkeyAction.Screenshot, HotkeyAction.Recording, false), "录屏选区期间不截图");
            check(!CaptureSessionRules.Accept(HotkeyAction.Screenshot, HotkeyAction.Translation, false), "翻译选区期间不截图");
            check(!CaptureSessionRules.Accept(HotkeyAction.Recording, HotkeyAction.Translation, false), "翻译选区期间不录屏");
            check(!CaptureSessionRules.Accept(HotkeyAction.Translation, HotkeyAction.Screenshot, false), "截图期间不切到翻译");
            check(CaptureSessionRules.Accept(HotkeyAction.Screenshot, HotkeyAction.Screenshot, false), "同一快捷键切换区域全屏");
            check(CaptureSessionRules.Accept(HotkeyAction.Translation, null, false), "录制中无选区，允许翻译");
            check(!CaptureSessionRules.Accept(HotkeyAction.Screenshot, HotkeyAction.Screenshot, true), "长截图期间忽略快捷键");
        });
        yield return ("Mac 2.4.2 钉图：原大小原位，只在超出屏幕时适配", () =>
        {
            var screen = new RectangleF(0, 0, 1000, 800); var work = new RectangleF(0, 0, 1000, 760);
            var small = PinLayout.Initial(new(200, 100), new(120, 80, 200, 100), screen, work);
            check(small.Bounds == new RectangleF(120, 80, 200, 100) && small.Zoom == 1, "小图原位");
            var large = PinLayout.Initial(new(1000, 760), screen, screen, work);
            check(large.Bounds == new RectangleF(0, 0, 1000, 760) && large.Zoom == 1, "超过 80% 仍保留原像素");
            check(PinLayout.Initial(screen.Size, screen, screen, work).Bounds == screen, "全屏钉图不缩小");
            var oversized = PinLayout.Initial(new(2000, 1600), new(0, 0, 2000, 1600), screen, work);
            check(oversized.Bounds == new RectangleF(25, 0, 950, 760) && Math.Abs(oversized.Zoom - .475) < .000001, "超屏正好适配");
            check(PinLayout.Initial(new(300, 200), new(-200, -100, 300, 200), screen, work).Bounds.Location == new PointF(0, 0), "部分在屏幕内时挪回工作区");
            check(PinLayout.Initial(new(300, 200), new(-800, -500, 300, 200), screen, work).Bounds.Location == new PointF(350, 280), "完全离屏时居中");
        });
        yield return ("Mac 钉图：长图按 2.5 比例识别，保留可读宽度和 85% 视口", () =>
        {
            var work = new RectangleF(-1200, 0, 1000, 800);
            var vertical = PinLayout.Initial(new(800, 10000), new(), work, work);
            check(vertical.Axis == ScrollAxis.Vertical && vertical.Bounds.Size == new SizeF(800, 680), "竖图原宽度与 85% 纵向");
            var horizontal = PinLayout.Initial(new(10000, 800), new(), work, work);
            check(horizontal.Axis == ScrollAxis.Horizontal && horizontal.Bounds.Size == new SizeF(850, 800), "横图 85% 横向与原高度");
            check(PinLayout.Initial(new(600, 5000), new(-1100, 200, 600, 400), work, work).Bounds == new RectangleF(-1100, 120, 600, 680), "长图原位，溢出工作区时内移");
            check(PinLayout.LongAxis(new(100, 250)) is null && PinLayout.LongAxis(new(100, 251)) == ScrollAxis.Vertical, "严格大于 2.5");
        });
        yield return ("Mac 钉图：缩放保持鼠标锚点，可放大超过屏幕", () =>
        {
            var old = new RectangleF(100, 100, 200, 100); var work = new RectangleF(0, 0, 1000, 800);
            var next = PinLayout.Zoom(new(200, 100), old, 1, 8, new(50, 25), work, null);
            check(next.Bounds == new RectangleF(-250, -75, 1600, 800) && next.Zoom == 8, "锚点固定，不被屏幕宽度限制");
            check(PinLayout.Zoom(new(40, 40), old, 1, .1, new(), work, null).Bounds == old, "小于 20 单位不继续缩小");
            check(Math.Abs(PinLayout.WheelOpacity(.8, 120) - .84) < .0001 && PinLayout.WheelOpacity(.2, -120) == .2, "透明度步长与下限");
        });
        yield return ("极小钉图仍能逐步放大，不被最小窗口尺寸锁住", () =>
        {
            var old = new RectangleF(100, 100, 8, 8);
            var next = PinLayout.Zoom(new(8, 8), old, 1, 1.1, new(4, 4), new(0, 0, 1000, 800), null, 30);
            check(next.Zoom > 1 && next.Bounds.Width > old.Width, "放大方向不应被缩小下限阻断");
            check(PinLayout.Zoom(new(8, 8), old, 1, .9, new(4, 4), new(0, 0, 1000, 800), null, 30).Zoom == 1, "仍阻止继续缩小极小图片");
        });
        yield return ("钉图边缘：八方向、内部、边界外和极小图片命中", () =>
        {
            var cases = new (PointF Point, PinEdge Edge)[] { (new(1, 50), PinEdge.Left), (new(199, 50), PinEdge.Right),
                (new(100, 1), PinEdge.Top), (new(100, 99), PinEdge.Bottom), (new(4, 8), PinEdge.Left | PinEdge.Top),
                (new(196, 8), PinEdge.Right | PinEdge.Top), (new(4, 92), PinEdge.Left | PinEdge.Bottom), (new(196, 92), PinEdge.Right | PinEdge.Bottom),
                (new(8, 8), PinEdge.None),
                (new(100, 50), PinEdge.None), (new(-1, 50), PinEdge.None), (new(201, 50), PinEdge.None) };
            foreach (var (point, edge) in cases) check(PinLayout.EdgeAt(point, new(200, 100)) == edge, $"{point} 命中 {edge}");
            check(PinLayout.EdgeAt(new(4, 4), new(8, 8)) == PinEdge.None && PinLayout.EdgeAt(new(0, 4), new(8, 8)) == PinEdge.Left, "小图仍保留内部移动区");
        });
        yield return ("钉图边缘：边与角缩放固定对侧并保持原图比例", () =>
        {
            var start = new RectangleF(-800, 100, 600, 400); var work = new RectangleF(-1200, 0, 1200, 900);
            var cases = new (PinEdge Edge, PointF Delta, RectangleF Bounds)[] {
                (PinEdge.Right, new(300, 0), new(-800, 0, 900, 600)), (PinEdge.Left, new(-300, 0), new(-1100, 0, 900, 600)),
                (PinEdge.Top, new(0, -200), new(-950, -100, 900, 600)), (PinEdge.Bottom, new(0, 200), new(-950, 100, 900, 600)),
                (PinEdge.Right | PinEdge.Bottom, new(300, 200), new(-800, 100, 900, 600)),
                (PinEdge.Left | PinEdge.Top, new(-300, -200), new(-1100, -100, 900, 600)),
                (PinEdge.Left | PinEdge.Bottom, new(-300, 200), new(-1100, 100, 900, 600)),
                (PinEdge.Right | PinEdge.Top, new(300, -200), new(-800, -100, 900, 600)) };
            foreach (var (edge, delta, bounds) in cases) { var next = PinLayout.ResizeFromEdge(new(600, 400), start, 1, edge, delta, work, null);
                check(next.Bounds == bounds && next.Zoom == 1.5, $"{edge} 固定对侧，不拉伸"); }
        });
        yield return ("钉图边缘：混合 DPI 使用物理像素，越过对边不翻转", () =>
        {
            foreach (var dpi in new[] { 1f, 1.25f, 1.5f, 2f }) {
                var start = new RectangleF(-1000, 100, 600, 400); var work = new RectangleF(-2000, 0, 2000, 1200);
                var next = PinLayout.ResizeFromEdge(new(600, 400), start, 1, PinEdge.Right, new(-10000, 0), work, null, 20 * dpi);
                check(next.Bounds.Width > 0 && next.Bounds.Height >= 20 * dpi && next.Bounds.Left == start.Left, $"{dpi} DPI 越界仍有最小尺寸");
                var max = PinLayout.ResizeFromEdge(new(600, 400), start, 1, PinEdge.Left, new(-10000, 0), work, null, 20 * dpi);
                check(max.Zoom == 8 && max.Bounds.Right == start.Right, "800% 上限，对边不漂移");
                check(PinLayout.EdgeAt(new(2, 50), new(200, 100)) == PinEdge.Left, "命中区以 DIP 统一");
            }
            check(PinLayout.ResizeFromEdge(new(8, 8), new(0, 0, 8, 8), 1, PinEdge.Right, new(4, 0), new(0, 0, 1000, 800), null, 30).Zoom == 1.5, "极小图仍可放大");
        });
        yield return ("Mac 2.4.2 长钉图：短轴缩放，长轴只改视口", () =>
        {
            var work = new RectangleF(0, 0, 1200, 1000);
            var vertical = PinLayout.ResizeFromEdge(new(240, 3000), new(100, 100, 240, 850), 1, PinEdge.Right, new(120, 0), work, ScrollAxis.Vertical);
            check(vertical.Zoom == 1.5 && vertical.Bounds.Size == new SizeF(360, 850), "纵向视口不超 85%，图像高度仍按 4500 像素显示");
            var horizontal = PinLayout.ResizeFromEdge(new(3000, 240), new(100, 100, 1020, 240), 1, PinEdge.Bottom, new(0, -120), work, ScrollAxis.Horizontal);
            check(horizontal.Zoom == .5 && horizontal.Bounds.Size == new SizeF(1020, 120), "短轴缩放后长轴仍受 85% 上限约束");
            var top = PinLayout.ResizeFromEdge(new(240, 3000), new(100, 100, 240, 850), 1, PinEdge.Top, new(0, 200), work, ScrollAxis.Vertical);
            check(top.Zoom == 1 && top.Bounds == new RectangleF(100, 300, 240, 650), "上边只收视口，下边固定");
            var right = PinLayout.ResizeFromEdge(new(3000, 240), new(100, 100, 1020, 240), 1, PinEdge.Right, new(9000, 0), work, ScrollAxis.Horizontal);
            check(right.Zoom == 1 && right.Bounds == new RectangleF(100, 100, 3000, 240), "横图长轴可展开整张，不拉伸图像");
            var corner = PinLayout.ResizeFromEdge(new(600, 400), new(100, 100, 600, 400), 1, PinEdge.Right | PinEdge.Bottom, new(60, 200), work, null);
            check(corner.Zoom == 1.5, "拖角按相对位移更大的方向缩放");
        });
        yield return ("Mac 缩略图：所有比例使用统一的可操作尺寸", () =>
        {
            check(ScreenshotLayout.ThumbnailSize(new(8, 8), 1) == new SizeF(60, 40), "小图最小尺寸");
            check(ScreenshotLayout.ThumbnailSize(new(400, 8000), 2) == new SizeF(150, 150), "长图保留按钮空间");
            check(ScreenshotLayout.ThumbnailSize(new(2400, 1600), 2) == new SizeF(225, 150), "普通图按比例");
        });
        yield return ("Mac 编辑器：按视口选择长图滚动方向，不依赖长截图标记", () =>
        {
            check(ScreenshotLayout.EditorFitAxis(new(500, 4000), new(800, 600)) == FitAxis.Width, "普通竖长图也按宽度显示");
            check(ScreenshotLayout.EditorFitAxis(new(4000, 500), new(800, 600)) == FitAxis.Height, "普通横长图也按高度显示");
            check(ScreenshotLayout.EditorFitAxis(new(500, 300), new(800, 600)) == FitAxis.Both, "普通图片完整显示");
        });
    }
}
