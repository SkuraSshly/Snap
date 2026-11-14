using System.Diagnostics;
using System.IO;
using System.Windows;
using Velos.UI;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using Velos.Core.Settings;
using Velos.Screenshot;

namespace Velos;

public partial class SettingsWindow
{
    private void BuildScreenshotSettings()
    {
        var options = app.Settings.ScreenshotOptions;
        var file = AddGroup("文件");
        var folder = AddFolderOption(file, SavePath(options));
        var pathLabel = folder.Path;
        var folderButtons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        var restoreFolder = new Button
        {
            Content = "恢复默认", Style = (Style)FindResource("PillButton"), Margin = new Thickness(4, 0, 0, 0)
        };
        restoreFolder.Click += (_, _) => SetFolder(null);
        restoreFolder.Visibility = options.Directory is null ? Visibility.Collapsed : Visibility.Visible;
        folderButtons.Children.Add(restoreFolder);
        folderButtons.Children.Add(MakeButton("打开", OpenFolder));
        folderButtons.Children.Add(MakeButton("更改…", () =>
        {
            var dialog = new OpenFolderDialog { Title = "选择截图保存文件夹", InitialDirectory = SavePath(app.Settings.ScreenshotOptions) };
            if (dialog.ShowDialog(this) == true)
                SetFolder(dialog.FolderName);
        }));
        folder.Row.Children.Add(folderButtons);
        Grid.SetColumn(folderButtons, 1);

        var formatChoices = new[] { ScreenshotFormat.Png, ScreenshotFormat.Heic, ScreenshotFormat.Jpeg }
            .Where(value => value != ScreenshotFormat.Heic || ShotEncoding.SupportsHeic || options.Format == value).Select(value => (value, value.ToString().ToUpperInvariant())).ToArray();
        var formats = new WarmSegments<ScreenshotFormat>(formatChoices, () => app.Settings.ScreenshotOptions.Format,
            format => ApplyShotUpdate(state => state with { Format = format }), available: format => format != ScreenshotFormat.Heic || ShotEncoding.SupportsHeic);
        AutomationProperties.SetName(formats, "截图文件格式");
        AddControl(file, "文件格式", formats);
        var quality = new Slider
        {
            Width = 125, Minimum = 60, Maximum = 100, TickFrequency = 5, IsSnapToTickEnabled = true,
            Value = Math.Clamp(options.Quality, 60, 100), VerticalAlignment = VerticalAlignment.Center,
            IsMoveToPointEnabled = true, SmallChange = 5, Style = CaptureChrome.SliderStyle
        };
        quality.Resources["CaptureDivider"] = Velos.UI.WarmTheme.Floating.Divider;
        AutomationProperties.SetName(quality, "压缩质量");
        var qualityLabel = new TextBlock
        {
            Text = $"{quality.Value:0}%", VerticalAlignment = VerticalAlignment.Center,
            Width = 42, Margin = new Thickness(7, 0, 0, 0)
        };
        var qualityBox = new StackPanel { Orientation = Orientation.Horizontal, Children = { quality, qualityLabel } };
        var qualityRow = AddControl(file, "压缩质量", qualityBox);
        qualityRow.Visibility = options.Format == ScreenshotFormat.Png ? Visibility.Collapsed : Visibility.Visible;
        UpdateFormat();
        preferenceRefreshers.Add(UpdateFormat);
        void UpdateFormat()
        {
            formats.Refresh();
            qualityRow.Visibility = app.Settings.ScreenshotOptions.Format == ScreenshotFormat.Png ? Visibility.Collapsed : Visibility.Visible;
        }
        quality.ValueChanged += (_, _) => qualityLabel.Text = $"{quality.Value:0}%";
        preferenceRefreshers.Add(() => quality.Value = Math.Clamp(app.Settings.ScreenshotOptions.Quality, 60, 100));
        void SaveQuality() => ApplyShotUpdate(state => state with { Quality = (int)quality.Value });
        quality.AddHandler(Mouse.PreviewMouseUpEvent, new MouseButtonEventHandler((_, _) => SaveQuality()), true);
        quality.PreviewKeyUp += (_, _) => SaveQuality();
        ScreenshotPage.Children.Add(new TextBlock
        {
            Text = "格式只影响保存文件。复制到剪贴板的始终是无损 PNG。",
            Style = (Style)FindResource("Caption"), Margin = new Thickness(8, -6, 8, 14)
        });

        var picture = AddGroup("画面");
        AddSwitch(picture, "包含鼠标指针", options.IncludeCursor, value => state => state with { IncludeCursor = value }, o => o.IncludeCursor);
        AddSwitch(picture, "按 1x 分辨率输出", options.Downscale, value => state => state with { Downscale = value }, o => o.Downscale,
            "用于普通截图。长截图始终保留显示器原生像素。");

        var output = AddGroup("完成后");
        var copy = AddSwitch(output, "复制到剪贴板", options.Copy, value => state => state with { Copy = value }, o => o.Copy);
        AddSwitch(output, "自动保存到文件", options.AutoSave, value => state => state with { AutoSave = value }, o => o.AutoSave,
            "关闭时可按 Ctrl+S 或点缩略图上的「保存」。");
        var thumbnail = AddSwitch(output, "在屏幕角落显示缩略图", options.Thumbnail, value => state => state with { Thumbnail = value }, o => o.Thumbnail);
        var afterPaste = AddSwitch(output, "粘贴后自动收起缩略图", options.DismissOnPaste,
            value => state => state with { DismissOnPaste = value }, o => o.DismissOnPaste,
            "剪贴板历史工具读取图像时也会触发收起。");
        afterPaste.IsEnabled = copy.IsChecked == true && thumbnail.IsChecked == true;
        copy.Click += (_, _) => afterPaste.IsEnabled = copy.IsChecked == true && thumbnail.IsChecked == true;
        thumbnail.Click += (_, _) => afterPaste.IsEnabled = copy.IsChecked == true && thumbnail.IsChecked == true;
        var outputWarning = new TextBlock { Text = "复制、保存、缩略图都已关闭，截图完成后不会留下结果。", Style = (Style)FindResource("Caption"), Margin = new Thickness(8, -6, 8, 14) };
        ScreenshotPage.Children.Add(outputWarning);
        void RefreshOutput()
        {
            var current = app.Settings.ScreenshotOptions;
            afterPaste.IsEnabled = current.Copy && current.Thumbnail;
            outputWarning.Visibility = !current.Copy && !current.AutoSave && !current.Thumbnail ? Visibility.Visible : Visibility.Collapsed;
        }
        preferenceRefreshers.Add(RefreshOutput); RefreshOutput();

        var scrolling = AddGroup("长截图");
        AddControl(scrolling, "长截图使用方法", new TextBlock { Text = "原生像素", Foreground = WarmTheme.Floating.Ink, FontSize = 11, VerticalAlignment = VerticalAlignment.Center },
            "选区或全屏中点长截图，向下滚动；也可开启「自动滚动」，鼠标移出选区暂停，移回继续。");

        void SetFolder(string? path)
        {
            ApplyShotUpdate(state => state with { Directory = path });
            var current = app.Settings.ScreenshotOptions;
            pathLabel.Text = SavePath(current);
            pathLabel.ToolTip = pathLabel.Text;
            restoreFolder.Visibility = current.Directory is null ? Visibility.Collapsed : Visibility.Visible;
        }

        void OpenFolder()
        {
            try
            {
                var path = SavePath(app.Settings.ScreenshotOptions);
                Directory.CreateDirectory(path);
                using var process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or ArgumentException)
            {
                ShowStatus("无法打开截图文件夹，请检查文件夹路径和访问权限。");
            }
        }
    }

