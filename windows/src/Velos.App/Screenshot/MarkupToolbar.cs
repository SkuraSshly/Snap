using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using Velos.Core.Settings;
using Velos.UI;
using Velos.Windows.Capture;

namespace Velos.Screenshot;

internal enum ShotAction { Done, Save, Copy, Pin, Cancel, Edit, LongCapture }

internal static class CaptureChrome
{
    public static Brush Ink => WarmTheme.Floating.Ink;
    public static Brush Apricot => WarmTheme.Apricot;
    public static Brush Paper => WarmTheme.Floating.Paper;
    public static Brush Line => WarmTheme.Floating.Outline;
    public static Style RectFocus => (Style)Styles.Value["WarmRectFocus"];
    public static Style MenuFocus => (Style)Styles.Value["WarmMenuFocus"];
    private static readonly Lazy<ResourceDictionary> Styles = new(() => new ResourceDictionary
    {
        Source = new Uri("pack://application:,,,/Screenshot/CaptureChrome.xaml")
    });

    public static Button Button(string text, string title, Action click, bool primary = false)
    {
        var button = new Button
        {
            Content = text, ToolTip = title, Style = (Style)Styles.Value["CaptureButton"],
            FocusVisualStyle = (Style)Styles.Value["WarmFocus"], Cursor = Cursors.Hand, Foreground = Ink, FontFamily = WarmTheme.Text,
            UseLayoutRounding = true, SnapsToDevicePixels = true
        };
        button.Resources["CaptureHover"] = WarmTheme.Floating.Hover;
        button.Resources["CapturePressed"] = WarmTheme.Floating.Pressed;
        button.Resources["CaptureRadius"] = new CornerRadius(16);
        AutomationProperties.SetName(button, title);
        if (primary)
        {
            button.Background = Apricot;
            button.Foreground = Brushes.White;
            button.FontWeight = FontWeights.SemiBold;
            button.FontSize = 13;
            button.Padding = new Thickness(13, 0, 13, 0);
        }
        button.Click += (_, _) => click();
        return button;
    }

    public static Border Pill(UIElement child) => new()
    {
        Background = WarmTheme.Floating.Surface, BorderBrush = Line, BorderThickness = new Thickness(.5), CornerRadius = new CornerRadius(21),
        Padding = new Thickness(5, 4.5, 5, 4.5), Child = child, HorizontalAlignment = HorizontalAlignment.Right,
        Effect = SystemParameters.HighContrast ? null : new DropShadowEffect { Color = Color.FromRgb(64, 38, 20), BlurRadius = 14, ShadowDepth = 4, Opacity = .22 },
        UseLayoutRounding = true, SnapsToDevicePixels = true
    };

    public static Button PinButton(Action click) => IconButton(ActionIcon.Pin, "钉图", click);
    public static Button SaveButton(Action click) => IconButton(ActionIcon.Save, "保存", click);

    public static Button IconButton(ActionIcon icon, string title, Action click, string? caption = null)
    {
        var button = Button("", title, click, caption is not null);
        var symbol = new ActionIconView(icon, caption is null ? 16 : 14);
        if (caption is null) button.Content = symbol;
        else { symbol.Margin = new Thickness(0, 0, 6, 0); button.Content = new StackPanel { Orientation = Orientation.Horizontal,
            Children = { symbol, new TextBlock { Text = caption, VerticalAlignment = VerticalAlignment.Center } } }; }
        return button;
    }

    public static Button IconButton(string glyph, string title, Action click, string? caption = null)
    {
        if (ActionIconView.FromGlyph(glyph) is { } icon) return IconButton(icon, title, click, caption);
        var button = Button("", title, click, primary: caption is not null);
        var symbol = WarmTheme.Glyph(glyph, caption is null ? 14 : 13);
        if (caption is null)
        {
            button.Content = symbol;
        }
        else
        {
            symbol.Margin = new Thickness(0, 0, 6, 0);
            button.Content = new StackPanel { Orientation = Orientation.Horizontal, Children =
            {
                symbol, new TextBlock { Text = caption, VerticalAlignment = VerticalAlignment.Center }
            }};
        }
        return button;
    }

