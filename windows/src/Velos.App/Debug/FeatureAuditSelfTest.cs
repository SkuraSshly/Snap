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
using Velos.Recording;
using Velos.Screenshot;
using Velos.Translation;
using Velos.UI;
using Velos.Windows.Capture;
using PixelRect = System.Drawing.Rectangle;

namespace Velos;

public partial class App
{
    private async Task RunFeatureAudit(string profile, List<string> results)
    {
        void Check(bool condition, string id, string text)
        {
            if (!condition) throw new InvalidOperationException($"[{id}] {text}");
            results.Add($"通过  [{id}] {text}");
        }
        var display = Desktop.Displays().First();
        var image = SyntheticImage(600, 400);
        var left = new PixelRect(display.WorkArea.X + 30, display.WorkArea.Y + 30, 400, 280);
        var right = new PixelRect(left.Right + 20, left.Top, 400, 280);
        var a = display with { Bounds = left }; var b = display with { Bounds = right };
        if (Environment.GetCommandLineArgs().Contains("--verify-file-drop"))
        {
            await VerifyNativeFileDrop(profile, Check, new ShotImage(ShotEncoding.Encode(image), 600, 400, 1, left, display)); return;
        }

        var lifetime = new Window { Title = "Velos 生命周期合成检查", Width = 200, Height = 100 };
        lifetime.Show(); await SettleUI(); MainWindow = lifetime; lifetime.Close();
        Check(MainWindow is null, "L01", "任意已关闭窗口不再被 Application.MainWindow 保留");

        var host = new Window { Title = "Velos 逐项标注检查", Width = 960, Height = 730, WindowStartupLocation = WindowStartupLocation.CenterScreen };
        host.Show();
        try
        {
            foreach (var tool in Enum.GetValues<Tool>())
            {
                var memory = new Dictionary<Tool, ToolStyle>();
                var canvas = new MarkCanvas(image, 1, t => memory.GetValueOrDefault(t) ?? ToolInfo.Default(t), (t, value) => memory[t] = value)
                { Width = 600, Height = 400, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
                host.Content = canvas; canvas.SelectTool(tool);
                var info = ToolInfo.For(tool); var key = "A" + (int)tool;
                if (tool == Tool.Text) { canvas.DebugPress(new Point(60, 60)); canvas.DebugText("逐项测试\n第二行"); }
                else canvas.DebugStroke(new Point(60, 60), new Point(180, 140));
                Check(canvas.DebugMarks.Count == 1 && canvas.DebugMarks[0].Tool == tool, key + ".1", info.Name + "：独立创建标注");
                var identity = canvas.DebugMarks[0].Id;
                canvas.Undo(); Check(canvas.DebugMarks.Count == 0, key + ".2", info.Name + "：撤销创建");
                canvas.Redo(); Check(canvas.DebugMarks.Single().Id == identity, key + ".3", info.Name + "：重做保持同一标注");
                var mark = canvas.DebugMarks[0];
                var hit = tool switch
                { Tool.Counter => mark.First, Tool.Text => new Point(mark.Bounds.X + 5, mark.Bounds.Y + 5), Tool.Rectangle or Tool.Ellipse or Tool.Mosaic or Tool.Blur => new Point(120, 60), _ => new Point(120, 100) };
                canvas.DebugPress(hit); canvas.DebugRelease(hit);
                Check(canvas.DebugSelected == 0, key + ".4", info.Name + "：点击实际路径选中");
                canvas.HandleEditingKey(Key.Delete, ModifierKeys.None);
                Check(canvas.DebugMarks.Count == 0, key + ".5", info.Name + "：删除所选标注");
                canvas.Undo(); Check(canvas.DebugMarks.Count == 1, key + ".6", info.Name + "：撤销删除");
                canvas.DebugPress(hit); canvas.DebugRelease(hit);
                canvas.SetStyle(canvas.DisplayedStyle! with { Size = info.Max });
                Check(canvas.DebugMarks[0].Style.Size == info.Max && memory[tool].Size == info.Max, key + ".7", info.Name + "：样式修改作用于选中标注并记忆");
                var exported = canvas.RenderCrop(new PixelRect(0, 0, 600, 400));
                Check(exported.PixelWidth == 600 && exported.PixelHeight == 400, key + ".8", info.Name + "：标注输出保留物理尺寸");
            }
        }
        finally { host.Close(); }

        var actionLog = new List<ShotAction>();
        var overlay = new CaptureWindow(a, image, [], ToolInfo.Default, (_, _) => { }, actionLog.Add, _ => true);
        overlay.ShowOnDisplay(); overlay.Surface.DebugDrag(new(30, 30), new(250, 180)); await SettleUI();
        var rectangle = AuditDescendants<Button>(overlay).First(button => AutomationProperties.GetName(button) == "矩形");
        rectangle.Focus(); rectangle.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent)); overlay.DebugKey(Key.Enter);
        Check(actionLog.SequenceEqual(new[] { ShotAction.Done }), "K01", "点过工具按钮、焦点仍在按钮上时，Enter 仍然完成截图"); overlay.Close();

