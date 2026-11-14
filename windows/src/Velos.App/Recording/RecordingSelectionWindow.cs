using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velos.Core.Settings;
using Velos.Core.Screenshot;
using Velos.Screenshot;
using Velos.UI;
using Velos.Windows.Capture;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.Recording;

internal sealed class RecordingSelectionWindow : Window
{
    private readonly Canvas chrome = new();
    private readonly Border optionsBar;
    private readonly ModeHint hint;
    private readonly Button system;
    private readonly Button microphone;
    private readonly Button devices;
    private readonly Button cursor;
    private readonly Button fps30;
    private readonly Button fps60;
    private readonly Button start;
    private readonly Func<RecordingPreferences> read;
    private readonly Action<RecordingPreferences> update;
    private ContextMenu? deviceMenu;
    private int deviceRequest;
    private bool closed;
    public Display Display { get; }
    public CaptureSurface Surface { get; }

    public RecordingSelectionWindow(Display display, IReadOnlyList<PixelRect> windows,
        Func<RecordingPreferences> read, Action<RecordingPreferences> update, Action<RecordingSelectionWindow> confirm, Action cancel)
    {
        Display = display;
        this.read = read;
        this.update = update;
        Title = "Velos 录屏选区";
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; AllowsTransparency = true;
        Background = Brushes.Transparent; Topmost = true; ShowInTaskbar = false; ShowActivated = true;
        WindowStartupLocation = WindowStartupLocation.Manual;
        var stride = (display.Bounds.Width + 7) / 8;
        var placeholder = BitmapSource.Create(display.Bounds.Width, display.Bounds.Height, 96, 96,
            PixelFormats.Indexed1, BitmapPalettes.BlackAndWhite, new byte[stride * display.Bounds.Height], stride);
        Surface = new CaptureSurface(display, placeholder, windows, ToolInfo.Default, (_, _) => { }, live: true) { Cursor = Cursors.Cross };
        system = CaptureChrome.IconButton("\ue767", "录制系统声音", () => Change(p => p with { SystemAudio = !p.SystemAudio }));
        microphone = CaptureChrome.IconButton("\ue720", "录制麦克风", () => Change(p => p with { Microphone = !p.Microphone }));
        cursor = CaptureChrome.IconButton(ActionIcon.Pointer, "录制鼠标指针", () => Change(p => p with { ShowCursor = !p.ShowCursor }));
        fps30 = CaptureChrome.Button("30", "30 fps", () => Change(p => p with { FrameRate = 30 }));
        fps60 = CaptureChrome.Button("60", "60 fps", () => Change(p => p with { FrameRate = 60 }));
        start = CaptureChrome.IconButton(ActionIcon.Record, "开始录制", () => confirm(this), "开始录制");
        start.Background = WarmTheme.Coral;
        devices = CaptureChrome.IconButton("\ue70d", "选择麦克风", () => ChooseMicrophone());
        devices.MinWidth = 20; devices.Width = 20; devices.Padding = new Thickness(2, 0, 2, 0);
        foreach (var button in new[] { fps30, fps60 })
        { button.MinWidth = 0; button.Width = 32; button.Height = 20; button.Margin = new Thickness(2); button.Padding = new Thickness(0); button.FontWeight = FontWeights.SemiBold; button.Resources["CaptureRadius"] = new CornerRadius(10); }
        var rate = new Border { Width = 76, Height = 32, Background = Brushes.Transparent, Child = new Border
        { Margin = new Thickness(2, 4, 2, 4), CornerRadius = new CornerRadius(12), Background = WarmTheme.Floating.Hover,
            Child = new UniformGrid { Columns = 2, Children = { fps30, fps60 } } } };
        Border Separator() => new() { Width = 1.5, Height = 16, Margin = new Thickness(5, 8, 6.5, 8), Background = WarmTheme.Floating.Divider };
        var controls = new WrapPanel { Children = { system, microphone, devices, cursor, Separator(), rate, Separator(), start } };
        optionsBar = CaptureChrome.Pill(controls);
        hint = new ModeHint();
        chrome.Children.Add(hint); chrome.Children.Add(optionsBar);
        Content = new Grid { Children = { Surface, chrome } };
        Surface.SelectionChanged += Layout;
        SizeChanged += (_, _) => Layout();
        MouseMove += (_, _) => Layout();
        DpiChanged += (_, _) => { if (IsLoaded && IsVisible) Dispatcher.BeginInvoke(cancel); };
        PreviewKeyDown += (_, e) =>
        {
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            if (e.IsRepeat && key is not (Key.Left or Key.Right or Key.Up or Key.Down)) { e.Handled = true; return; }
            if (key == Key.Escape && deviceMenu?.IsOpen == true) { deviceMenu.IsOpen = false; e.Handled = true; return; }
            if (key == Key.Escape) cancel();
            else if (key == Key.Enter && Surface.Region is not null) confirm(this);
            else if (!Surface.Nudge(key, Keyboard.Modifiers)) return;
            e.Handled = true;
        };
        MouseRightButtonUp += (_, e) => { e.Handled = true; if (!Surface.FullScreen && Surface.Region is not null) Surface.ClearRegion(); else cancel(); };
        Closed += (_, _) => { closed = true; deviceRequest++; if (deviceMenu is not null) deviceMenu.IsOpen = false; Desktop.ForgetScreenshotWindow(new WindowInteropHelper(this).Handle); };
        RefreshOptions();
    }

