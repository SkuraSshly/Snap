using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shell;
using System.Windows.Threading;
using Velos.Core.Settings;
using Velos.Core.Translation;
using Velos.Screenshot;
using Velos.UI;
using Velos.Windows.Capture;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.Translation;

// 对应 TranslationWindow + TranslationView。状态仅来自 TranslationModel。
internal sealed class TranslationWindow : Window
{
    private static readonly Brush Cocoa = WarmTheme.Brush(84, 61, 46);
    private static Brush Ink => WarmTheme.IsDark ? WarmTheme.Floating.Ink : Cocoa;
    private readonly TextBox source, output;
    private readonly Button sourceLanguage, targetLanguage, pin, engineButton, sourceSpeech, outputSpeech, sourceCopy, outputCopy, copyBoth;
    private readonly TextBlock sourceLabel, timing, notice, sourceMessage, outputMessage;
    private readonly Grid layout;
    private readonly WindowChrome chrome;
    private readonly RotateTransform pinRotation = new();
    private readonly string speechOwner = Guid.NewGuid().ToString("N");
    private readonly StackPanel sourcePlaceholder, outputPlaceholder;
    private readonly Func<TranslationPreferences> read;
    private readonly Action openSettings;
    private readonly Action<string> copy;
    private readonly CancellationTokenSource lifetime = new();
    private OutsideClickMonitor? outside;
    private TranslationCopyHud? hud;
    private bool closed, moving, freeSized, updating, composing;
    internal TranslationModel Model { get; }
    internal CancellationToken ClosedToken => lifetime.Token;
    internal bool IsClosed => closed;
    public bool IsPinned { get; private set; }
    public event Action<TranslationWindow>? PinChanged;
    private TranslateLanguage SourceLanguage => Model.SourceLanguage;
    private TranslateLanguage TargetLanguage => Model.TargetLanguage;

    public TranslationWindow(PixelRect anchor, Func<TranslationPreferences> read, TranslationService service, Action openSettings, Action<string> copy)
        : this(anchor, new TranslationModel(read, service, copy), read, openSettings, copy) { }

