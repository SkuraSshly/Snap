using System.IO;
using System.Security;
using System.Windows;
using System.Windows.Interop;
using Velos.Core.Hotkeys;
using Velos.Core.Settings;
using Velos.Screenshot;
using Velos.UI;
using Velos.Windows;
using Velos.Windows.Capture;
using Velos.Recording;
using Velos.Translation;
using Velos.Core.Translation;
using Velos.Windows.Translation;

namespace Velos;

public partial class App : Application
{
    private HwndSource? messageWindow;
    private GlobalHotkeys? hotkeys;
    private TrayIcon? tray;
    private Mutex? instance;
    private EventWaitHandle? activateInstance;
    private RegisteredWaitHandle? activationWait;
    private SettingsWindow? settingsWindow;
    private ScreenshotController? screenshots;
    private RecordingController? recordings;
    private TranslationController? translations;
    private CredentialStore? credentials;
    private TranslationService? translator;
    internal CredentialStore Credentials => credentials ??= new CredentialStore();
    internal TranslationService Translator => translator ??= new TranslationService(() => Settings.TranslationOptions, TranslationField, HasTranslationField);
    private bool exiting;
    private ClipboardOwner? clipboardOwner;
    private SettingsStore store = null!;
    private LaunchAtLogin launchAtLogin = null!;
    private string? startupWarning;
    private readonly HashSet<Window> trackedWindows = [];

    internal AppSettings Settings { get; private set; } = new();

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        EventManager.RegisterClassHandler(typeof(Window), FrameworkElement.LoadedEvent, new RoutedEventHandler(TrackWindowLifetime));

        if (e.Args.Length > 0 && e.Args[0] == "--ocr-worker")
        {
            RunOcrWorker(e.Args); return;
        }

        var profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Velos");
        var instanceName = @"Local\Velos.Windows";
        var runValue = "Velos";
#if DEBUG
        var screenshotTestDirectory = GetSelfTestDirectory(e.Args, "--screenshot-self-test");
        var longTestDirectory = GetSelfTestDirectory(e.Args, "--long-self-test");
        var recordingTestDirectory = GetSelfTestDirectory(e.Args, "--recording-self-test");
        var translationTestDirectory = GetSelfTestDirectory(e.Args, "--translation-self-test");
        var selfTestDirectory = translationTestDirectory ?? recordingTestDirectory ?? longTestDirectory ?? screenshotTestDirectory ?? GetSelfTestDirectory(e.Args);
        if (selfTestDirectory is not null)
        {
            var testId = Guid.NewGuid().ToString("N");
            profile = Path.Combine(selfTestDirectory, testId);
            instanceName += "." + testId;
            runValue += ".SelfTest." + testId;
        }
#endif
        var login = e.Args.Contains("--login", StringComparer.Ordinal);
        activateInstance = new EventWaitHandle(false, EventResetMode.AutoReset, instanceName + ".Activate");
        instance = new Mutex(false, instanceName, out var primary);
        if (!primary)
        {
            if (!login)
                activateInstance.Set();
            Shutdown();
            return;
        }

        store = new SettingsStore(Path.Combine(profile, "settings.json"));
        launchAtLogin = new LaunchAtLogin(runValue);
        (Settings, startupWarning) = store.Load();
        messageWindow = new HwndSource(new HwndSourceParameters("Velos")
        {
            WindowStyle = unchecked((int)0x80000000), // WS_POPUP，顶层隐藏窗口可接收 TaskbarCreated。
            Width = 0,
            Height = 0
        });
        messageWindow.AddHook(HandleMessage);
        hotkeys = new GlobalHotkeys(messageWindow.Handle);
#if DEBUG
        if (screenshotTestDirectory is null && longTestDirectory is null && recordingTestDirectory is null && translationTestDirectory is null)
#endif
        hotkeys.RegisterSaved(Settings);
        WarmTheme.Refresh();
#if DEBUG
        if (e.Args.Contains("--dark")) WarmTheme.DebugSetDark(true);
#endif
        tray = new TrayIcon(messageWindow.Handle, BuildTrayMenu, size =>
        {
            var variant = WarmTheme.DarkTaskbar() ? "white" : "black";
            var density = Math.Clamp((int)Math.Ceiling(size / 18d), 1, 3);
            return WarmTheme.ImageBytes($"tray-{variant}-{density}x");
        }, OpenSettings);
        if (!tray.SetVisible(Settings.ShowTrayIcon))
            startupWarning ??= "暂时无法显示托盘图标。再次打开 Velos 可进入设置。";

