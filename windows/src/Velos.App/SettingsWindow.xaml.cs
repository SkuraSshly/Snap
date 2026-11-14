using System.ComponentModel;
using System.Windows.Data;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Media.Effects;
using System.Windows.Interop;
using Velos.Windows.Capture;
using Microsoft.Win32;
using Velos.Core.Hotkeys;
using Velos.Core.Settings;
using Velos.Screenshot;
using Velos.UI;

namespace Velos;

public partial class SettingsWindow : Window
{
    private readonly App app;
    private readonly Dictionary<HotkeyAction, HotkeyRow> rows;
    private readonly List<Action> preferenceRefreshers = [];
    internal void RefreshPreferences() { foreach (var refresh in preferenceRefreshers) refresh(); }
    private HotkeyAction? recording;

    internal SettingsWindow(App app, string? warning)
    {
        this.app = app;
        InitializeComponent();
        BrandIcon.Source = new CroppedBitmap(WarmTheme.Image("wordmark-3x"), new Int32Rect(24, 19, 336, 142));
        FontFamily = WarmTheme.Text;
        CloseButton.Content = new ActionIconView(ActionIcon.Close, 13);
        MinimizeButton.Content = new ActionIconView(ActionIcon.Minimize, 13);
        RefreshMaximizeButton();
        LoginIcon.Content = WhiteIcon(ActionIcon.Power);
        TrayIcon.Content = WhiteIcon(ActionIcon.Tray);
        Loaded += (_, _) => UpdateWindowShape();
        SizeChanged += (_, _) => UpdateWindowShape();
        DpiChanged += (_, _) => UpdateWindowShape();
        StateChanged += (_, _) =>
        {
            RefreshMaximizeButton();
            UpdateWindowShape();
        };
        Resources["IconFont"] = WarmTheme.Icons;
        GeneralTab.Content = NavigationLabel("通用", "\ue713", WarmTheme.Brush(158, 115, 87));
        ScreenshotTab.Content = NavigationLabel("截图", "\ue722", WarmTheme.Brush(97, 158, 224));
        RecordingTab.Content = NavigationLabel("录屏", "\ue7c8", WarmTheme.Coral);
        TranslationTab.Content = NavigationLabel("截屏翻译", "\ue8f2", WarmTheme.Brush(115, 179, 120), ActionIcon.Translate);
        HotkeysTab.Content = NavigationLabel("快捷键", "\ue765", WarmTheme.Brush(158, 133, 217));
        ApplyPalette();
        rows = Enum.GetValues<HotkeyAction>().ToDictionary(action => action, action => new HotkeyRow(app, action));
        HotkeyRows.ItemsSource = rows.Values;
        GeneralTab.IsChecked = true;
        TraySwitch.IsChecked = app.Settings.ShowTrayIcon;
        RefreshLogin();
        if (warning is not null)
            ShowStatus(warning);
        Activated += (_, _) => RefreshLogin();
        Closed += (_, _) => { CancelRecording(); cancelEngineTest?.Invoke(); };
    }

