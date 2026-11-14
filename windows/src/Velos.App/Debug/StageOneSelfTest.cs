#if DEBUG
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Velos.Core.Hotkeys;
using Velos.Core.Settings;
using Velos.Windows;
using Velos.UI;

namespace Velos;

public partial class App
{
    private Action<HotkeyAction>? selfTestHotkey;

    private static string? GetSelfTestDirectory(string[] args, string option = "--self-test")
    {
        var index = Array.IndexOf(args, option);
        return index >= 0 && index + 1 < args.Length
            ? Path.GetFullPath(args[index + 1]) : null;
    }

    private async void RunSelfTest(string profile)
    {
        var results = new List<string>();
        var exitCode = 1;
        Directory.CreateDirectory(profile);
        try
        {
            if (Environment.GetCommandLineArgs().Contains("--verify-motion"))
            {
                OpenSettings(); await SettleUI(); await VerifyNativeMotion(settingsWindow!, profile, Check); exitCode = 0; return;
            }
            if (Environment.GetCommandLineArgs().Contains("--verify-alt-focus"))
            {
                OpenSettings(); await SettleUI();
                await VerifyNativeAltFocus(settingsWindow!, profile, Check);
                exitCode = 0;
                return;
            }
            Check(tray!.DebugIconExists(), "托盘图标已注册");
            Check(tray.DebugUsesReferenceIcon, "使用参考资源里的托盘图标");
            var focusLost = 0;
            using (var guard = new Velos.Windows.Capture.SelectionFocus(_ => focusLost++))
            {
                Check(guard.DebugInstalled, "选区前台监听可注册");
                guard.DebugForeground((uint)Environment.ProcessId); guard.DebugForeground(uint.MaxValue); guard.DebugForeground(uint.MaxValue);
                Check(focusLost == 1 && !guard.DebugInstalled, "Mac 语义：切到其他程序只取消一次并释放前台监听");
            }
            Check(tray.DebugSimulateTaskbarRecreated(), "收到 TaskbarCreated 时恢复托盘图标");
            var welcome = new WelcomeWindow(() => { }); welcome.Show(); await SettleUI();
            WriteSettingsImage(welcome, Path.Combine(profile, "欢迎.png")); welcome.Close();

            OpenSettings();
            await SettleUI();
            var window = settingsWindow!;
            window.Topmost = true; window.Activate();
            var pageScroll = (ScrollViewer)window.FindName("PageScroll");
            window.Focus(); pageScroll.Focus();
            Check(!pageScroll.IsKeyboardFocused, "设置空白滚动容器不接收独立焦点，避免 Alt 显示整页虚线框");
            var firstSwitch = (CheckBox)window.FindName("LoginSwitch");
            Check(firstSwitch.Focus() && firstSwitch.IsKeyboardFocused, "移除容器焦点后，内部设置开关仍可获得键盘焦点");
            Check(ReferenceEquals(firstSwitch.FocusVisualStyle, window.FindResource("SwitchKeyboardFocus")), "开关采用暖色圆角键盘焦点样式，不回退黑色虚线框");
            window.Focus();
            WriteSettingsImage(window, Path.Combine(profile, "通用.png"));

            var loginSwitch = (CheckBox)window.FindName("LoginSwitch");
            ClickSwitch(loginSwitch);
            Check(launchAtLogin.IsEnabled(), "登录启动开关写入当前用户 Run 项");
            ClickSwitch(loginSwitch);
            Check(!launchAtLogin.IsEnabled(), "关闭登录启动后撤销注册");

            var traySwitch = (CheckBox)window.FindName("TraySwitch");
            ClickSwitch(traySwitch);
            Check(!tray.DebugIconExists() && !Settings.ShowTrayIcon, "隐藏托盘并保存设置");
            ClickSwitch(traySwitch);
            Check(tray.DebugIconExists() && Settings.ShowTrayIcon, "重新显示托盘");
            await Task.Delay(600);
            var knob = (FrameworkElement)traySwitch.Template.FindName("Knob", traySwitch);
            var knobTransform = (TranslateTransform)knob.RenderTransform;
            Check(knobTransform.X == 15 && knob.Width == 17 && !knobTransform.HasAnimatedProperties, "Mac 开关：17 点圆钮滑动 15 点，结束后释放时钟");
            traySwitch.IsChecked = false; await Task.Delay(600); traySwitch.IsChecked = true;
            if (WarmMotion.Allowed) {
                try { await WaitFor(() => knobTransform.HasAnimatedProperties && knobTransform.X > .001 && knobTransform.X < 16, "等待开关实际中间帧"); }
                catch { var actual = (TranslateTransform)knob.RenderTransform; results.Add($"诊断  checked={traySwitch.IsChecked}; loaded={traySwitch.IsLoaded}; oldX={knobTransform.X}; oldAnimated={knobTransform.HasAnimatedProperties}; same={ReferenceEquals(actual, knobTransform)}; newX={actual.X}; newAnimated={actual.HasAnimatedProperties}; frozen={actual.IsFrozen}"); throw; }
            }
            if (WarmMotion.Allowed) Check(knobTransform.HasAnimatedProperties && knobTransform.X > 0 && knobTransform.X < 16, $"Mac 0.30/0.68 开关弹簧具有实际中间帧（X={knobTransform.X:0.000}）");
            var accent = (UIElement)traySwitch.Template.FindName("TrackAccent", traySwitch);
            var colorVelocity = WarmMotion.SpringVelocity(accent, UIElement.OpacityProperty);
            traySwitch.IsChecked = false;
            if (WarmMotion.Allowed) Check(Math.Abs(colorVelocity) > .00001 && Math.Abs(WarmMotion.SpringVelocity(accent, UIElement.OpacityProperty) - colorVelocity) < .01,
                "开关快速反向时轨道颜色保留之前的运动方向，不突然清零速度");
            traySwitch.IsChecked = true;
            await Task.Delay(600); Check(!knobTransform.HasAnimatedProperties && knobTransform.X == 15, "开关连续切换后回到正确位置并停止动画");
            var actionButton = Screenshot.CaptureChrome.Button("测试", "动画验收", () => { });
            Check(!WarmMotion.GetEnabled(actionButton) && actionButton.RenderTransform.Value.IsIdentity, "Mac AppKit 工具按钮仅用底色反馈，不放大或缩放");

            ((RadioButton)window.FindName("HotkeysTab")).IsChecked = true;
            await SettleUI();
            await Task.Delay(600);
            var navOffset = (TranslateTransform)window.FindName("NavigationOffset");
            Check(navOffset.Y == 160 && !navOffset.HasAnimatedProperties, "2.2：侧栏选中胶囊滑到正确位置并释放动画时钟");
            WriteSettingsImage(window, Path.Combine(profile, "快捷键.png"));

            foreach (var action in Enum.GetValues<HotkeyAction>())
            {
                var key = Hotkey.Default(action);
                if (!IsHotkeyRegistered(action))
                {
                    results.Add($"环境  {key} 已占用，改用自测快捷键");
                    key = new Hotkey((uint)('J' + (int)action), HotkeyModifiers.Alt);
                    RecordShortcut(window, action, key);
                    Check(Settings.GetHotkey(action) == key, "可以从被占用的默认组合键换到可用组合键");
                }
                await CheckShortcut(action, key);
                results.Add($"通过  注册 {key} 并处理 Windows 快捷键消息（{Hotkey.Title(action)}）");
            }

            var previous = Settings.Screenshot;
            const uint occupiedId = 0xbfff;
            var occupied = new Hotkey(0x7a, HotkeyModifiers.Control | HotkeyModifiers.Alt);
            var hwnd = messageWindow!.Handle;
            Check(RegisterHotKey(hwnd, occupiedId, (uint)occupied.Modifiers, occupied.KeyCode), "占用测试组合键");
            try
            {
                Check(ChangeHotkey(HotkeyAction.Screenshot, occupied)?.Contains("占用") == true,
                    "注册失败时提示快捷键已占用");
                Check(Settings.Screenshot == previous, "保留冲突前的设置");
                await CheckShortcut(HotkeyAction.Screenshot, Settings.Screenshot);
                results.Add("通过  冲突后旧绑定仍可触发");
            }
            finally
            {
                UnregisterHotKey(hwnd, occupiedId);
            }

            var recorder = FindRecorder(window, HotkeyAction.Screenshot);
            recorder.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
            Check(Enum.GetValues<HotkeyAction>().All(action => !IsHotkeyRegistered(action)), "2.2：录制组合键期间暂停全部全局快捷键");
            SendToRecorder(recorder, Key.Escape, HotkeyModifiers.None);
            await SettleUI();
            Check(recorder.Content?.ToString() == previous.ToString(), "Esc 取消录制");
            Check(Enum.GetValues<HotkeyAction>().All(IsHotkeyRegistered), "2.2：Esc 后恢复全部可用快捷键");

            var custom = new Hotkey('U', HotkeyModifiers.Alt);
            RecordShortcut(window, HotkeyAction.Screenshot, custom);
            Check(Settings.Screenshot == custom, "通过设置界面录制并更新快捷键");
            Check(new SettingsStore(Path.Combine(profile, "settings.json")).Load().Settings == Settings,
                "设置文件重读与界面一致");
            await CheckShortcut(HotkeyAction.Screenshot, custom);
            results.Add("通过  修改后的快捷键可触发");

            window.Close();
            Check(settingsWindow is null, "关闭设置后释放窗口引用");
            OpenSettings();
            Check(settingsWindow is { IsVisible: true } && !ReferenceEquals(window, settingsWindow), "重新打开设置");
            settingsWindow!.Close();
            exitCode = 0;
        }
        catch (Exception error)
        {
            results.Add("失败  " + error);
        }
        finally
        {
            selfTestHotkey = null;
            launchAtLogin.SetEnabled(false);
            File.WriteAllLines(Path.Combine(profile, "结果.txt"), results);
            Shutdown(exitCode);
        }

        void Check(bool condition, string name)
        {
            if (!condition)
                throw new InvalidOperationException(name);
            results.Add("通过  " + name);
        }

    }