    private bool ApplyShotUpdate(Func<ScreenshotPreferences, ScreenshotPreferences> update)
    {
        var current = app.Settings.ScreenshotOptions;
        var next = update(current);
        var problem = current == next ? null : app.ChangeScreenshotOptions(next);
        ShowStatus(problem);
        return problem is null;
    }

    private static string SavePath(ScreenshotPreferences options) =>
        string.IsNullOrWhiteSpace(options.Directory) ? ShotEncoding.DefaultDirectory : options.Directory;

    private StackPanel AddGroup(string title, Panel? page = null)
    {
        var label = new TextBlock { Text = title, Style = (Style)FindResource("SectionLabel") };
        var content = new StackPanel();
        var card = new Border { Child = content, CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(0.5), Margin = new Thickness(0, 0, 0, 13) };
        card.SetResourceReference(BackgroundProperty, "Card");
        card.SetResourceReference(Border.BorderBrushProperty, "Hairline");
        card.SetResourceReference(EffectProperty, "CardShadow");
        (page ?? ScreenshotPage).Children.Add(label);
        (page ?? ScreenshotPage).Children.Add(card);
        return content;
    }

    private (Grid Row, TextBlock Path) AddFolderOption(Panel group, string path)
    {
        var text = new TextBlock
        {
            Text = path, Style = (Style)FindResource("Caption"), TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center
        };
        text.SetBinding(ToolTipProperty, new Binding(nameof(TextBlock.Text)) { Source = text });
        var badge = new Border { Child = text, CornerRadius = new CornerRadius(9), Padding = new Thickness(7, 3, 7, 3), VerticalAlignment = VerticalAlignment.Center };
        badge.SetResourceReference(BackgroundProperty, "Track");
        return (AddOption(group, "保存到", suffix: badge).Row, text);
    }