        activationWait = ThreadPool.RegisterWaitForSingleObject(activateInstance,
            (_, _) => Dispatcher.BeginInvoke(() => OpenSettings()), null, Timeout.Infinite, executeOnlyOnce: false);

#if DEBUG
        if (selfTestDirectory is not null)
        {
            if (translationTestDirectory is not null)
                Dispatcher.BeginInvoke(() => RunTranslationSelfTest(profile, e.Args.Contains("--measure-idle")));
            else if (recordingTestDirectory is not null)
                Dispatcher.BeginInvoke(() => RunRecordingSelfTest(profile, e.Args.Contains("--measure-idle")));
            else if (longTestDirectory is not null)
                Dispatcher.BeginInvoke(() => RunLongCaptureSelfTest(profile, e.Args.Contains("--measure-idle")));
            else if (screenshotTestDirectory is not null)
                Dispatcher.BeginInvoke(() => RunScreenshotSelfTest(profile, e.Args.Contains("--measure-idle")));
            else
                Dispatcher.BeginInvoke(() => RunSelfTest(profile));
            return;
        }
#endif
        MigrateTranslationOptions();
        ScreenshotDrag.CleanupTemporaryFiles();
        if (!login && !Settings.HasCompletedWelcome)
        {
            var welcome = new WelcomeWindow(OpenSettings);
            welcome.Closed += (_, _) =>
            {
                if (ReferenceEquals(MainWindow, welcome)) MainWindow = null;
                if (!Save(Settings with { HasCompletedWelcome = true }, out var problem)) tray.Notify(problem!);
            };
            welcome.Show();
        }
        else if (!login && !Settings.ShowTrayIcon) OpenSettings();
    }

    internal bool IsHotkeyRegistered(HotkeyAction action) => hotkeys!.IsRegistered(action);
    private void TrackWindowLifetime(object sender, RoutedEventArgs e)
    {
        if (sender is Window window && trackedWindows.Add(window)) window.Closed += ReleaseWindow;
    }
    private void ReleaseWindow(object? sender, EventArgs e)
    {
        if (sender is not Window window) return;
        trackedWindows.Remove(window); window.Closed -= ReleaseWindow;
        if (ReferenceEquals(MainWindow, window)) MainWindow = null;
    }
    internal void SuspendHotkeys() => hotkeys!.Dispose();
    internal void ResumeHotkeys() { hotkeys!.Dispose(); hotkeys.RegisterSaved(Settings); }

    internal string? ChangeHotkey(HotkeyAction action, Hotkey candidate)
    {
        var problem = HotkeyConflicts.Validate(candidate, action, Settings.GetHotkey);
        if (problem is not null)
            return problem;

        string? saveProblem = null;
        var next = Settings.WithHotkey(action, candidate);
        return hotkeys!.TryReplace(action, candidate, () => next == Settings || Save(next, out saveProblem))
            ? null : saveProblem ?? HotkeyConflicts.Occupied(candidate);
    }

    internal string? ChangeTrayVisibility(bool visible)
    {
        if (!Save(Settings with { ShowTrayIcon = visible }, out var problem))
            return problem;
        return tray!.SetVisible(visible) ? null : "暂时无法显示托盘图标。";
    }

    internal string? ChangeScreenshotOptions(ScreenshotPreferences options)
    {
        Save(Settings with { ScreenshotOptions = options }, out var problem);
        return problem;
    }

    internal string? ChangeRecordingOptions(RecordingPreferences options)
    {
        Save(Settings with { RecordingOptions = options }, out var problem);
        return problem;
    }

    internal string? ChangeTranslationOptions(TranslationPreferences options)
    {
        CancelTranslationNetwork(); Save(Settings with { TranslationOptions = options }, out var problem); return problem;
    }
    internal void CancelTranslationNetwork() => translations?.CancelNetwork();

    private async void RunOcrWorker(string[] args)
    {
        try { await OcrWorker.Run(args.ElementAtOrDefault(1) ?? ""); Shutdown(); }
        catch { Shutdown(1); }
    }

    internal (bool Enabled, string? Warning) ReadLoginSetting()
    {
        try
        {
            return (launchAtLogin.IsEnabled(), null);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or SecurityException)
        {
            return (false, "无法读取登录启动设置。");
        }
    }

    internal string? ChangeLoginSetting(bool enabled)
    {
        try
        {
            launchAtLogin.SetEnabled(enabled);
            return null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or SecurityException)
        {
            return "无法更新登录启动设置，请检查 Windows 是否允许修改启动项。";
        }
    }

    private bool Save(AppSettings next, out string? problem)
    {
        try
        {
            store.Save(next);
            Settings = next;
            settingsWindow?.RefreshPreferences();
            problem = null;
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            problem = "无法保存设置，请检查 Velos 设置文件夹的访问权限和可用空间。";
            return false;
        }
    }

    private void OpenSettings()
    {
        if (Dispatcher.HasShutdownStarted)
            return;

        if (settingsWindow is null)
        {
            settingsWindow = new SettingsWindow(this, startupWarning);
            settingsWindow.Closed += (sender, _) =>
            {
                if (ReferenceEquals(MainWindow, sender))
                    MainWindow = null;
                settingsWindow = null;
            };
            settingsWindow.Show();
        }

        if (settingsWindow.WindowState == WindowState.Minimized)
            SystemCommands.RestoreWindow(settingsWindow);
        if (!settingsWindow.Activate())
        {
            settingsWindow.Topmost = true;
            settingsWindow.Topmost = false;
        }
    }

    private IReadOnlyList<TrayMenuItem> BuildTrayMenu()
    {
        var items = new List<TrayMenuItem>();
        foreach (var action in Enum.GetValues<HotkeyAction>())
        {
            var hint = IsHotkeyRegistered(action) ? $"\t{Settings.GetHotkey(action)}" : "";
            items.Add(new TrayMenuItem(Hotkey.Title(action) + hint, () => RunAction(action, fromTray: true)));
        }
        items.Add(new TrayMenuItem(null));
        if (recordings?.IsRecording == true)
        {
            items.Add(new TrayMenuItem(recordings.IsPaused ? "继续录制" : "暂停录制", recordings.TogglePause));
            items.Add(new TrayMenuItem("停止录制", () => _ = recordings.Stop()));
            items.Add(new TrayMenuItem(null));
        }
        items.Add(new TrayMenuItem("设置…", OpenSettings));
        items.Add(new TrayMenuItem(null));
        items.Add(new TrayMenuItem("退出 Velos", RequestExit));
        return items;
    }

    private RecordingController GetRecordingController() => recordings ??= new RecordingController(() => Settings.RecordingOptions,
        options => { var problem = ChangeRecordingOptions(options); if (problem is not null) ShowCaptureError(problem); }, ShowCaptureError, messageWindow!.Handle);

    internal void ExportExistingGif(string path, Window owner)
    {
        var center = owner.PointToScreen(new Point(owner.ActualWidth / 2, owner.ActualHeight / 2));
        var displays = Desktop.Displays();
        var display = displays.FirstOrDefault(item => item.Bounds.Contains((int)center.X, (int)center.Y)) ?? displays.First();
        GetRecordingController().ExportGif(path, display, System.Windows.Media.VisualTreeHelper.GetDpi(owner).DpiScaleX);
    }

    private void RunAction(HotkeyAction action, bool fromTray = false)
    {
#if DEBUG
        if (selfTestHotkey is not null)
        {
            selfTestHotkey(action);
            return;
        }
#endif
        if (action == HotkeyAction.Recording && recordings?.IsRecording == true) { _ = recordings.Stop(); return; }
        var selection = screenshots?.IsActive == true ? HotkeyAction.Screenshot : translations?.IsSelecting == true ? HotkeyAction.Translation : recordings?.IsSelecting == true ? HotkeyAction.Recording : (HotkeyAction?)null;
        if (!Velos.Core.Screenshot.CaptureSessionRules.Accept(action, selection, screenshots?.IsLongCapturing == true)) return;
        if (action == HotkeyAction.Screenshot)
        {
            clipboardOwner ??= new ClipboardOwner(messageWindow!.Handle);
            screenshots ??= new ScreenshotController(() => Settings.ScreenshotOptions, ChangeScreenshotOptions,
                (png, firstRead) => clipboardOwner.CopyImage(png, () => ShotEncoding.Dib(png), firstRead),
                text =>
                {
                    clipboardOwner.CancelCopyAttempt();
                    Clipboard.SetText(text);
                }, ShowCaptureError);
            screenshots.Toggle(fromTray);
            return;
        }
        if (screenshots?.IsActive == true)
            return;

        if (action == HotkeyAction.Recording)
        {
            GetRecordingController().Toggle(fromTray); return;
        }

        if (action == HotkeyAction.Translation)
        {
            translations ??= new TranslationController(() => Settings.TranslationOptions, Translator,
                () => { OpenSettings(); settingsWindow?.SelectTranslationSettings(); },
                text => { clipboardOwner?.CancelCopyAttempt(); Clipboard.SetText(text); }, ShowCaptureError);
            translations.Toggle(fromTray); return;
        }

        ShowCaptureError("无法识别此快捷键操作。");
    }

    private void ShowCaptureError(string message)
    {
        if (tray?.Notify(message) == true)
            return;
        MessageBox.Show(message, "Velos", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    private async void RequestExit()
    {
        if (exiting) return;
        exiting = true;
        if (recordings is not null) await recordings.Close();
        Shutdown();
    }

    private nint HandleMessage(nint window, int message, nint wParam, nint lParam, ref bool handled)
    {
        recordings?.HandleSystemMessage(message, wParam, lParam);
        if (message == 0x007e) // WM_DISPLAYCHANGE：旧的选区坐标不能继续使用。
            Dispatcher.BeginInvoke(() => { screenshots?.CancelSelection(); translations?.CancelSelection(); recordings?.CancelSelection(); if (recordings?.IsRecording == true) _ = recordings.Stop(); });
        if (message == 0x001a)
        {
            WarmTheme.Refresh();
            settingsWindow?.ApplyPalette();
        }
        if (message == GlobalHotkeys.Message && hotkeys!.TryGetAction(wParam, out var action, out var key))
        {
            if (settingsWindow?.CaptureRegisteredHotkey(key) != true)
                RunAction(action);
            handled = true;
        }
        else if (clipboardOwner?.HandleMessage(message, wParam) == true ||
                 tray?.HandleMessage(message, wParam, lParam) == true)
        {
            handled = true;
        }
        return 0;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        OcrWorker.Stop();
        credentials?.ClearCache();
        activationWait?.Unregister(null);
        screenshots?.Dispose();
        translations?.Dispose();
        clipboardOwner?.Dispose();
        hotkeys?.Dispose();
        tray?.Dispose();
        messageWindow?.Dispose();
        instance?.Dispose();
        activateInstance?.Dispose();
        WarmCursors.DisposeCache();
        base.OnExit(e);
    }
}