    private static void RecordShortcut(Window window, HotkeyAction action, Hotkey key)
    {
        var button = FindRecorder(window, action);
        button.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
        SendToRecorder(button, KeyInterop.KeyFromVirtualKey((int)key.KeyCode), key.Modifiers);
    }

    private async Task CheckShortcut(HotkeyAction expected, Hotkey key)
    {
        if (!IsHotkeyRegistered(expected))
            throw new InvalidOperationException($"测试快捷键 {key} 未能注册。");

        var triggered = new TaskCompletionSource<HotkeyAction>(TaskCreationOptions.RunContinuationsAsynchronously);
        selfTestHotkey = action => triggered.TrySetResult(action);
        try
        {
            var data = (nint)((key.KeyCode << 16) | (uint)key.Modifiers);
            if (!PostMessage(messageWindow!.Handle, GlobalHotkeys.Message, hotkeys!.DebugMessageId(expected), data))
                throw new InvalidOperationException("无法向自测窗口投递 WM_HOTKEY。");
            if (await triggered.Task.WaitAsync(TimeSpan.FromSeconds(2)) != expected)
                throw new InvalidOperationException($"{key} 触发了其他动作。");
        }
        finally
        {
            selfTestHotkey = null;
        }
    }

    private static void SendToRecorder(Button button, Key key, HotkeyModifiers modifiers)
    {
        var original = new byte[256];
        if (!GetKeyboardState(original))
            throw new InvalidOperationException("无法读取自测线程的按键状态。");
        var simulated = (byte[])original.Clone();
        // WPF 分别读取左右修饰键。
        simulated[0x12] = simulated[0xa4] = modifiers.HasFlag(HotkeyModifiers.Alt) ? (byte)0x80 : (byte)0;
        simulated[0x11] = simulated[0xa2] = modifiers.HasFlag(HotkeyModifiers.Control) ? (byte)0x80 : (byte)0;
        simulated[0x10] = simulated[0xa0] = modifiers.HasFlag(HotkeyModifiers.Shift) ? (byte)0x80 : (byte)0;
        simulated[0xa1] = simulated[0xa3] = simulated[0xa5] = 0;
        simulated[0x5b] = simulated[0x5c] = 0;
        if (!SetKeyboardState(simulated))
            throw new InvalidOperationException("无法模拟自测线程的修饰键。");

        try
        {
            var input = new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(button)!,
                Environment.TickCount, key) { RoutedEvent = Keyboard.PreviewKeyDownEvent };
            button.RaiseEvent(input);
        }
        finally
        {
            SetKeyboardState(original);
        }
    }

    private static void ClickSwitch(CheckBox toggle)
    {
        toggle.IsChecked = toggle.IsChecked != true;
        toggle.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));
    }

    private static Button FindRecorder(DependencyObject root, HotkeyAction action)
    {
        var queue = new Queue<DependencyObject>();
        queue.Enqueue(root);
        while (queue.TryDequeue(out var item))
        {
            if (item is Button { Name: "HotkeyRecorder", Tag: HotkeyAction bound } button && bound == action)
                return button;
            for (var index = 0; index < VisualTreeHelper.GetChildrenCount(item); index++)
                queue.Enqueue(VisualTreeHelper.GetChild(item, index));
        }
        throw new InvalidOperationException("未找到快捷键输入按钮。");
    }

    private async Task SettleUI()
    {
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        await Task.Delay(220);
    }
    private async Task VerifyNativeAltFocus(SettingsWindow window, string profile, Action<bool, string> check)
    {
        window.Title = "Velos Alt+A 焦点自测";
        var triggered = new TaskCompletionSource<HotkeyAction>(TaskCreationOptions.RunContinuationsAsynchronously);
        selfTestHotkey = action => triggered.TrySetResult(action); // 阻断实际捕获，只验证原生按键路径。
        try
        {
            check(IsHotkeyRegistered(HotkeyAction.Screenshot) && Settings.Screenshot == Hotkey.Default(HotkeyAction.Screenshot), "真实 Alt+A 已注册到合成测试实例");
            File.WriteAllText(Path.Combine(profile, "原生快捷键就绪.txt"), "点击设置空白处并按 Alt+A；不触发实际截图。");
            check(await triggered.Task.WaitAsync(TimeSpan.FromSeconds(60)) == HotkeyAction.Screenshot, "实际按下 Alt+A 后收到 Windows 截图快捷键消息");
            await SettleUI();
            var scroll = (ScrollViewer)window.FindName("PageScroll");
            check(!scroll.IsKeyboardFocused && (AdornerLayer.GetAdornerLayer(scroll)?.GetAdorners(scroll)?.Length ?? 0) == 0,
                "实际 Alt+A 后，设置内容区无独立焦点且无整页焦点装饰框");
            WriteSettingsImage(window, Path.Combine(profile, "实际Alt+A后设置.png"));
            File.WriteAllText(Path.Combine(profile, "原生快捷键通过.txt"), "原生 Alt+A 路径及无整页虚线验证通过。");
            await Task.Delay(1800);
        }
        finally { selfTestHotkey = null; }
    }
    private static void WriteSettingsImage(Window window, string path)
    {
        var visual = (FrameworkElement)window.Content;
        var dpi = VisualTreeHelper.GetDpi(visual);
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(visual.ActualWidth * dpi.DpiScaleX),
            (int)Math.Ceiling(visual.ActualHeight * dpi.DpiScaleY), dpi.PixelsPerInchX, dpi.PixelsPerInchY,
            PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var png = new PngBitmapEncoder();
        png.Frames.Add(BitmapFrame.Create(bitmap));
        using var output = File.Create(path);
        png.Save(output);
    }

    [DllImport("user32.dll", EntryPoint = "PostMessageW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(nint window, int message, nint wParam, nint lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetKeyboardState([Out] byte[] keys);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetKeyboardState(byte[] keys);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(nint window, uint id, uint modifiers, uint key);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(nint window, uint id);
}
#endif