    private (Grid Row, StackPanel Label) AddOption(Panel group, string title, string? caption = null, FrameworkElement? suffix = null)
    {
        var row = new Grid { Margin = new Thickness(13, 9, 13, 9), MinHeight = 28 };
        if (group.Children.Count > 0)
        {
            var line = new Border { Height = 0.5, Margin = new Thickness(50, 0, 0, 0) };
            line.SetResourceReference(BackgroundProperty, "Hairline");
            line.SetBinding(VisibilityProperty, new Binding(nameof(Visibility)) { Source = row });
            group.Children.Add(line);
        }
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = new StackPanel { Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
        label.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.Medium, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center });
        if (caption is not null)
            label.Children.Add(new TextBlock { Text = caption, Style = (Style)FindResource("Caption") });
        var (glyph, tint) = title switch
        {
            "保存到" => ("\ue8b7", "#F2AD40"),
            "文件格式" => ("\ue8a5", "#619EE0"),
            "压缩质量" => ("\ue9e9", "#9E85D9"),
            "包含鼠标指针" => ("\ue8b0", "#9E7357"),
            "按 1x 分辨率输出" => ("\ue740", "#9E85D9"),
            "复制到剪贴板" => ("\ue8c8", "#F5945C"),
            "自动保存到文件" => ("\ue896", "#73B378"),
            "在屏幕角落显示缩略图" => ("\ue8b9", "#619EE0"),
            "粘贴后自动收起缩略图" => ("\uea47", "#9E7357"),
            "长截图使用方法" => ("\ue70f", "#F5945C"),
            "分辨率" => ("\ue740", "#619EE0"),
            "帧率" => ("\ue916", "#F2AD40"),
            "编码" => ("\ue950", "#9E85D9"),
            "画质" => ("\ue8b9", "#F5945C"),
            "录制系统声音" => ("\ue767", "#73B378"),
            "录制麦克风" => ("\ue720", "#E87897"),
            "显示鼠标指针" => ("\ue8b0", "#9E7357"),
            "高亮鼠标点击" => ("\ue8b0", "#F5945C"),
            "开始前 3 秒倒计时" => ("\ue916", "#ED5E4D"),
            "完成后在屏幕角落显示缩略图" => ("\ue8b9", "#619EE0"),
            "将录屏转为 GIF" => ("\ue8a5", "#ED5E4D"),
            "最大宽度" => ("\ue8ab", "#F2AD40"),
            "优先识别的语言" => ("\ue774", "#619EE0"),
            "智能排版" => ("\ue8e9", "#F5945C"),
            "同时识别二维码" => ("\ued14", "#9E7357"),
            "默认引擎" => ("\ue734", "#F5945C"),
            "在线翻译" => ("\ue8f2", "#73B378"),
            "默认目标语言" => ("\ue72a", "#619EE0"),
            "翻译完成后自动复制译文" => ("\ue8c8", "#F2AD40"),
            "朗读语速" => ("\ue767", "#73B378"),
            "默认钉住" => ("\ue718", "#F5945C"),
            _ => ("\ue713", "#9E7357")
        };
        var badge = new Border { Style = (Style)FindResource("Badge"), Background = WarmTheme.Badge(BrushOf(tint)), Child = new TextBlock
        {
            Text = glyph, Style = (Style)FindResource("BadgeGlyph")
        }};
        ActionIcon? icon = title switch
        {
            "包含鼠标指针" or "显示鼠标指针" => ActionIcon.Pointer,
            "帧率" => ActionIcon.FrameRate,
            "分辨率" or "按 1x 分辨率输出" => ActionIcon.Resolution,
            "画质" or "压缩质量" => ActionIcon.Quality,
            "将录屏转为 GIF" => ActionIcon.Gif,
            "在线翻译" or "默认目标语言" => ActionIcon.Translate,
            _ => ActionIconView.FromGlyph(glyph)
        };
        if (icon is { } semanticIcon) badge.Child = new ActionIconView(semanticIcon, 13) { Ink = Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        if (title == "粘贴后自动收起缩略图") badge.Visibility = Visibility.Hidden;
        var identity = new Grid();
        identity.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        identity.ColumnDefinitions.Add(new ColumnDefinition());
        identity.Children.Add(badge);
        FrameworkElement labelContent = label;
        if (suffix is not null)
        {
            var inline = new Grid { Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
            inline.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            inline.ColumnDefinitions.Add(new ColumnDefinition());
            inline.Children.Add(label); inline.Children.Add(suffix); Grid.SetColumn(suffix, 1);
            labelContent = inline;
        }
        identity.Children.Add(labelContent);
        Grid.SetColumn(labelContent, 1);
        row.Children.Add(identity);
        group.Children.Add(row);
        return (row, label);
    }

    private Grid AddControl(Panel group, string title, FrameworkElement control, string? caption = null)
    {
        var (row, _) = AddOption(group, title, caption);
        control.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(control);
        Grid.SetColumn(control, 1);
        return row;
    }

    private CheckBox AddSwitch(Panel group, string name, bool enabled,
        Func<bool, Func<ScreenshotPreferences, ScreenshotPreferences>> change, Func<ScreenshotPreferences, bool> read, string? caption = null)
    {
        var toggle = new CheckBox { IsChecked = enabled, Style = (Style)FindResource("Switch") };
        preferenceRefreshers.Add(() => toggle.IsChecked = read(app.Settings.ScreenshotOptions));
        AutomationProperties.SetName(toggle, name);
        toggle.Click += (_, _) =>
        {
            ApplyShotUpdate(change(toggle.IsChecked == true));
            toggle.IsChecked = read(app.Settings.ScreenshotOptions);
        };
        AddControl(group, name, toggle, caption);
        return toggle;
    }

    private Button MakeButton(string text, Action invoke)
    {
        var button = new Button { Content = text, Style = (Style)FindResource("PillButton"), FocusVisualStyle = null, Margin = new Thickness(4, 0, 0, 0) };
        button.Click += (_, _) => invoke();
        return button;
    }

}
