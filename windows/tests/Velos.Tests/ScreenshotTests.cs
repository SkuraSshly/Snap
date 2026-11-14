using System.Drawing;
using Velos.Core.Hotkeys;
using Velos.Core.Screenshot;

internal static class ScreenshotTests
{
    public static (string Name, Action Run)[] Cases(Action<bool, string> check)
    {
        var screen = new RectangleF(0, 0, 1000, 800);
        var bar = new SizeF(300, 40);
        return
        [
            ("工具栏在选区下方右对齐", () =>
                check(ScreenshotLayout.ToolbarOrigin(bar, new RectangleF(200, 300, 400, 200), screen) == new PointF(300, 508), "下方右对齐")),
            ("工具栏下方放不下时放到上方并让出尺寸标签", () =>
                check(ScreenshotLayout.ToolbarOrigin(bar, new RectangleF(200, 580, 400, 200), screen).Y == 510, "让出尺寸标签")),
            ("工具栏上下都放不下时移入选区", () =>
                check(ScreenshotLayout.ToolbarOrigin(bar, new RectangleF(200, 20, 400, 770), screen).Y == 742, "选区内底部")),
            ("全屏工具栏在屏幕底部中央", () =>
                check(ScreenshotLayout.ToolbarOrigin(bar, null, screen) == new PointF(350, 732), "居中")),
            ("工具栏两端保留边距", () =>
            {
                check(ScreenshotLayout.ToolbarOrigin(bar, new RectangleF(0, 300, 100, 100), screen).X == 4, "左端");
                check(ScreenshotLayout.ToolbarOrigin(bar, new RectangleF(900, 300, 200, 100), screen).X == 696, "右端");
            }),
            ("编辑器按较小的宽高比例适配", () =>
                check(ScreenshotLayout.FitScale(new SizeF(400, 300), new SizeF(800, 450)) == 1.5, "完整图像")),
            ("竖向和横向画布可按单轴适配", () =>
            {
                check(ScreenshotLayout.FitScale(new SizeF(400, 3000), new SizeF(600, 500), FitAxis.Width) == 1.5, "宽度");
                check(ScreenshotLayout.FitScale(new SizeF(3000, 200), new SizeF(600, 100), FitAxis.Height) == 0.5, "高度");
            }),
            ("空画布可以计算编辑器比例", () =>
                check(ScreenshotLayout.FitScale(SizeF.Empty, new SizeF(10, 10)) == 1, "零尺寸")),
            ("缩略图保持比例且小图不放大", () =>
            {
                check(ScreenshotLayout.ThumbnailScale(new SizeF(400, 300), 1) == 0.5, "大图缩小");
                check(ScreenshotLayout.ThumbnailScale(new SizeF(100, 60), 2) == 0.5, "保持小图原始物理尺寸");
            }),
            ("方向键微调步长与修饰键", () =>
            {
                check(ScreenshotLayout.ArrowStep(HotkeyModifiers.None) == 1, "1 像素");
                check(ScreenshotLayout.ArrowStep(HotkeyModifiers.Shift) == 10, "10 像素");
                check(ScreenshotLayout.ArrowStep(HotkeyModifiers.Control | HotkeyModifiers.Shift) is null, "Ctrl");
                check(ScreenshotLayout.ArrowStep(HotkeyModifiers.Alt) is null, "Alt");
            }),
            ("框选支持反向拖拽和负坐标", () =>
                check(RegionGeometry.Between(new Point(200, 120), new Point(-10, 30)) ==
                      new Rectangle(-10, 30, 210, 90), "物理像素")),
            ("选区移动和控制点限制在本屏", () =>
            {
                var bounds = new Rectangle(0, 0, 800, 600);
                var area = new Rectangle(10, 20, 200, 120);
                check(RegionGeometry.Move(area, -90, 900, bounds) == new Rectangle(0, 480, 200, 120), "移动");
                check(RegionGeometry.Resize(area, RegionHandle.BottomRight, new Point(810, 630), bounds) ==
                      new Rectangle(10, 20, 790, 580), "右下角控制点");
                check(RegionGeometry.Resize(area, RegionHandle.TopLeft, new Point(700, 500), bounds) ==
                      new Rectangle(209, 139, 1, 1), "最小尺寸");
            })
        ];
    }
}