        var errors = new List<string>();
        using (var failedColor = new ScreenshotController(() => new(), _ => null, (_, _) => Task.CompletedTask,
            _ => throw new InvalidOperationException("合成剪贴板忙"), errors.Add))
        {
            var window = failedColor.DebugStart(a, image, []); window.Surface.SetPointer(new(15, 15)); window.DebugKey(Key.C);
            Check(errors.Count == 1 && !window.Surface.DebugColorCopied, "K02", "颜色复制失败时不能显示已复制");
        }

        var asset = new ShotImage(ShotEncoding.Encode(image), 600, 400, 1, left, display);
        var editorActions = new List<ShotAction>();
        var editor = new EditorWindow(asset, ToolInfo.Default, (_, _) => { }, (_, _, action) => editorActions.Add(action)); editor.Show(); await SettleUI();
        AuditDescendants<Button>(editor).First(button => AutomationProperties.GetName(button) == "矩形").Focus();
        AuditKey(editor, Key.Enter);
        Check(editorActions.SequenceEqual(new[] { ShotAction.Done }) && !editor.IsVisible, "K03", "编辑器按钮有焦点时，Enter 仍输出并关闭");

        var cancels = 0; var prefs = new RecordingPreferences();
        var recordA = new RecordingSelectionWindow(a, [], () => prefs, _ => { }, _ => { }, () => cancels++);
        var recordB = new RecordingSelectionWindow(b, [], () => prefs, _ => { }, _ => { }, () => cancels++);
        var recordingGroup = new SelectionGroup();
        try
        {
            recordA.ShowOnDisplay(); recordB.ShowOnDisplay();
            recordingGroup.Add(recordA, a, recordA.Surface, recordA.SetSuppressed); recordingGroup.Add(recordB, b, recordB.Surface, recordB.SetSuppressed);
            recordA.Surface.DebugDrag(new(30, 30), new(220, 170)); var original = recordA.Surface.Region;
            recordA.Surface.SetFullScreen(true); recordingGroup.MoveFullScreen(recordB);
            Check(recordB.Surface.FullScreen && recordA.Surface.Suppressed, "R01", "录屏全屏跨屏时只亮当前屏");
            recordB.Surface.SetFullScreen(false);
            Check(recordA.Surface.Region == original && !recordA.Surface.Suppressed, "R02", "录屏区域与全屏跨屏往返保留原区域");
            AuditRightClick(recordA);
            Check(recordA.Surface.Region is null && cancels == 0, "R03", "录屏有选区时右键先清除选区");
            AuditRightClick(recordA); Check(cancels == 1, "R04", "录屏无选区时右键才取消会话");
        }
        finally { recordingGroup.Clear(); recordA.Close(); recordB.Close(); }

        var controller = new RecordingController(() => prefs, _ => { }, errors.Add);
        controller.Toggle(fromTray: true);
        Check(controller.IsSelecting && !Windows.Cast<Window>().OfType<RecordingSelectionWindow>().Any(), "R05", "从托盘启动录屏先等待菜单退场，此时不会提前显示选区");
        controller.CancelSelection(); await Task.Delay(260);
        Check(!controller.IsSelecting && errors.Count == 1, "R06", "菜单退场等待可取消，不会延迟冒出选区"); await controller.Close();
        var closeProbe = new RecordingController(() => prefs, _ => { }, errors.Add);
        closeProbe.Toggle(); await SettleUI();
        var actualSelectors = Windows.Cast<Window>().OfType<RecordingSelectionWindow>().ToArray();
        Check(actualSelectors.Length > 0 && closeProbe.IsSelecting, "R07", "实际录屏控制器已创建选区会话（未启动屏幕或声音采集）");
        actualSelectors[0].Close();
        Check(!closeProbe.IsSelecting && !Windows.Cast<Window>().OfType<RecordingSelectionWindow>().Any(), "R08", "系统关闭任一录屏选区后关闭整组，不留下幽灵会话"); await closeProbe.Close();