    public static Button LongCaptureButton(Action click)
    {
        var button = Button("", "长截图", click);
        button.Content = new Border
        {
            Width = 18, Height = 18, Background = Ink,
            OpacityMask = new ImageBrush(WarmTheme.Image("long-capture-3x"))
        };
        return button;
    }

    public static Style SliderStyle => (Style)Styles.Value["CaptureSlider"];
    public static Style OverlayScrollStyle => (Style)Styles.Value["OverlayScrollViewer"];
    public static Style ScrollBarStyle => (Style)Styles.Value["WarmScrollBar"];
}

internal sealed class MarkupToolbar : StackPanel
{
    private readonly MarkCanvas canvas;
    private readonly Dictionary<Tool, Button> tools = [];
    private readonly WrapPanel controls = new();
    private readonly Border properties;
    private readonly Button undo;
    private readonly Button redo;
    private readonly Button? longCapture;
    private readonly Func<bool>? canStartLongCapture;
    private Tool? shownTool;
    private Tool? shownActiveTool;
    private ToolStyle? shownStyle;
    private bool initialized;
    private bool editingProperties;
    private AnnotationColorPicker? colorPicker;
    public bool IsPickingColor => colorPicker?.IsOpen == true;

    public MarkupToolbar(MarkCanvas canvas, Action<ShotAction> action, Func<bool>? canStartLongCapture = null)
    {
        this.canvas = canvas;
        this.canStartLongCapture = canStartLongCapture;
        var bar = new WrapPanel();
        foreach (var tool in Enum.GetValues<Tool>())
        {
            var info = ToolInfo.For(tool);
            var icon = tool switch { Tool.Rectangle => ActionIcon.Rectangle, Tool.Ellipse => ActionIcon.Ellipse, Tool.Arrow => ActionIcon.Arrow,
                Tool.Line => ActionIcon.Line, Tool.Pen => ActionIcon.Pen, Tool.Highlighter => ActionIcon.Highlighter,
                Tool.Text => ActionIcon.Text, Tool.Counter => ActionIcon.Counter, Tool.Mosaic => ActionIcon.Mosaic, _ => ActionIcon.Blur };
            var button = CaptureChrome.IconButton(icon, info.Name, () => canvas.SelectTool(tool));
            tools.Add(tool, button);
            bar.Children.Add(button);
        }
        AddDivider(bar);
        undo = CaptureChrome.IconButton("\ue7a7", "撤销（Ctrl+Z）", canvas.Undo);
        redo = CaptureChrome.IconButton("\ue7a6", "重做（Ctrl+Shift+Z）", canvas.Redo);
        bar.Children.Add(undo);
        bar.Children.Add(redo);
        AddDivider(bar);
        if (canStartLongCapture is not null)
        {
            longCapture = CaptureChrome.LongCaptureButton(() => action(ShotAction.LongCapture));
            bar.Children.Add(longCapture);
        }
        bar.Children.Add(CaptureChrome.PinButton(() => action(ShotAction.Pin)));
        bar.Children.Add(CaptureChrome.SaveButton(() => action(ShotAction.Save)));
        AddDivider(bar);
        bar.Children.Add(CaptureChrome.IconButton("\ue711", "取消（Esc）", () => action(ShotAction.Cancel)));
        bar.Children.Add(CaptureChrome.IconButton("\ue73e", "完成（Enter）", () => action(ShotAction.Done), "完成"));
        Children.Add(CaptureChrome.Pill(bar));
        properties = CaptureChrome.Pill(controls);
        properties.Margin = new Thickness(0, 8, 0, 0);
        Children.Add(properties);
        canvas.Changed += Update;
        Unloaded += (_, _) => { if (colorPicker is not null) colorPicker.IsOpen = false; };
        Update();
    }

    public event Action? MetricsChanged;

    public void UpdateLongCapture()
    {
        if (longCapture is not null)
            longCapture.IsEnabled = canStartLongCapture!();
    }

