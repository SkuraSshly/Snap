#if DEBUG
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velos.Core.Settings;
using Velos.Screenshot;

namespace Velos;

public partial class App
{
    private async Task VerifyAnnotationParity(string profile, Action<bool, string> check)
    {
        var photo = SyntheticImage(900, 600);
        var host = new Window { Title = "Velos 标注行为自测", Width = 950, Height = 740, WindowStartupLocation = WindowStartupLocation.CenterScreen };
        MarkCanvas Fresh(double scale = 1)
        {
            var styles = new Dictionary<Tool, ToolStyle>();
            var canvas = new MarkCanvas(photo, scale, tool => styles.GetValueOrDefault(tool) ?? ToolInfo.Default(tool), (tool, value) => styles[tool] = value)
            { Width = 900 / scale, Height = 600 / scale, ViewScale = 1 / scale, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
            host.Content = canvas; return canvas;
        }
        host.Show();
        try
        {
            foreach (var scale in new[] { 1d, 1.25, 1.5, 2 })
            {
                var canvas = Fresh(scale); canvas.SelectTool(Tool.Pen);
                canvas.DebugPress(new Point(40, 40)); canvas.DebugRelease(new Point(40, 40));
                check(canvas.DebugMarks.Count == 0, $"Mac {scale * 100:0}%：单击画笔不留下孤立点");
                canvas.SelectTool(Tool.Rectangle); canvas.DebugStroke(new Point(40, 40), new Point(40 + scale * 2, 60));
                canvas.SelectTool(Tool.Line); canvas.DebugStroke(new Point(40, 40), new Point(40 + scale * 3, 40));
                check(canvas.DebugMarks.Count == 0, $"Mac {scale * 100:0}%：小于 3 点的框和 4 点的线视为误触");

                canvas.SelectTool(Tool.Rectangle); canvas.DebugStroke(new Point(100, 100), new Point(220, 180));
                var mark = canvas.DebugMarks.Single();
                check(mark.Bounds.Left == 100 - 2 * scale && !mark.Hit(new Point(160, 140), scale) &&
                    !mark.Hit(new Point(100 - 3.5 * scale, 140), scale), $"Mac {scale * 100:0}%：外框包含线宽，空心内部和远离线条处不抢点击");
                canvas.DebugStroke(new Point(160, 100), new Point(160, 100));
                canvas.HandleEditingKey(Key.Right, ModifierKeys.Shift); canvas.Undo();
                check(canvas.DebugSelected == 0 && canvas.DebugMarks[0].Id == mark.Id && canvas.DebugMarks[0].Points.SequenceEqual(mark.Points),
                    $"Mac {scale * 100:0}%：撤销移动后保留仍存在的标注选中状态");
                var style = canvas.DebugMarks[0].Style;
                canvas.SetStyle(style with { Size = 7 }); canvas.SetStyle(style with { Size = 9, Opacity = .5 }); canvas.Undo();
                check(canvas.DebugMarks[0].Style == style && canvas.DebugSelected == 0, $"Mac {scale * 100:0}%：一秒内连续改样式合并撤销并保留选中");
                canvas.SelectTool(Tool.Pen);
                check(canvas.ActiveTool == Tool.Pen && canvas.DebugSelected == 0, $"Mac {scale * 100:0}%：绘图工具与已有标注选择分开保存");

                canvas = Fresh(scale); canvas.SelectTool(Tool.Text); canvas.DebugPress(new Point(890, 570));
                var editor = canvas.DebugTextEditor!; editor.Text = new string('W', 70) + "\n合成文字";
                canvas.SetStyle(new ToolStyle(0xffcc00, 30, .4, true));
                check(Math.Abs(editor.Margin.Left - 890 / scale) < .00001 && Math.Abs(editor.Margin.Top - 570 / scale) < .00001 && editor.TextWrapping == TextWrapping.NoWrap && editor.Width > 420 &&
                    editor.FontSize == 30 && editor.Foreground == Brushes.Black && editor.Opacity == .4 && canvas.DebugMarks.Count == 0,
                    $"Mac {scale * 100:0}%：文字锚点不位移、不自动折行，颜色字号底色和透明度实时应用");
                check(!canvas.HandleEditingKey(Key.Enter, ModifierKeys.Shift) && canvas.EditingText, $"Mac {scale * 100:0}%：Shift+Enter 留给文字输入框换行");
                canvas.HandleEditingKey(Key.Enter, ModifierKeys.None);
                check(!canvas.EditingText && canvas.DebugMarks.Single().Style == new ToolStyle(0xffcc00, 30, .4, true),
                    $"Mac {scale * 100:0}%：Enter 只确认文字，输出使用最终样式");
            }
            var textCanvas = Fresh(); textCanvas.SelectTool(Tool.Text); textCanvas.DebugPress(new Point(100, 100)); textCanvas.DebugTextEditor!.Text = "合成文字";
            textCanvas.DebugPress(new Point(500, 300));
            check(textCanvas.DebugMarks.Count == 1 && !textCanvas.EditingText, "Mac：输入文字后点别处只确认这段文字，不额外创建新输入框");

            var clipped = Fresh(); clipped.SelectTool(Tool.Rectangle); clipped.DebugStroke(new Point(850, 500), new Point(890, 600), true);
            check(clipped.DebugMarks.Single().Frame is { Width: 50, Height: 100 }, "Mac：Shift 形状触边后按画布相交裁切，不整体缩小");
            var arrow = new Mark(Tool.Arrow, new ToolStyle(0xff3b30, 2), 2, [new Point(100, 100), new Point(250, 100)]);
            check(arrow.Hit(new Point(231, 107), 2), "Mac：箭头头部三角形可直接命中，不只认中心线");
            check(MarkRenderer.CounterContrast(Color.FromRgb(51, 199, 89)) == Brushes.White && MarkRenderer.TextContrast(Color.FromRgb(51, 199, 89)) == Brushes.Black,
                "Mac：序号与文字底色各用原来的字色规则");

            foreach (var tool in new[] { Tool.Mosaic, Tool.Blur })
            {
                var mark = new Mark(tool, ToolInfo.Default(tool), 1, [new Point(40, 40), new Point(180, 160)]);
                byte[] Render(bool draft)
                {
                    var visual = new DrawingVisual(); using (var dc = visual.RenderOpen()) { dc.DrawImage(photo, new Rect(0, 0, 900, 600)); var renderer = new MarkRenderer(photo); if (draft) renderer.Draw(dc, [], mark); else renderer.Draw(dc, [mark]); }
                    var image = new RenderTargetBitmap(900, 600, 96, 96, PixelFormats.Pbgra32); image.Render(visual);
                    var bytes = new byte[900 * 600 * 4]; image.CopyPixels(bytes, 900 * 4, 0); return bytes;
                }
                check(Render(true).SequenceEqual(Render(false)), $"Mac：{ToolInfo.For(tool).Name}拖动预览与最终像素一致，不显示占位色块");
            }
            var edge = new byte[201 * 4]; for (var x = 100; x < 201; x++) edge[x * 4] = edge[x * 4 + 1] = edge[x * 4 + 2] = 255;
            PixelEffects.Blur(edge, 201, 1, 10);
            check(edge[90 * 4] is >= 35 and <= 55 && edge[0] == 0 && edge[^4] == 255, "Mac：模糊强度代表高斯 sigma，边缘延伸不发黑");

            var paint = Fresh(); paint.SelectTool(Tool.Text); paint.DebugPress(new Point(100, 100)); paint.DebugTextEditor!.Text = "实时颜色预览";
            var anchor = new Button { Content = "合成调色盘锚点", Width = 160, Height = 30 };
            host.Content = null;
            var layout = new DockPanel(); DockPanel.SetDock(anchor, Dock.Bottom); layout.Children.Add(anchor); layout.Children.Add(paint); host.Content = layout;
            var picker = new AnnotationColorPicker(anchor, 0xff3b30, value => paint.SetStyle(new ToolStyle(value.Rgb, 20, value.Opacity ?? 1)), () => null);
            picker.IsOpen = true; await SettleUI(); picker.DebugCode.Text = "rgba(12, 100, 220, 0.5)"; await SettleUI();
            check(paint.EditingText && paint.DebugTextEditor.Opacity == .5 && ((SolidColorBrush)paint.DebugTextEditor.Foreground).Color == Color.FromRgb(12, 100, 220),
                "Mac：调色盘实时应用 rgba，输入中的文字不被提前提交");
            var content = (FrameworkElement)picker.Child;
            var picture = new RenderTargetBitmap((int)Math.Ceiling((content.ActualWidth + content.Margin.Left + content.Margin.Right) * 1.5),
                (int)Math.Ceiling((content.ActualHeight + content.Margin.Top + content.Margin.Bottom) * 1.5), 144, 144, PixelFormats.Pbgra32); picture.Render(content);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(picture)); using (var file = File.Create(Path.Combine(profile, "调色盘.png"))) encoder.Save(file);
            picker.DebugCode.Text = "#0C64DC00";
            check(paint.DisplayedStyle!.Opacity == 0, "Mac：八位颜色代码末尾 00 可实时设置完全透明，未被普通滑块下限改写");
            picker.DebugCode.Text = "rgba(12, 100, 220, 0.5)";
            picker.IsOpen = false; paint.FinishText(); check(paint.DebugMarks.Single().Style.Opacity == .5, "Mac：关闭调色盘保留已经应用的颜色与透明度");
            if (Environment.GetCommandLineArgs().Contains("--verify-annotation-input"))
            {
                var interactive = Fresh(); interactive.SelectTool(Tool.Text); interactive.DebugPress(new Point(100, 100)); interactive.DebugTextEditor!.Text = "合成文字：实时样式";
                host.Content = null;
                var toolbar = new MarkupToolbar(interactive, _ => { });
                var root = new DockPanel(); DockPanel.SetDock(toolbar, Dock.Bottom); root.Children.Add(toolbar); root.Children.Add(interactive); host.Content = root;
                host.Title = "Velos 标注交互自测";
                var dismissed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                toolbar.DebugPickerClosed = () => dismissed.TrySetResult();
                File.WriteAllText(Path.Combine(profile, "原生调色盘就绪.txt"), "打开自定义颜色，输入 #12ABCD80，按 Esc 关闭。");
                await dismissed.Task.WaitAsync(TimeSpan.FromMinutes(3));
                check(interactive.EditingText && interactive.DisplayedStyle is { Rgb: 0x12abcd } result && Math.Abs(result.Opacity - 128 / 255d) < .00001,
                    "实际调色盘操作：鼠标打开、输入带 alpha 的代码、Esc 关闭，实时文字保持编辑");
                WriteSettingsImage(host, Path.Combine(profile, "实际调色盘后文字.png"));
                File.WriteAllText(Path.Combine(profile, "原生调色盘通过.txt"), "原生鼠标键盘操作通过，未采集真实屏幕。");
                await Task.Delay(1800);
            }
        }
        finally { host.Close(); }
    }
}
#endif