    internal TranslationWindow(PixelRect anchor, TranslationModel model, Func<TranslationPreferences> read, Action openSettings, Action<string> copy)
    {
        Model = model; this.read = read; this.openSettings = openSettings; this.copy = copy;
        Title = "Velos 截屏翻译"; Width = 420; MinWidth = 340; MinHeight = 220;
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize; ShowInTaskbar = false; Topmost = true;
        SizeToContent = SizeToContent.Height; WindowStartupLocation = WindowStartupLocation.Manual;
        FontFamily = WarmTheme.Text; FontSize = 14; Foreground = Ink; Background = CaptureChrome.Paper;
        UseLayoutRounding = true; SnapsToDevicePixels = true; TextOptions.SetTextFormattingMode(this, TextFormattingMode.Display);
        chrome = new WindowChrome { CaptionHeight = 0, ResizeBorderThickness = new Thickness(0), GlassFrameThickness = new Thickness(0), CornerRadius = new CornerRadius(14), UseAeroCaptionButtons = false };
        WindowChrome.SetWindowChrome(this, chrome);
        sourceLanguage = MenuButton("自动检测", "原文语言", () => ShowLanguages(true)); sourceLanguage.MaxWidth = 168;
        targetLanguage = MenuButton(TargetLanguage.Name, "目标语言", () => ShowLanguages(false)); targetLanguage.MaxWidth = 110;
        pin = SmallIcon(ActionIcon.Pin, "钉住：置顶、点别处不关闭，可拖动、调整大小（Ctrl+P）", TogglePin);
        var swap = SmallIcon(ActionIcon.Switch, "交换语言", Model.SwapLanguages);
        var dismiss = SmallIcon(ActionIcon.Close, "关闭（Esc）", Close);
        pin.Width = dismiss.Width = 24; pin.Height = dismiss.Height = swap.Height = 24; dismiss.Margin = new Thickness(0);
        var header = new Grid { Height = 30, Background = Brushes.Transparent };
        foreach (var width in new[] { GridLength.Auto, GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto })
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        header.ColumnDefinitions[3].MinWidth = 4;
        header.SizeChanged += (_, _) => sourceLanguage.MaxWidth = Math.Clamp(header.ActualWidth - targetLanguage.ActualWidth - 104, 70, 168);
        sourceLanguage.HorizontalAlignment = HorizontalAlignment.Left;
        foreach (var (child, column) in new[] { (sourceLanguage, 0), (swap, 1), (targetLanguage, 2), (pin, 4), (dismiss, 5) })
        { Grid.SetColumn(child, column); header.Children.Add(child); }

        source = TextArea(false); output = TextArea(true);
        sourceLabel = Label(""); timing = Label(""); timing.FontSize = 10.5;
        sourceMessage = Message(); outputMessage = Message(); notice = Message(); notice.Foreground = WarmTheme.Apricot; notice.FontSize = 11;
        sourcePlaceholder = Placeholder(.94, .72); outputPlaceholder = Placeholder(.88, .6);
        var sourceArea = new Grid { Background = Brushes.Transparent, Children = { source, sourcePlaceholder, sourceMessage } };
        var outputArea = new Grid { Background = Brushes.Transparent, Children = { output, outputPlaceholder, outputMessage } };
        engineButton = MenuButton("", "翻译引擎", ChooseEngine); engineButton.FontSize = 11; engineButton.FontWeight = FontWeights.Medium;
        engineButton.Height = 20; engineButton.Padding = new Thickness(7, 0, 7, 0); engineButton.MaxWidth = 230; engineButton.Margin = new Thickness(0);
        engineButton.Resources["CaptureRadius"] = new CornerRadius(10);
        var sourceCard = Card(sourceArea, sourceLabel, false, () => Speak(Model.SourceText, SourceLanguage, "source"), () => Copy(Model.SourceText, "已复制原文"),
            out sourceSpeech, out sourceCopy);
        var translatedCard = Card(outputArea, engineButton, true, () => Speak(Model.Translation, TargetLanguage, "translation"), () => Copy(Model.Translation, "已复制译文"),
            out outputSpeech, out outputCopy, notice);
        copyBoth = SmallButton("", "复制原文和译文", () => Copy(Model.SourceText + "\n\n" + Model.Translation, "已复制原文和译文"));
        copyBoth.Resources["CaptureRadius"] = new CornerRadius(12);
        copyBoth.Content = new StackPanel { Orientation = Orientation.Horizontal, Children = {
            new ActionIconView(ActionIcon.Copy, 12) { Margin = new Thickness(0, 0, 5, 0) },
            new TextBlock { Text = "复制原文和译文", VerticalAlignment = VerticalAlignment.Center } } };
        var footer = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        DockPanel.SetDock(copyBoth, Dock.Left); footer.Children.Add(copyBoth); timing.HorizontalAlignment = HorizontalAlignment.Right; footer.Children.Add(timing);
        layout = new Grid { Margin = new Thickness(14, 10, 14, 12), Background = Brushes.Transparent };
        foreach (var child in new FrameworkElement[] { header, sourceCard, translatedCard, footer })
        { layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); Grid.SetRow(child, layout.Children.Count); layout.Children.Add(child); }
        var wash = new LinearGradientBrush(WarmTheme.IsDark ? Color.FromRgb(56, 43, 36) : Color.FromRgb(255, 246, 235),
            WarmTheme.IsDark ? Color.FromRgb(46, 36, 31) : Color.FromRgb(251, 231, 218), 90);
        var root = new Border { Background = wash, BorderBrush = CaptureChrome.Line, BorderThickness = new Thickness(.5), CornerRadius = new CornerRadius(14), Child = layout };
        Content = root;
        // 最外层边框和圆角附近可能直接命中 Window，而不是内层 Border。
        // 从窗口预览事件处理留白拖动，控件仍按原始命中保留编辑、选择及点击。
        PreviewMouseLeftButtonDown += DragWindow;
        source.TextChanged += (_, _) => { if (!updating) Model.Edit(source.Text); };
        TextCompositionManager.AddPreviewTextInputStartHandler(source, (_, _) => { composing = true; Model.SetComposing(true); });
        TextCompositionManager.AddPreviewTextInputHandler(source, (_, _) => { composing = false; Model.SetComposing(false); });
        source.SizeChanged += (_, e) => { if (e.WidthChanged && !freeSized) FitText(source, 180); };
        output.SizeChanged += (_, e) => { if (e.WidthChanged && !freeSized) FitText(output, 240); };
        Model.Changed += Render; TranslationSpeaker.Shared.Changed += RefreshSpeech;
        PreviewKeyDown += OnKey;
        // Mac 只在鼠标实际点到窗口外时关；Alt+Tab、系统弹层和失焦本身不应关窗口。
        Deactivated += (_, _) => { if (outside is null && !closed && !IsPinned && !moving && !MenuOpen()) Close(); };
        SourceInitialized += (_, _) => HwndSource.FromHwnd(new WindowInteropHelper(this).Handle)?.AddHook(HandleNative);
        SizeChanged += (_, _) => Round();
        Closed += (_, _) => {
            closed = true; outside?.Dispose(); outside = null; hud?.Close(); lifetime.Cancel();
            Model.Changed -= Render; TranslationSpeaker.Shared.Changed -= RefreshSpeech; Model.Dispose(); TranslationSpeaker.Shared.StopOwned(speechOwner);
            Pulse(sourcePlaceholder, false); Pulse(outputPlaceholder, false); lifetime.Dispose();
            Desktop.ForgetScreenshotWindow(new WindowInteropHelper(this).Handle);
        };
        Render();
        var monitor = Desktop.Displays().FirstOrDefault(display => display.Bounds.Contains(anchor.X + anchor.Width / 2, anchor.Y + anchor.Height / 2)) ?? Desktop.Displays().First();
        var handle = new WindowInteropHelper(this).EnsureHandle();
        // 先移到目标屏，不拿主屏 DPI 下的物理宽度去改窗口 DIP 宽度。
        Desktop.Move(handle, anchor.Right + 10, anchor.Top); Show(); UpdateLayout();
        var scale = VisualTreeHelper.GetDpi(this).DpiScaleX; var w = (int)Math.Ceiling(ActualWidth * scale); var h = (int)Math.Ceiling(ActualHeight * scale);
        var work = monitor.WorkArea; var gap = (int)Math.Round(10 * scale);
        var candidates = new[] { new PixelRect(anchor.Right + gap, anchor.Top, w, h), new(anchor.Left, anchor.Bottom + gap, w, h),
            new(anchor.Left - gap - w, anchor.Top, w, h), new(anchor.Left, anchor.Top - gap - h, w, h) };
        var placement = candidates.FirstOrDefault(rect => work.Contains(rect)); if (placement.IsEmpty) placement = candidates[0];
        placement.X = Math.Clamp(placement.X, work.Left + 4, Math.Max(work.Left + 4, work.Right - w - 4));
        placement.Y = Math.Clamp(placement.Y, work.Top + 4, Math.Max(work.Top + 4, work.Bottom - h - 4));
        MaxHeight = Math.Max(220, (work.Height - 8) / scale); Desktop.Position(handle, placement);
        Desktop.ExcludeForScreenshots(handle); if (read().PinnedByDefault) TogglePin(); else ObserveOutside();
        Activate(); Round();
    }

    private void Render()
    {
        if (closed || updating) return; updating = true;
        try {
            if (source.Text != Model.SourceText) source.Text = Model.SourceText;
            if (output.Text != Model.Translation) output.Text = Model.Translation;
            source.Visibility = Model.IsRecognizing || Model.RecognitionFailure is not null ? Visibility.Collapsed : Visibility.Visible;
            sourceMessage.Text = Model.RecognitionFailure ?? (Model.IsSlowRecognition ? "第一次识别这种文字，系统正在准备识别模型，请稍候…" : "");
            sourceMessage.Visibility = sourceMessage.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            sourceMessage.Margin = new Thickness(0, Model.IsRecognizing ? 30 : 0, 0, 0);
            Pulse(sourcePlaceholder, Model.IsRecognizing);
            var pending = Model.Status is TranslationModel.Phase.Idle or TranslationModel.Phase.Checking or TranslationModel.Phase.Translating;
            var failed = Model.Status == TranslationModel.Phase.Failed;
            Pulse(outputPlaceholder, pending && Model.Translation.Length == 0);
            output.Visibility = !failed && (!pending || Model.Translation.Length > 0) ? Visibility.Visible : Visibility.Collapsed;
            output.Opacity = pending && !Model.IsPartial ? .5 : 1;
            outputMessage.Text = Model.Failure ?? ""; outputMessage.Visibility = failed ? Visibility.Visible : Visibility.Collapsed;
            notice.Text = Model.EngineNotice ?? ""; notice.Visibility = notice.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            sourceLabel.Text = Model.IsRecognizing ? "正在识别…" : "原文 · " + SourceLanguage.Name;
            SetMenuTitle(sourceLanguage, Model.SourceChoice is not null ? SourceLanguage.Name : Model.IsRecognizing ? "自动检测" : "自动检测 · " + SourceLanguage.Name);
            SetMenuTitle(targetLanguage, TargetLanguage.Name);
            SetMenuTitle(engineButton, EngineDefinition.All.FirstOrDefault(engine => engine.Id == Model.Engine)?.Name ?? "设置翻译引擎…");
            timing.Text = Model.RecognitionTime is { } time ? $"识别 {time.TotalSeconds:0.00} 秒" : "";
            sourceCopy.IsEnabled = Model.SourceText.Length > 0; outputCopy.IsEnabled = copyBoth.IsEnabled = Model.Translation.Length > 0;
            sourceSpeech.IsEnabled = !string.IsNullOrWhiteSpace(Model.SourceText); outputSpeech.IsEnabled = !string.IsNullOrWhiteSpace(Model.Translation);
            if (!freeSized) { FitText(source, 180); FitText(output, 240); }
            else source.VerticalScrollBarVisibility = output.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        } finally { updating = false; }
    }
    private nint HandleNative(nint hwnd, int message, nint w, nint l, ref bool handled)
    { if (message == 0x0214 && IsPinned) BeginResize(); return 0; }
    private void ObserveOutside()
    {
        outside?.Dispose(); outside = null;
        if (closed || IsPinned) return;
        try { outside = new OutsideClickMonitor(new WindowInteropHelper(this).Handle, () => Dispatcher.BeginInvoke(() => { if (!closed && !IsPinned && !moving) Close(); })); }
        catch (System.ComponentModel.Win32Exception) { /* 不可用时使用失焦兜底。 */ }
    }
    private bool MenuOpen() => new[] { sourceLanguage, targetLanguage, engineButton }.Any(button => button.ContextMenu?.IsOpen == true);
    private void DragWindow(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || Interaction.IsControl(e.OriginalSource)) return;
        e.Handled = true; moving = true; try { DragMove(); } catch (InvalidOperationException) { } finally { moving = false; }
    }
    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi) { base.OnDpiChanged(oldDpi, newDpi); Round(); }
    private void Round()
    {
        var handle = new WindowInteropHelper(this).Handle; if (handle == 0 || ActualWidth < 1) return;
        var scale = VisualTreeHelper.GetDpi(this).DpiScaleX; Desktop.RoundWindow(handle, (int)Math.Ceiling(ActualWidth * scale), (int)Math.Ceiling(ActualHeight * scale), (int)Math.Round(14 * scale));
        if (!IsVisible || freeSized) return;
        var point = PointToScreen(new Point()); var display = Desktop.Displays().FirstOrDefault(item => item.Bounds.Contains((int)point.X, (int)point.Y));
        if (display is not null && point.Y + ActualHeight * scale > display.WorkArea.Bottom) Top -= (point.Y + ActualHeight * scale - display.WorkArea.Bottom) / scale;
    }
    public void TogglePin()
    {
        IsPinned = !IsPinned; ResizeMode = IsPinned ? ResizeMode.CanResize : ResizeMode.NoResize;
        // 未钉住时边缘也用于移动；只有可调整大小时才预留原生缩放命中区。
        chrome.ResizeBorderThickness = new Thickness(IsPinned ? 5 : 0);
        pin.Background = IsPinned ? WarmTheme.Apricot : WarmTheme.Floating.Hover; pin.Foreground = IsPinned ? Brushes.White : Ink;
        var icon = new ActionIconView(IsPinned ? ActionIcon.PinFilled : ActionIcon.Pin, 12);
        icon.RenderTransformOrigin = new Point(.5, .5); icon.RenderTransform = pinRotation;
        WarmMotion.Spring(pinRotation, RotateTransform.AngleProperty, IsPinned ? -45 : 0, .3, .6);
        pin.Content = icon; pin.ToolTip = IsPinned ? "取消钉住（Ctrl+P）" : "钉住：置顶、点别处不关闭，可拖动、调整大小（Ctrl+P）";
        if (!IsPinned) {
            freeSized = false; layout.RowDefinitions[1].Height = layout.RowDefinitions[2].Height = GridLength.Auto; Width = 420;
            source.MinHeight = output.MinHeight = 20; SizeToContent = SizeToContent.Height; Render();
        }
        ObserveOutside(); PinChanged?.Invoke(this);
    }
    private void BeginResize()
    {
        if (freeSized) return; freeSized = true; var height = ActualHeight; SizeToContent = SizeToContent.Manual; Height = height;
        layout.RowDefinitions[1].Height = layout.RowDefinitions[2].Height = new GridLength(1, GridUnitType.Star);
        source.MinHeight = output.MinHeight = 40; source.Height = output.Height = double.NaN;
        source.VerticalScrollBarVisibility = output.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
    }
    public Task Recognize(byte[] pixels, int width, int height, double pixelScale = 1) =>
        TranslationController.RecognizeWindow(this, Model, pixels, width, height, pixelScale, read(), ClosedToken);
    private void ShowLanguages(bool forSource)
    {
        var button = forSource ? sourceLanguage : targetLanguage; var menu = Menu(button);
        var auto = new MenuItem { Header = forSource ? "自动检测" : "自动（中文 → 英文，其他 → 简体中文）", IsCheckable = true, IsChecked = (forSource ? Model.SourceChoice : Model.TargetChoice) is null };
        auto.Click += (_, _) => Model.ChooseLanguage(forSource, null); menu.Items.Add(auto); menu.Items.Add(new Separator());
        foreach (var language in LanguageRules.MenuLanguages) {
            var item = new MenuItem { Header = language.Name, IsCheckable = true, IsChecked = language == (forSource ? Model.SourceChoice : Model.TargetChoice) };
            item.Click += (_, _) => Model.ChooseLanguage(forSource, language); menu.Items.Add(item);
        }
        button.ContextMenu = menu; menu.IsOpen = true;
    }
    private void ChooseEngine()
    {
        var menu = Menu(engineButton);
        foreach (var engine in Model.Available) {
            var item = new MenuItem { Header = engine.Name, IsCheckable = true, IsChecked = engine.Id == Model.Engine };
            item.Click += (_, _) => Model.Use(engine.Id); menu.Items.Add(item);
        }
        menu.Items.Add(new Separator()); var settings = new MenuItem { Header = "设置翻译引擎…" };
        settings.Click += (_, _) => { openSettings(); if (!IsPinned) Close(); }; menu.Items.Add(settings); engineButton.ContextMenu = menu; menu.IsOpen = true;
    }
    public void CancelTranslation(bool explain = false) => Model.Cancel(explain);
    private void Copy(string text, string hint)
    {
        if (text.Length == 0) return;
        try { copy(text); ShowHud(hint); } catch { ShowHud("剪贴板正忙，请重试"); }
    }
    private void ShowHud(string text) { if (closed) return; hud?.Close(); hud = new TranslationCopyHud(this, text); }
    private string SpeechIdentity(string part) => speechOwner + ":" + part;
    private void Speak(string text, TranslateLanguage language, string id) => TranslationSpeaker.Shared.Toggle(text, language, SpeechIdentity(id), read().SpeechRate, ShowHud);
    private void RefreshSpeech()
    {
        if (closed) return;
        foreach (var (button, id) in new[] { (sourceSpeech, "source"), (outputSpeech, "translation") }) {
            var active = TranslationSpeaker.Shared.SpeakingId == SpeechIdentity(id);
            button.Content = new ActionIconView(active ? ActionIcon.Stop : ActionIcon.Volume, 12); button.ToolTip = active ? "停止朗读" : "朗读";
            System.Windows.Automation.AutomationProperties.SetName(button, active ? "停止朗读" : "朗读");
            button.Background = active ? WarmTheme.Apricot : WarmTheme.Floating.Hover; button.Foreground = active ? Brushes.White : Ink;
        }
    }
    private void OnKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape && Keyboard.Modifiers == ModifierKeys.None && !composing && !MenuOpen()) { Close(); e.Handled = true; return; }
        if (Keyboard.Modifiers is not (ModifierKeys.Control or (ModifierKeys.Control | ModifierKeys.Shift))) return;
        if (e.Key == Key.C) {
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) Copy(Model.SourceText, "已复制原文");
            else if (Keyboard.FocusedElement is TextBox { SelectionLength: > 0 }) return;
            else Copy(Model.Translation, "已复制译文");
        }
        else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.R) _ = Model.Translate();
        else if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.P) TogglePin();
        else return;
        e.Handled = true;
    }
    private static TextBlock Label(string text) => new() { Text = text, FontSize = 11, Foreground = Ink, Opacity = .58, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    private static TextBlock Message() => new() { FontFamily = WarmTheme.Text, FontSize = 12.5, Foreground = Ink, Opacity = .58, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Top, Visibility = Visibility.Collapsed };
    private static TextBox TextArea(bool readOnly)
    {
        var box = new TextBox { IsReadOnly = readOnly, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0), Background = Brushes.Transparent,
            Foreground = Ink, FontSize = 14, FontFamily = WarmTheme.Text, Padding = new Thickness(0), MinHeight = 20, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, IsReadOnlyCaretVisible = false };
        var style = new Style(typeof(ScrollBar), CaptureChrome.ScrollBarStyle); style.Setters.Add(new Setter(WidthProperty, 10d)); box.Resources[typeof(ScrollBar)] = style; return box;
    }
    private static ContextMenu Menu(Button target) => new() { PlacementTarget = target, Placement = PlacementMode.Bottom, FontFamily = WarmTheme.Text, MaxWidth = 360, MaxHeight = 420, UseLayoutRounding = true };
    private static Button SmallButton(string text, string hint, Action action)
    {
        var button = CaptureChrome.Button(text, hint, action); button.MinWidth = 24; button.Height = 24; button.Padding = new Thickness(9, 0, 9, 0); button.FontSize = 11;
        button.Resources["CaptureRadius"] = new CornerRadius(8); button.Foreground = Ink; button.Background = WarmTheme.Floating.Hover; button.Margin = new Thickness(0, 0, 6, 0); button.FocusVisualStyle = CaptureChrome.RectFocus; return button;
    }
    private static Button MenuButton(string text, string hint, Action action)
    { var button = SmallButton("", hint, action); button.FontSize = 12; button.FontWeight = FontWeights.SemiBold; button.Resources["CaptureRadius"] = new CornerRadius(12); button.FocusVisualStyle = CaptureChrome.MenuFocus; SetMenuTitle(button, text); return button; }
    private static void SetMenuTitle(Button button, string text)
    {
        var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new TextBlock { Text = text, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center });
        var arrow = new ActionIconView(ActionIcon.ChevronDown, 9) { Margin = new Thickness(4, 0, 0, 0) }; Grid.SetColumn(arrow, 1); grid.Children.Add(arrow);
        button.Content = grid; button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
    }
    private static Button SmallIcon(ActionIcon icon, string hint, Action action)
    { var button = SmallButton("", hint, action); button.Width = 26; button.Height = 22; button.Padding = new Thickness(0); button.Margin = new Thickness(0, 0, 4, 0); button.Resources["CaptureRadius"] = new CornerRadius(7); button.Content = new ActionIconView(icon, 12); WarmMotion.SetPressedScale(button, .94); WarmMotion.SetEnabled(button, true); return button; }
    private static Border Card(UIElement area, UIElement label, bool tinted, Action speak, Action copy, out Button speech, out Button copyButton, TextBlock? note = null)
    {
        speech = SmallIcon(ActionIcon.Volume, "朗读", speak); copyButton = SmallIcon(ActionIcon.Copy, "复制", copy);
        var controls = new DockPanel { Margin = new Thickness(0, 8, 0, 0) }; var left = new StackPanel { Orientation = Orientation.Horizontal, Children = { speech, copyButton } };
        DockPanel.SetDock(left, Dock.Left); controls.Children.Add(left); if (label is FrameworkElement element) element.HorizontalAlignment = HorizontalAlignment.Right; controls.Children.Add(label);
        var grid = new Grid(); grid.RowDefinitions.Add(new RowDefinition()); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Children.Add(area); if (note is not null) { note.Margin = new Thickness(0, 8, 0, 0); Grid.SetRow(note, 1); grid.Children.Add(note); }
        Grid.SetRow(controls, 2); grid.Children.Add(controls);
        return new Border { CornerRadius = new CornerRadius(12), Padding = new Thickness(12, 10, 12, 8), Margin = new Thickness(0, 10, 0, 0),
            BorderBrush = WarmTheme.IsDark ? WarmTheme.Brush(255, 230, 204, 31) : WarmTheme.Brush(115, 84, 56, 33), BorderThickness = new Thickness(.5),
            Background = WarmTheme.IsDark ? WarmTheme.Brush(77, 61, 51, tinted ? (byte)110 : (byte)140) : WarmTheme.Brush(255, 252, 249, tinted ? (byte)145 : (byte)184), Child = grid };
    }
    private static StackPanel Placeholder(params double[] widths)
    {
        var panel = new StackPanel { IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Top, Visibility = Visibility.Collapsed };
        foreach (var fraction in widths) { var line = new Border { Height = 8, CornerRadius = new CornerRadius(4), Background = WarmTheme.Floating.Divider, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 4, 0, 4) };
            panel.SizeChanged += (_, _) => line.Width = Math.Max(1, panel.ActualWidth * fraction); panel.Children.Add(line); }
        return panel;
    }
    private static void Pulse(StackPanel panel, bool visible)
    {
        if ((panel.Visibility == Visibility.Visible) == visible) return;
        panel.BeginAnimation(OpacityProperty, null); panel.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        panel.Opacity = 1;
    }
    private static void FitText(TextBox box, double maximum)
    {
        var text = new FormattedText(string.IsNullOrEmpty(box.Text) ? " " : box.Text, System.Globalization.CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
            new Typeface(WarmTheme.Text, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal), 14, Ink, VisualTreeHelper.GetDpi(box).PixelsPerDip) { MaxTextWidth = Math.Max(40, box.ActualWidth > 0 ? box.ActualWidth - 6 : 362) };
        box.Height = Math.Clamp(Math.Ceiling(text.Height) + 2, 20, maximum);
        box.VerticalScrollBarVisibility = text.Height + 2 > maximum ? ScrollBarVisibility.Auto : ScrollBarVisibility.Hidden;
    }
#if DEBUG
    internal string DebugSpeechIdentity(string part) => SpeechIdentity(part);
    internal bool DebugSourceSpeaking => (string?)sourceSpeech.ToolTip == "停止朗读";
    internal void DebugSwap() => Model.SwapLanguages();
    internal void DebugBeginResize() => BeginResize();
    internal bool DebugFreeSized => freeSized;
    internal void DebugShow(string original, string translated) => Model.DebugShow(original, translated);
    internal double DebugSourceHeight => source.ActualHeight;
    internal void DebugEdit(string text) => Model.Edit(text);
    internal bool DebugHasCopyableTranslation => Model.Translation.Length > 0;
    internal void DebugOpenEngineMenu() => ChooseEngine();
    internal bool DebugEngineMenuOpen => engineButton.ContextMenu?.IsOpen == true;
    internal void DebugCloseEngineMenu() { if (engineButton.ContextMenu is { } menu) menu.IsOpen = false; }
    internal string DebugSource => source.Text;
    internal string DebugOutput => output.Text;
#endif
}