    private void Update()
    {
        undo.IsEnabled = canvas.CanUndo;
        redo.IsEnabled = canvas.CanRedo;
        UpdateLongCapture();
        var tool = canvas.DisplayedTool;
        var style = canvas.DisplayedStyle;
        if (initialized && shownTool == tool && shownStyle == style && shownActiveTool == canvas.ActiveTool)
            return;
        var previousTool = shownTool;
        initialized = true;
        shownTool = tool;
        shownActiveTool = canvas.ActiveTool;
        shownStyle = style;
        foreach (var item in tools)
        {
            item.Value.Background = item.Key == canvas.ActiveTool ? CaptureChrome.Apricot : Brushes.Transparent;
            item.Value.Foreground = item.Key == canvas.ActiveTool ? Brushes.White : CaptureChrome.Ink;
        }
        var toolChanged = controls.Children.Count == 0 || previousTool != tool;
        if (!toolChanged && style is not null && editingProperties) return;
        controls.Children.Clear();
        properties.Visibility = style is null ? Visibility.Collapsed : Visibility.Visible;
        if (tool is { } current && style is { } value)
            BuildProperties(current, value);
        MetricsChanged?.Invoke();
    }

    private void BuildProperties(Tool tool, ToolStyle style)
    {
        if (ToolInfo.HasColor(tool))
        {
            (uint Rgb, string Title)[] colors =
                [(0xff3b30, "红色"), (0xffcc00, "黄色"), (0x33c759, "绿色"),
                 (0x0a85ff, "蓝色"), (0xffffff, "白色"), (0x000000, "黑色")];
            foreach (var (rgb, title) in colors)
            {
                var button = CaptureChrome.Button("", title, () => canvas.SetStyle((canvas.DisplayedStyle ?? style) with { Rgb = rgb }));
                button.Width = button.MinWidth = 28; button.Padding = new Thickness(0);
                button.Resources["CaptureHover"] = button.Resources["CapturePressed"] = Brushes.Transparent;
                var dot = new Border
                {
                    Width = 18, Height = 18, CornerRadius = new CornerRadius(9),
                    Background = new SolidColorBrush(Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb)),
                    BorderBrush = WarmTheme.Brush(255, 255, 255, 230), BorderThickness = new Thickness(1.5),
                    Effect = new DropShadowEffect { Color = Color.FromRgb(77, 46, 26), BlurRadius = 2, ShadowDepth = 1, Opacity = .25 }
                };
                var ring = new Border { Width = 25, Height = 25, CornerRadius = new CornerRadius(13), BorderBrush = CaptureChrome.Apricot,
                    BorderThickness = new Thickness(2), Visibility = rgb == style.Rgb ? Visibility.Visible : Visibility.Hidden };
                button.Content = new Grid { Width = 26, Height = 26, Children = { ring, dot } };
                controls.Children.Add(button);
            }
            Button custom = null!;
            custom = CaptureChrome.IconButton(ActionIcon.Palette, "自定义颜色", () =>
            {
                if (colorPicker is not null) { colorPicker.IsOpen = false; return; }
                editingProperties = true; canvas.BeginStyleEdit();
                colorPicker = new AnnotationColorPicker(custom, (canvas.DisplayedStyle ?? style).Rgb, picked =>
                { var current = canvas.DisplayedStyle ?? style; canvas.SetStyle(current with { Rgb = picked.Rgb, Opacity = picked.Opacity ?? current.Opacity }); });
                colorPicker.Closed += (_, _) => { colorPicker = null; editingProperties = false; canvas.EndStyleEdit(); Update(); canvas.FocusTextEditor();
#if DEBUG
                    DebugPickerClosed?.Invoke();
#endif
                };
                colorPicker.IsOpen = true;
            });
            custom.Width = custom.MinWidth = 28; custom.Padding = new Thickness(0); controls.Children.Add(custom);
            if (!colors.Any(color => color.Rgb == style.Rgb))
            {
                var selectedColor = Color.FromRgb((byte)(style.Rgb >> 16), (byte)(style.Rgb >> 8), (byte)style.Rgb);
                custom.Content = new Grid { Width = 26, Height = 26, Children = {
                    new Border { Width = 25, Height = 25, CornerRadius = new CornerRadius(13), BorderThickness = new Thickness(2), BorderBrush = CaptureChrome.Apricot },
                    new Border { Width = 18, Height = 18, CornerRadius = new CornerRadius(9), Background = new SolidColorBrush(selectedColor), BorderThickness = new Thickness(1.5), BorderBrush = Brushes.White } } };
            }
            AddDivider(controls);
        }
        var info = ToolInfo.For(tool);
        AddSlider(info.SizeLabel, info.Min, info.Max, style.Size, 1, "", number => canvas.SetStyle((canvas.DisplayedStyle ?? style) with { Size = (int)number }));
        if (ToolInfo.SupportsFill(tool))
        {
            var fill = CaptureChrome.IconButton(tool == Tool.Ellipse ? ActionIcon.FillEllipse : tool == Tool.Text ? ActionIcon.FillText : ActionIcon.FillRectangle,
                tool == Tool.Text ? "文字底色" : "实心", () => { var current = canvas.DisplayedStyle ?? style; canvas.SetStyle(current with { Filled = !current.Filled }); });
            fill.Background = style.Filled ? CaptureChrome.Apricot : Brushes.Transparent; fill.Foreground = style.Filled ? Brushes.White : CaptureChrome.Ink;
            controls.Children.Add(fill);
        }
        if (ToolInfo.HasColor(tool))
        {
            AddDivider(controls);
            AddSlider("不透明度", 10, 100, style.Opacity * 100, 1, "%", number => canvas.SetStyle((canvas.DisplayedStyle ?? style) with { Opacity = number / 100 }), false);
        }
    }

    private void AddSlider(string name, double min, double max, double value, double tick, string suffix, Action<double> apply, bool showTitle = true)
    {
        var group = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(5, 0, 5, 0), Height = 32 };
        var slider = new Slider
        {
            Minimum = min, Maximum = max, Value = value, TickFrequency = tick, IsSnapToTickEnabled = true,
            SmallChange = showTitle ? tick : 5, LargeChange = tick * 5, Width = 76, VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(5, 0, 5, 0), IsMoveToPointEnabled = true, Style = CaptureChrome.SliderStyle
        };
        slider.Resources["CaptureDivider"] = WarmTheme.Floating.Divider;
        AutomationProperties.SetName(slider, name);
        var number = Label($"{value:0}{suffix}");
        number.MinWidth = suffix.Length == 0 ? 23 : 36;
        slider.ValueChanged += (_, _) => { number.Text = $"{slider.Value:0}{suffix}"; apply(slider.Value); };
        slider.AddHandler(Mouse.PreviewMouseDownEvent, new MouseButtonEventHandler((_, _) => { editingProperties = true; canvas.BeginStyleEdit(); }), true);
        void EndEdit() => slider.Dispatcher.BeginInvoke(() => { editingProperties = false; canvas.EndStyleEdit(); Update(); });
        slider.AddHandler(Mouse.PreviewMouseUpEvent,
            new MouseButtonEventHandler((_, _) => EndEdit()), true);
        slider.LostMouseCapture += (_, _) => EndEdit();
        slider.LostKeyboardFocus += (_, _) => EndEdit();
        slider.PreviewKeyDown += (_, e) => { if (e.Key is Key.Left or Key.Right or Key.Up or Key.Down or Key.Home or Key.End) { editingProperties = true; canvas.BeginStyleEdit(); } };
        slider.PreviewKeyUp += (_, e) =>
        {
            if (e.Key is Key.Left or Key.Right or Key.Up or Key.Down or Key.Home or Key.End)
                EndEdit();
        };
        if (showTitle) group.Children.Add(Label(name));
        group.Children.Add(slider);
        group.Children.Add(number);
        controls.Children.Add(group);
    }

    private static TextBlock Label(string text) => new()
    {
        Text = text, FontSize = 12, FontWeight = FontWeights.SemiBold,
        VerticalAlignment = VerticalAlignment.Center, Foreground = CaptureChrome.Ink
    };

    private static void AddDivider(Panel panel) => panel.Children.Add(new Border
    {
        Width = 1, Height = 15, Margin = new Thickness(3, 0, 3, 0),
        Background = CaptureChrome.Line, VerticalAlignment = VerticalAlignment.Center
    });
#if DEBUG
    internal AnnotationColorPicker? DebugColorPicker => colorPicker;
    internal Action? DebugPickerClosed;
#endif
}