        var confirmations = 0;
        var translationA = new TranslationSelectionWindow(a, image, [], _ => confirmations++, () => { });
        var translationB = new TranslationSelectionWindow(b, image, [], _ => confirmations++, () => { });
        var translationGroup = new SelectionGroup();
        try
        {
            translationA.ShowOnDisplay(); translationB.ShowOnDisplay();
            translationGroup.Add(translationA, a, translationA.Surface, translationA.SetSuppressed); translationGroup.Add(translationB, b, translationB.Surface, translationB.SetSuppressed);
            translationA.Surface.SetPointer(new(100, 60));
            Check(!translationA.Surface.ShowMagnifier && translationA.Surface.MagnifierAvoid.IsEmpty, "T01", "翻译选区不显示截图放大镜");
            translationA.Surface.DebugDrag(new(40, 40), new(250, 190)); var original = translationA.Surface.Region;
            Check(confirmations == 1, "T02", "翻译只在鼠标完成选区后确认一次");
            translationA.Surface.SetFullScreen(true); translationGroup.MoveFullScreen(translationB); translationB.Surface.SetFullScreen(false);
            Check(confirmations == 1 && translationA.Surface.Region == original, "T03", "翻译切换模式和跨屏不能误触发 OCR");
            Check(!translationA.Surface.Suppressed && !translationB.Surface.Suppressed, "T04", "翻译退出全屏后恢复各屏选区输入");
        }
        finally { translationGroup.Clear(); translationA.Close(); translationB.Close(); }

        for (var mask = 0; mask < 8; mask++)
        {
            var folder = Path.Combine(profile, "输出组合", mask.ToString()); var copies = 0;
            var options = new ScreenshotPreferences { Directory = folder, Copy = (mask & 1) != 0, AutoSave = (mask & 2) != 0, Thumbnail = (mask & 4) != 0 };
            using var flow = new ScreenshotController(() => options, _ => null, (_, _) => { copies++; return Task.CompletedTask; }, _ => { }, errors.Add);
            await flow.DebugDeliver(image, 1, left, display, ShotAction.Done);
            if (options.AutoSave) await WaitFor(() => Directory.Exists(folder) && Directory.EnumerateFiles(folder, "*.png").Any(), "自动保存组合");
            Check(copies == (options.Copy ? 1 : 0), "O" + mask + ".1", $"输出组合 {mask}：复制开关独立生效");
            Check(Directory.Exists(folder) == options.AutoSave, "O" + mask + ".2", $"输出组合 {mask}：只在需要自动保存时写文件");
            Check(flow.DebugThumbnails.Count == (options.Thumbnail ? 1 : 0), "O" + mask + ".3", $"输出组合 {mask}：缩略图开关独立生效");
        }
        Check(errors.Count == 1, "O09", "输出组合未产生其他错误");

        var dragRoot = Path.Combine(profile, "拖拽临时");
        Check(ScreenshotDrag.DebugFileDrop(asset, dragRoot), "D01", "未保存图片同时支持普通文件拖拽，真正取数据才生成原生 PNG");
        var oldDrag = Path.Combine(dragRoot, "截图 2000-01-01 00.00.00-1234abcd.png"); await File.WriteAllBytesAsync(oldDrag, asset.Png); File.SetLastWriteTimeUtc(oldDrag, DateTime.UtcNow.AddDays(-2));
        var otherFile = Path.Combine(dragRoot, "其他文件.png"); await File.WriteAllBytesAsync(otherFile, asset.Png); File.SetLastWriteTimeUtc(otherFile, DateTime.UtcNow.AddDays(-2));
        ScreenshotDrag.CleanupTemporaryFiles(dragRoot);
        Check(!File.Exists(oldDrag) && File.Exists(otherFile) && Directory.GetFiles(dragRoot).Length == 2, "D02", "临时截图清理只回收自身历史文件，保留新文件和同目录其他文件");