    public void ShowOnDisplay()
    {
        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        Desktop.Position(hwnd, Display.Bounds); Show(); Desktop.Position(hwnd, Display.Bounds);
        Desktop.ExcludeFromCapture(hwnd, true);
        var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        Surface.PixelScale = dpi; Surface.ViewScale = 1 / dpi;
        Layout();
    }

    public void RefreshOptions()
    {
        var preferences = read();
        Interaction.SetAction(system, preferences.SystemAudio ? ActionIcon.Volume : ActionIcon.Mute, "录制系统声音");
        Interaction.SetAction(microphone, preferences.Microphone ? ActionIcon.Microphone : ActionIcon.MicrophoneOff, "录制麦克风");
        Interaction.SetAction(cursor, preferences.ShowCursor ? ActionIcon.Pointer : ActionIcon.PointerOff, "录制鼠标指针");
        foreach (var (button, enabled) in new[] { (system, preferences.SystemAudio), (microphone, preferences.Microphone),
            (cursor, preferences.ShowCursor), (fps30, preferences.FrameRate == 30), (fps60, preferences.FrameRate != 30) })
        {
            button.Background = enabled ? WarmTheme.Apricot : Brushes.Transparent;
            button.Foreground = enabled ? Brushes.White : CaptureChrome.Ink;
        }
    }

    private void Change(Func<RecordingPreferences, RecordingPreferences> change) { update(change(read())); RefreshOptions(); }

    private async void ChooseMicrophone()
    {
        if (deviceMenu?.IsOpen == true) { deviceMenu.IsOpen = false; return; }
        var request = ++deviceRequest;
        var menu = deviceMenu = new ContextMenu { PlacementTarget = devices, Placement = PlacementMode.Top };
        var defaultDevice = new MenuItem { Header = "系统默认", IsCheckable = true, IsChecked = string.IsNullOrEmpty(read().MicrophoneId) };
        defaultDevice.Click += (_, _) => Change(p => p with { MicrophoneId = null, Microphone = true });
        menu.Items.Add(defaultDevice);
        try
        {
            foreach (var device in await Velos.Windows.Recording.WasapiCapture.Microphones())
            {
                var item = new MenuItem { Header = device.Name, IsCheckable = true, IsChecked = read().MicrophoneId == device.Id };
                item.Click += (_, _) => Change(p => p with { MicrophoneId = device.Id, Microphone = true });
                menu.Items.Add(item);
            }
        }
        catch (Exception) { menu.Items.Add(new MenuItem { Header = "无法枚举麦克风", IsEnabled = false }); }
        if (!closed && request == deviceRequest) menu.IsOpen = true;
    }

    private void Layout()
    {
        if (Surface.Suppressed) { hint.Visibility = optionsBar.Visibility = Visibility.Collapsed; return; }
        hint.Visibility = Visibility.Visible;
        if (chrome.ActualWidth <= 0) return;
        var selected = Surface.Region is { } region && !Surface.IsSelecting;
        start.IsEnabled = selected;
        optionsBar.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
        hint.Set(Surface.FullScreen ? "全屏录屏" : "区域录屏", ((App)Application.Current).Settings.Recording + (Surface.FullScreen ? " 切换区域" : " 切换全屏"), "Enter 开始", "Esc 取消");
        optionsBar.MaxWidth = Math.Max(1, chrome.ActualWidth - 8);
        optionsBar.Measure(new Size(optionsBar.MaxWidth, double.PositiveInfinity));
        System.Drawing.RectangleF? selection = Surface.Region is { } area && !Surface.FullScreen
            ? new(area.X / (float)Surface.PixelScale, area.Y / (float)Surface.PixelScale, area.Width / (float)Surface.PixelScale, area.Height / (float)Surface.PixelScale) : null;
        var origin = ScreenshotLayout.ToolbarOrigin(new((float)optionsBar.DesiredSize.Width, (float)optionsBar.DesiredSize.Height), selection,
            new(0, 0, (float)chrome.ActualWidth, (float)chrome.ActualHeight));
        Canvas.SetLeft(optionsBar, origin.X); Canvas.SetTop(optionsBar, origin.Y);
        var avoid = selection is { } rect ? new Rect(rect.X, rect.Y, rect.Width, rect.Height) : Rect.Empty;
        hint.Place(chrome, avoid, selected ? new Rect(origin.X, origin.Y, optionsBar.DesiredSize.Width, optionsBar.DesiredSize.Height) : Rect.Empty, Surface.PointerAvoid);
    }
    internal void SetSuppressed(bool value) { Surface.Suppress(value); Layout(); }
}