    private void CloseSettings(object sender, RoutedEventArgs e) => Close();
    private void RefreshMaximizeButton()
    {
        var maximized = WindowState == WindowState.Maximized;
        MaximizeButton.Content = new ActionIconView(maximized ? ActionIcon.WindowRestore : ActionIcon.WindowMaximize, 13);
        MaximizeButton.ToolTip = maximized ? "还原" : "最大化";
        System.Windows.Automation.AutomationProperties.SetName(MaximizeButton, maximized ? "还原" : "最大化");
    }
    private void MinimizeSettings(object sender, RoutedEventArgs e) => SystemCommands.MinimizeWindow(this);
    private void MaximizeSettings(object sender, RoutedEventArgs e)
    {
        if (WindowState == WindowState.Maximized) SystemCommands.RestoreWindow(this);
        else SystemCommands.MaximizeWindow(this);
    }
    private void UpdateWindowShape()
    {
        if (!IsLoaded || ActualWidth <= 0 || ActualHeight <= 0) return;
        var radius = WindowState == WindowState.Maximized ? 0 : 16;
        WindowRoot.Clip = new RectangleGeometry(new Rect(0, 0, ActualWidth, ActualHeight), radius, radius);
        var scale = VisualTreeHelper.GetDpi(this);
        Desktop.RoundWindow(new WindowInteropHelper(this).Handle, (int)Math.Round(ActualWidth * scale.DpiScaleX),
            (int)Math.Round(ActualHeight * scale.DpiScaleY), (int)Math.Round(radius * scale.DpiScaleX));
    }
    private static ActionIconView WhiteIcon(ActionIcon kind) => new(kind, 13)
    { Ink = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

    internal void ShowStatus(string? message)
    {
        StatusText.Text = message ?? "";
        StatusText.Visibility = message is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void ShowGeneral(object sender, RoutedEventArgs e)
    {
        CancelRecording();
        PageTitle.Text = "通用";
        GeneralPage.Visibility = Visibility.Visible;
        ScreenshotPage.Visibility = Visibility.Collapsed;
        HotkeysPage.Visibility = Visibility.Collapsed;
        RecordingPage.Visibility = Visibility.Collapsed;
        TranslationPage.Visibility = Visibility.Collapsed;
        RevealPage(GeneralPage);
    }

    private void ShowScreenshot(object sender, RoutedEventArgs e)
    {
        CancelRecording();
        PageTitle.Text = "截图";
        GeneralPage.Visibility = Visibility.Collapsed;
        HotkeysPage.Visibility = Visibility.Collapsed;
        ScreenshotPage.Visibility = Visibility.Visible;
        RecordingPage.Visibility = Visibility.Collapsed;
        TranslationPage.Visibility = Visibility.Collapsed;
        if (ScreenshotPage.Children.Count == 0)
            BuildScreenshotSettings();
        RevealPage(ScreenshotPage);
    }

    private void ShowHotkeys(object sender, RoutedEventArgs e)
    {
        PageTitle.Text = "快捷键";
        GeneralPage.Visibility = Visibility.Collapsed;
        ScreenshotPage.Visibility = Visibility.Collapsed;
        HotkeysPage.Visibility = Visibility.Visible;
        RecordingPage.Visibility = Visibility.Collapsed;
        TranslationPage.Visibility = Visibility.Collapsed;
        RevealPage(HotkeysPage);
    }

    private void ShowRecording(object sender, RoutedEventArgs e)
    {
        CancelRecording(); PageTitle.Text = "录屏"; GeneralPage.Visibility = ScreenshotPage.Visibility = HotkeysPage.Visibility = Visibility.Collapsed;
        RecordingPage.Visibility = Visibility.Visible;
        TranslationPage.Visibility = Visibility.Collapsed;
        if (RecordingPage.Children.Count == 0) BuildRecordingSettings();
        RevealPage(RecordingPage);
    }

    private void ShowTranslation(object sender, RoutedEventArgs e)
    {
        CancelRecording(); PageTitle.Text = "截屏翻译"; GeneralPage.Visibility = ScreenshotPage.Visibility = HotkeysPage.Visibility = RecordingPage.Visibility = Visibility.Collapsed;
        TranslationPage.Visibility = Visibility.Visible; if (TranslationPage.Children.Count == 0) BuildTranslationSettings(); RevealPage(TranslationPage);
    }
    private void RevealPage(FrameworkElement page)
    {
        if (NavigationOffset is not null)
        {
            var tabs = new[] { GeneralTab, ScreenshotTab, RecordingTab, TranslationTab, HotkeysTab };
            var index = Math.Max(0, Array.FindIndex(tabs, tab => tab.IsChecked == true));
            WarmMotion.SelectNavigation(NavigationOffset, index * 40, IsLoaded);
        }
        PageScroll?.ScrollToTop(); if (IsLoaded) WarmMotion.Fade(page, 1, 180, 0);
    }

    private void ToggleTray(object sender, RoutedEventArgs e)
    {
        ShowStatus(app.ChangeTrayVisibility(TraySwitch.IsChecked == true));
        TraySwitch.IsChecked = app.Settings.ShowTrayIcon;
    }

    private void ToggleLogin(object sender, RoutedEventArgs e)
    {
        var problem = app.ChangeLoginSetting(LoginSwitch.IsChecked == true);
        ShowStatus(problem);
        RefreshLogin();
    }

    private void RefreshLogin()
    {
        var (enabled, warning) = app.ReadLoginSetting();
        LoginSwitch.IsChecked = enabled;
        if (warning is not null)
            ShowStatus(warning);
    }

    private void BeginRecording(object sender, RoutedEventArgs e)
    {
        var button = (Button)sender;
        var action = (HotkeyAction)button.Tag;
        CancelRecording();
        button.Focus();
        recording = action;
        app.SuspendHotkeys();
        rows[action].Refresh(recording: true);
    }

    private void RestoreHotkey(object sender, RoutedEventArgs e)
    {
        CancelRecording();
        var action = (HotkeyAction)((Button)sender).Tag;
        rows[action].Refresh(app.ChangeHotkey(action, Hotkey.Default(action)));
    }

    private void RecordKey(object sender, KeyEventArgs e)
    {
        if (recording is null)
            return;

        e.Handled = true;
        var key = e.Key switch
        {
            Key.System => e.SystemKey,
            Key.ImeProcessed => e.ImeProcessedKey,
            Key.DeadCharProcessed => e.DeadCharProcessedKey,
            _ => e.Key
        };
        var modifiers = (HotkeyModifiers)Keyboard.Modifiers;
        if (Keyboard.IsKeyDown(Key.LWin) || Keyboard.IsKeyDown(Key.RWin))
            modifiers |= HotkeyModifiers.Windows;
        if (key == Key.Escape && modifiers == HotkeyModifiers.None)
        {
            CancelRecording();
            return;
        }
        if (e.IsRepeat || key is Key.None or Key.LeftAlt or Key.RightAlt or Key.LeftCtrl or Key.RightCtrl
            or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin)
        {
            ShowModifiers(modifiers);
            return;
        }
        CaptureRegisteredHotkey(new Hotkey((uint)KeyInterop.VirtualKeyFromKey(key), modifiers));
    }

    internal bool CaptureRegisteredHotkey(Hotkey key)
    {
        if (recording is not { } action)
            return false;

        recording = null;
        var warning = app.ChangeHotkey(action, key);
        app.ResumeHotkeys();
        foreach (var row in rows.Values) row.Refresh();
        rows[action].Refresh(warning);
        return true;
    }

    private void CancelOnFocusLost(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (recording is { } action && ((Button)sender).Tag is HotkeyAction buttonAction && action == buttonAction)
            CancelRecording();
    }

    private void WindowDeactivated(object? sender, EventArgs e) => CancelRecording();

    private void CancelRecording()
    {
        if (recording is not { } action)
            return;
        recording = null;
        app.ResumeHotkeys();
        foreach (var row in rows.Values) row.Refresh();
    }

    private void ReleaseRecordedModifier(object sender, KeyEventArgs e)
    { if (recording is not null) { ShowModifiers((HotkeyModifiers)Keyboard.Modifiers); e.Handled = true; } }
    private void ShowModifiers(HotkeyModifiers modifiers)
    {
        if (recording is not { } action) return;
        var labels = new List<string>();
        if (modifiers.HasFlag(HotkeyModifiers.Control)) labels.Add("Ctrl");
        if (modifiers.HasFlag(HotkeyModifiers.Alt)) labels.Add("Alt");
        if (modifiers.HasFlag(HotkeyModifiers.Shift)) labels.Add("Shift");
        if (modifiers.HasFlag(HotkeyModifiers.Windows)) labels.Add("Win");
        rows[action].Refresh(recording: true, pending: labels.Count == 0 ? null : string.Join('+', labels));
    }

    internal void ApplyPalette()
    {
        Resources["KeycapFace"] = WarmTheme.IsDark ? WarmTheme.Brush(107, 89, 77) : Brushes.White;
        Resources["KeycapEdge"] = WarmTheme.IsDark ? WarmTheme.Brush(66, 52, 43) : WarmTheme.Brush(210, 197, 184);
        Resources["ApricotBadge"] = WarmTheme.Badge(WarmTheme.Apricot);
        Resources["CocoaBadge"] = WarmTheme.Badge(WarmTheme.Brush(158, 115, 87));
        DropShadowEffect Shadow(Color color, double opacity, double blur, double depth) => new()
        { Color = color, Opacity = SystemParameters.HighContrast ? 0 : opacity, BlurRadius = blur, ShadowDepth = depth, Direction = 270 };
        Resources["CardShadow"] = Shadow(Color.FromRgb(89, 51, 26), .07, 8, 2);
        Resources["NavigationShadow"] = Shadow(WarmTheme.Apricot.Color, .32, 8, 2);
        Resources["BadgeShadow"] = Shadow(WarmTheme.Apricot.Color, .2, 3, 1);
        if (SystemParameters.HighContrast)
        {
            Resources["Wash"] = SystemColors.WindowBrush;
            Resources["Sidebar"] = SystemColors.WindowBrush;
            Resources["Card"] = SystemColors.ControlBrush;
            Resources["Track"] = SystemColors.ControlBrush;
            Resources["Hairline"] = SystemColors.ControlTextBrush;
            Resources["Ink"] = SystemColors.WindowTextBrush;
            Resources["Secondary"] = SystemColors.WindowTextBrush;
            Resources["Warning"] = SystemColors.WindowTextBrush;
            Resources["Focus"] = SystemColors.HighlightBrush;
            Resources["Apricot"] = SystemColors.HighlightBrush;
            Resources["SelectedInk"] = SystemColors.HighlightTextBrush;
            Resources["ApricotGlow"] = Brushes.Transparent;
            Resources["CoralGlow"] = Brushes.Transparent;
            return;
        }

        var dark = WarmTheme.IsDark;
        var baseColor = ColorOf(dark ? "#211B18" : "#FFFDF9");
        Resources["Wash"] = new LinearGradientBrush(
            Composite(ColorOf(dark ? "#B8382B24" : "#C7FFF2E3"), baseColor),
            Composite(ColorOf(dark ? "#C72E241F" : "#B3FCE8D6"), baseColor), 58);
        Resources["Sidebar"] = BrushOf(dark ? "#55241B18" : "#55FFFDF8");
        Resources["Card"] = BrushOf(dark ? "#8C4D3D33" : "#B8FFFCF9");
        Resources["Track"] = BrushOf(dark ? "#21FFE6CC" : "#1F735438");
        Resources["Hairline"] = BrushOf(dark ? "#1FFFE6CC" : "#21735438");
        Resources["Ink"] = BrushOf(dark ? "#FAEBDB" : "#543D2E");
        Resources["Secondary"] = BrushOf(dark ? "#8CFAEBDB" : "#94543D2E");
        Resources["Warning"] = BrushOf(dark ? "#FFAB9F" : "#A4382F");
        Resources["Focus"] = BrushOf(dark ? "#F5945C" : "#A85324");
        Resources["Apricot"] = WarmTheme.Apricot;
        Resources["SelectedInk"] = Brushes.White;
        Resources["ApricotGlow"] = WarmTheme.Glow(245, 148, 92, 56);
        Resources["CoralGlow"] = WarmTheme.Glow(237, 94, 77, 26);
    }

    private static Color Composite(Color top, Color bottom)
    {
        byte Mix(byte value, byte basis) => (byte)((value * top.A + basis * (255 - top.A) + 127) / 255);
        return Color.FromRgb(Mix(top.R, bottom.R), Mix(top.G, bottom.G), Mix(top.B, bottom.B));
    }

    private static StackPanel NavigationLabel(string title, string icon, Brush color, ActionIcon? kind = null)
    {
        kind ??= ActionIconView.FromGlyph(icon);
        var glyph = WarmTheme.Glyph(icon, 12);
        glyph.Foreground = Brushes.White;
        var tile = new Border { Width = 24, Height = 24, CornerRadius = new CornerRadius(6),
            Child = kind is { } selectedIcon ? new ActionIconView(selectedIcon, 13) { Ink = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } : glyph, Margin = new Thickness(0, 0, 10, 0) };
        var tileStyle = new Style(typeof(Border));
        tileStyle.Setters.Add(new Setter(BackgroundProperty, WarmTheme.Badge(color)));
        var selected = new DataTrigger
        {
            Binding = new Binding("IsChecked") { RelativeSource = new RelativeSource(RelativeSourceMode.FindAncestor, typeof(RadioButton), 1) },
            Value = true
        };
        selected.Setters.Add(new Setter(BackgroundProperty, WarmTheme.Brush(255, 255, 255, 64)));
        tileStyle.Triggers.Add(selected);
        tile.Style = tileStyle;
        var bounceBound = false;
        tile.Loaded += (_, _) => {
            if (bounceBound) return;
            for (DependencyObject? parent = tile; parent is not null; parent = VisualTreeHelper.GetParent(parent)) {
                if (parent is not RadioButton tab) continue;
                bounceBound = true;
                void Bounce(object sender, RoutedEventArgs e) { if (tile.Child is FrameworkElement icon) WarmMotion.BounceSymbol(icon); }
                tab.Checked += Bounce; tab.Unchecked += Bounce; break;
            }
        };
        var text = new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center };
        text.SetBinding(TextBlock.ForegroundProperty, new Binding("Foreground")
        {
            RelativeSource = new RelativeSource(RelativeSourceMode.FindAncestor, typeof(RadioButton), 1)
        });
        return new StackPanel { Orientation = Orientation.Horizontal, Children =
        {
            tile, text
        }};
    }

    private static Color ColorOf(string hex) => (Color)ColorConverter.ConvertFromString(hex);

    private static SolidColorBrush BrushOf(string hex)
    {
        var brush = new SolidColorBrush(ColorOf(hex));
        brush.Freeze();
        return brush;
    }

    private sealed class HotkeyRow : INotifyPropertyChanged
    {
        private readonly App app;
        public HotkeyAction Action { get; }
        public string Title => Hotkey.Title(Action);
        public string Glyph { get; }
        public FrameworkElement Symbol { get; }
        public Brush Tint { get; }
        public string Label { get; private set; } = "";
        public string? Status { get; private set; }
        public Visibility StatusVisibility => Status is null ? Visibility.Collapsed : Visibility.Visible;
        public Visibility RestoreVisibility => app.Settings.GetHotkey(Action) != Hotkey.Default(Action)
            ? Visibility.Visible : Visibility.Collapsed;
        public string AutomationName => $"设置{Title}快捷键，当前为 {app.Settings.GetHotkey(Action)}";
        public string RestoreName => $"恢复{Title}默认快捷键";

        public event PropertyChangedEventHandler? PropertyChanged;

        public HotkeyRow(App app, HotkeyAction action)
        {
            this.app = app;
            Action = action;
            var (glyph, color) = action switch
            {
                HotkeyAction.Screenshot => ("\ue722", "#619EE0"),
                HotkeyAction.Recording => ("\ue7c8", "#ED5E4D"),
                _ => ("\ue8f2", "#73B378")
            };
            Glyph = glyph;
            Symbol = WhiteIcon(action switch { HotkeyAction.Screenshot => ActionIcon.Capture, HotkeyAction.Recording => ActionIcon.Record, _ => ActionIcon.Translate });
            Tint = WarmTheme.Badge(BrushOf(color));
            Refresh();
        }

        public void Refresh(string? warning = null, bool recording = false, string? pending = null)
        {
            var key = app.Settings.GetHotkey(Action);
            Label = recording ? pending ?? "请按下快捷键…" : key.ToString();
            Status = recording ? null : warning ?? (app.IsHotkeyRegistered(Action) ? null : HotkeyConflicts.Occupied(key));
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
        }
    }
}