        var explicitFolder = Path.Combine(profile, "明确保存");
        var explicitOptions = new ScreenshotPreferences { Copy = false, AutoSave = false, Thumbnail = false, Directory = explicitFolder };
        using (var explicitFlow = new ScreenshotController(() => explicitOptions, _ => null, (_, _) => throw new InvalidOperationException("不应复制"), _ => { }, errors.Add))
        {
            await explicitFlow.DebugDeliver(image, 1, left, display, ShotAction.Save);
            await WaitFor(() => Directory.Exists(explicitFolder) && Directory.GetFiles(explicitFolder).Length == 1, "明确保存");
            Check(explicitFlow.DebugThumbnails.Count == 0, "O10", "三个完成后选项全关，明确保存仍写文件且不复制、不显示缩略图");
        }
        byte[]? scaledCopy = null;
        var scaleOptions = new ScreenshotPreferences { Copy = true, AutoSave = true, Thumbnail = false, Downscale = true, Directory = Path.Combine(profile, "普通1x") };
        using (var scaledFlow = new ScreenshotController(() => scaleOptions, _ => null, (png, _) => { scaledCopy = png; return Task.CompletedTask; }, _ => { }, errors.Add))
        {
            await scaledFlow.DebugDeliver(image, 2, left, display, ShotAction.Done);
            await WaitFor(() => Directory.Exists(scaleOptions.Directory) && Directory.GetFiles(scaleOptions.Directory).Length == 1, "普通截图 1x");
            var copyImage = ShotEncoding.Decode(scaledCopy!); var savedImage = ShotEncoding.Decode(await File.ReadAllBytesAsync(Directory.GetFiles(scaleOptions.Directory!)[0]));
            Check(copyImage.PixelWidth == 300 && copyImage.PixelHeight == 200 && savedImage.PixelWidth == 300 && savedImage.PixelHeight == 200,
                "O11", "普通截图 1x 同时用于复制与保存，原生 600×400 在 2x 下输出 300×200");
        }

