#if DEBUG
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Velos.Core.Settings;
using Velos.Screenshot;
using Velos.Windows.Capture;

namespace Velos;

public partial class App
{
    private async Task VerifyCursorInteraction(Action<bool, string> check)
    {
        var image = SyntheticImage(600, 400);
        var display = Desktop.Displays().First();
        var host = new Window { Title = "Velos 控制点光标回归", Width = 660, Height = 480, WindowStartupLocation = WindowStartupLocation.CenterScreen };
        host.Show();
        try
        {
            foreach (var scale in new[] { 1d, 1.25, 1.5, 2 })
            foreach (var capture in new[] { false, true })
            foreach (var tool in new[] { Tool.Rectangle, Tool.Ellipse, Tool.Arrow, Tool.Line, Tool.Mosaic, Tool.Blur })
            {
                MarkCanvas canvas = capture ? new CaptureSurface(display, image, [], ToolInfo.Default, (_, _) => { }) : new MarkCanvas(image, scale, ToolInfo.Default, (_, _) => { });
                if (canvas is CaptureSurface surface) surface.SetFullScreen(true);
                canvas.PixelScale = scale; canvas.ViewScale = 1 / scale; canvas.Width = 600 / scale; canvas.Height = 400 / scale;
                host.Content = canvas;
                canvas.SelectTool(tool); canvas.DebugStroke(new Point(100, 100), new Point(340, 280));
                canvas.DebugPress(new Point(220, 100));
                if (canvas.DebugSelected < 0) { canvas.DebugRelease(new Point(220, 100)); canvas.DebugPress(new Point(220, 190)); }
                canvas.DebugRelease(new Point(220, 190));
                var mark = canvas.DebugMarks.Single();
                var handles = mark.Handles().ToArray();
                var cursors = handles.Select(handle => canvas.DebugResizeCursorAt(handle.Point)).ToArray();
                var outside = new Point(500, 350);
                var name = $"光标 {scale * 100:0}% { (capture ? "截图" : "编辑器") } {ToolInfo.For(tool).Name}：";
                bool HoverMatches() => handles.Select((handle, index) => ReferenceEquals(canvas.DebugResizeCursorAt(handle.Point), cursors[index])).All(value => value)
                    && canvas.DebugResizeCursorAt(outside) is null;
                check(cursors.All(cursor => cursor is not null) && cursors.Distinct().Count() > 1 && HoverMatches(), name + "点击前各控制点方向不同，移开不显示缩放光标");
                var first = handles[0].Point;
                canvas.DebugPress(first); canvas.DebugRelease(first);
                check(HoverMatches(), name + "单击白点再松开，后续只悬停即可切换各点方向");
                canvas.DebugPress(first); canvas.DebugMove(first + new Vector(15, 10));
                check(ReferenceEquals(canvas.DebugResizeCursorAt(outside), cursors[0]), name + "按住拖动期间保持当前控制点方向");
                canvas.DebugRelease(first + new Vector(15, 10));
                check(canvas.DebugResizeCursorAt(outside) is null && canvas.DebugResizeCursorAt(canvas.DebugMarks.Single().Handles().Last().Point) != cursors[0], name + "拖动松开后立即解除方向锁定");
                canvas.Undo();
                canvas.DebugPress(first); canvas.DebugMove(first + new Vector(20, 12)); canvas.DebugLoseMouseCapture();
                check(canvas.DebugDraft is null && canvas.DebugMarks.Single().Points.SequenceEqual(mark.Points) && HoverMatches(), name + "拖动丢失捕获后回滚并恢复悬停方向");
            }
            await SettleUI();
        }
        finally { host.Close(); }
    }

    private async Task VerifyNativeCursorHover(string profile, List<string> results)
    {
        var image = SyntheticImage(600, 400); var display = Desktop.Displays().First();
        foreach (var capture in new[] { false, true })
        {
            var kind = capture ? "截图" : "编辑器";
            MarkCanvas canvas = capture ? new CaptureSurface(display, image, [], ToolInfo.Default, (_, _) => { }) : new MarkCanvas(image, 1, ToolInfo.Default, (_, _) => { });
            if (canvas is CaptureSurface surface) surface.SetFullScreen(true);
            canvas.Width = 600; canvas.Height = 400; canvas.HorizontalAlignment = HorizontalAlignment.Left; canvas.VerticalAlignment = VerticalAlignment.Top;
            canvas.SelectTool(Tool.Rectangle); canvas.DebugStroke(new Point(100, 100), new Point(340, 280)); canvas.DebugPress(new Point(220, 100)); canvas.DebugRelease(new Point(220, 100));
            var expected = canvas.DebugResizeCursorAt(new Point(340, 100));
            var label = new TextBlock { Text = "单击左上白点并松开，再只悬停右上白点（不要再次点击）", Margin = new Thickness(8), FontSize = 16 };
            var layout = new DockPanel(); DockPanel.SetDock(label, Dock.Top); layout.Children.Add(label); layout.Children.Add(canvas);
            var host = new Window { Title = "Velos 光标悬停原生自测 - " + kind, Width = 650, Height = 500, Content = layout, WindowStartupLocation = WindowStartupLocation.CenterScreen };
            var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var released = false;
            host.AddHandler(UIElement.MouseLeftButtonUpEvent, new MouseButtonEventHandler((_, args) =>
            {
                if ((args.GetPosition(canvas) - new Point(100, 100)).Length > 8) return;
                released = true; label.Text = "已松开；只移动到右上白点，不要点击";
            }), handledEventsToo: true);
            host.Closed += (_, _) => finished.TrySetCanceled();
            host.PreviewMouseLeftButtonDown += (_, _) => { if (released) finished.TrySetException(new InvalidOperationException("再次点击不能代替被测的被动悬停。")); };
            host.MouseMove += (_, args) =>
            {
                if (!released || args.LeftButton != MouseButtonState.Released || (args.GetPosition(canvas) - new Point(340, 100)).Length > 7) return;
                if (!ReferenceEquals(canvas.Cursor, expected)) finished.TrySetException(new InvalidOperationException("松开后原生悬停仍是旧控制点方向。"));
                else finished.TrySetResult();
            };
            host.Show(); HwndSource.FromHwnd(new WindowInteropHelper(host).Handle)!.CompositionTarget!.RenderMode = RenderMode.SoftwareOnly;
            File.WriteAllText(Path.Combine(profile, kind + "原生悬停就绪.txt"), "只使用合成图片；单击左上白点再无点击移到右上白点。");
            try
            {
                await finished.Task.WaitAsync(TimeSpan.FromMinutes(3));
                results.Add("通过  原生悬停 " + kind + "：点击左上白点松开后，无再次点击悬停右上白点，实际 Cursor 恢复正确方向");
                File.WriteAllText(Path.Combine(profile, kind + "原生悬停通过.txt"), "真实鼠标消息通过，目标点没有按下／点击。");
            }
            finally { host.Close(); }
        }
    }
}
#endif