        if (Environment.GetCommandLineArgs().Contains("--verify-feature-input")) await VerifyFeatureNativeInput(profile, Check, display, image);
    }

    private static IEnumerable<T> AuditDescendants<T>(DependencyObject root) where T : DependencyObject
    {
        if (root is T match) yield return match;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var child in AuditDescendants<T>(VisualTreeHelper.GetChild(root, i))) yield return child;
    }
    private static void AuditKey(Window window, Key key) => window.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, key) { RoutedEvent = Keyboard.PreviewKeyDownEvent });
    private static void AuditRightClick(Window window) => window.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Right) { RoutedEvent = UIElement.MouseRightButtonUpEvent });

    private async Task VerifyFeatureNativeInput(string profile, Action<bool, string, string> check, Display display, BitmapSource image)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var flow = new ScreenshotController(() => new ScreenshotPreferences { Thumbnail = false }, _ => null,
            (_, _) => { done.TrySetResult(); return Task.CompletedTask; }, _ => { }, message => done.TrySetException(new InvalidOperationException(message)));
        var testDisplay = display with { Bounds = new PixelRect(display.WorkArea.X + 30, display.WorkArea.Y + 30, image.PixelWidth, image.PixelHeight) };
        var window = flow.DebugStart(testDisplay, image, []); window.Surface.DebugDrag(new(30, 30), new(450, 260));
        System.Windows.Interop.HwndSource.FromHwnd(new System.Windows.Interop.WindowInteropHelper(window).Handle)!.CompositionTarget!.RenderMode = System.Windows.Interop.RenderMode.SoftwareOnly;
        window.Title = "Velos 工具焦点原生自测"; window.ShowInTaskbar = true;
        Desktop.ExcludeFromCapture(new System.Windows.Interop.WindowInteropHelper(window).Handle, false);
        File.WriteAllText(Path.Combine(profile, "原生工具按键就绪.txt"), "点击任意绘图工具按钮，再按 Enter。只使用合成图像和假剪贴板。");
        await done.Task.WaitAsync(TimeSpan.FromMinutes(3));
        check(true, "K04", "实际鼠标点击工具后按 Enter 完成，未被工具按钮吞掉");
        File.WriteAllText(Path.Combine(profile, "原生工具按键通过.txt"), "实际点击工具和 Enter 完成已通过；输出进入假剪贴板。");
        var editorAsset = new ShotImage(ShotEncoding.Encode(image), image.PixelWidth, image.PixelHeight, 1, testDisplay.Bounds, display);
        var editor = new EditorWindow(editorAsset, ToolInfo.Default, (_, _) => { }, (_, _, _) => { }) { Title = "Velos 编辑器缩放原生自测" };
        editor.Show(); await SettleUI(); editor.DebugZoomTo(1);
        File.WriteAllText(Path.Combine(profile, "原生编辑器按键就绪.txt"), "按 Ctrl+Shift+= 放大至 125%，再按 Ctrl+W 关闭。");
        var deadline = DateTime.UtcNow.AddMinutes(3);
        while (Math.Abs(editor.DebugZoom - 1.25) > .001) { if (DateTime.UtcNow > deadline) throw new TimeoutException("原生 Ctrl+Shift+="); await Task.Delay(50); }
        check(true, "K05", "原生 Ctrl+Shift+= 按 Mac 代码步长放大至 125%");
        while (editor.IsVisible) { if (DateTime.UtcNow > deadline) throw new TimeoutException("原生 Ctrl+W"); await Task.Delay(50); }
        check(true, "K06", "原生 Ctrl+W 关闭编辑窗口");
        File.WriteAllText(Path.Combine(profile, "原生编辑器按键通过.txt"), "125% 快捷键和关闭编辑器通过。");
        await VerifyNativeFileDrop(profile, check, editorAsset);
    }

    private async Task VerifyNativeFileDrop(string profile, Action<bool, string, string> check, ShotImage asset)
    {
        var dropped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var window = new Window { Title = "Velos 文件拖拽原生自测", Width = 700, Height = 360, WindowStartupLocation = WindowStartupLocation.CenterScreen };
        var start = new Border { Background = WarmTheme.Apricot, CornerRadius = new CornerRadius(20), Margin = new Thickness(24), Child = new TextBlock { Text = "把这里拖到右侧", VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, FontSize = 20 } };
        var target = new Border { Background = WarmTheme.Brush(115, 179, 120), CornerRadius = new CornerRadius(20), Margin = new Thickness(24), AllowDrop = true, Child = new TextBlock { Text = "普通文件接收区", VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, FontSize = 20 } };
        var layout = new Grid(); layout.ColumnDefinitions.Add(new ColumnDefinition()); layout.ColumnDefinitions.Add(new ColumnDefinition());
        layout.Children.Add(start); layout.Children.Add(target); Grid.SetColumn(target, 1); window.Content = layout;
        Point? anchor = null;
        start.MouseLeftButtonDown += (_, e) => { anchor = e.GetPosition(start); start.CaptureMouse(); e.Handled = true; };
        start.MouseMove += (_, e) =>
        {
            if (anchor is not { } initial || e.LeftButton != MouseButtonState.Pressed || (e.GetPosition(start) - initial).Length < 8) return;
            anchor = null; start.ReleaseMouseCapture();
            ((TextBlock)start.Child).Text = "拖拽已开始";
            ScreenshotDrag.Start(asset, message => dropped.TrySetException(new InvalidOperationException(message)), Path.Combine(profile, "原生拖拽临时"));
        };
        start.MouseLeftButtonUp += (_, _) => { anchor = null; start.ReleaseMouseCapture(); };
        target.DragEnter += (_, e) => { e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None; e.Handled = true; };
        target.DragOver += (_, e) => { e.Effects = DragDropEffects.Copy; e.Handled = true; };
        target.Drop += (_, e) =>
        {
            try
            {
                var paths = (string[])e.Data.GetData(DataFormats.FileDrop);
                if (paths.Length != 1 || !File.ReadAllBytes(paths[0]).AsSpan().SequenceEqual(asset.Png)) throw new InvalidOperationException("接收的文件不是原生 PNG");
                e.Effects = DragDropEffects.Copy; e.Handled = true; dropped.TrySetResult();
            }
            catch (Exception failure) { dropped.TrySetException(failure); }
        };
        window.Show();
        try { await dropped.Task.WaitAsync(TimeSpan.FromMinutes(3)); check(true, "D03", "实际 OLE 拖拽可被只接收普通文件的目标接收，内容为原生 PNG"); File.WriteAllText(Path.Combine(profile, "原生文件拖拽通过.txt"), "实际鼠标 OLE 拖拽及普通文件接收已通过。"); }
        finally { window.Close(); }
    }
}
#endif
