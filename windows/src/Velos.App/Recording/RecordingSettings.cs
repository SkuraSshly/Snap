using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using Microsoft.Win32;
using Velos.Core.Settings;
using Velos.Recording;
using Velos.Windows.Recording;
using Velos.UI;

namespace Velos;

public partial class SettingsWindow
{
    private void BuildRecordingSettings()
    {
        var options = app.Settings.RecordingOptions;
        var file = AddGroup("文件", RecordingPage);
        var folder = AddFolderOption(file, RecordingPath());
        var path = folder.Path;
        var restoreFolder = MakeButton("恢复默认", () => ChangeRecording(p => p with { Directory = null }));
        restoreFolder.Click += (_, _) => RefreshFolder();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Children = {
            restoreFolder,
            MakeButton("打开", () => { try { Directory.CreateDirectory(RecordingPath()); Process.Start(new ProcessStartInfo(RecordingPath()) { UseShellExecute = true }); } catch { ShowStatus("无法打开录屏文件夹。"); } }),
            MakeButton("更改…", () => { var dialog = new OpenFolderDialog { Title = "选择录屏保存文件夹", InitialDirectory = RecordingPath() };
                if (dialog.ShowDialog(this) == true) { ChangeRecording(p => p with { Directory = dialog.FolderName }); RefreshFolder(); } }) } };
        folder.Row.Children.Add(buttons); Grid.SetColumn(buttons, 1);
        RefreshFolder();
        void RefreshFolder() { path.Text = RecordingPath(); restoreFolder.Visibility = app.Settings.RecordingOptions.Directory is null ? Visibility.Collapsed : Visibility.Visible; }
        RecordingCaption("录屏总是自动保存为 MP4。文件名示例：录屏 2026-11-11 23.40.02.mp4");
        var picture = AddGroup("画面", RecordingPage);
        var first = Pair(picture); var second = Pair(picture);
        Choices(first.Left, "分辨率", new[] { (RecordingResolution.Native, "原生"), (RecordingResolution.P1080, "1080p") }, p => p.Resolution, (p, v) => p with { Resolution = v });
        Choices(first.Right, "帧率", new[] { (60, "60 fps"), (30, "30 fps") }, p => p.FrameRate, (p, v) => p with { FrameRate = v });
        Choices(second.Left, "编码", new[] { (VideoCodec.Hevc, "HEVC"), (VideoCodec.H264, "H.264") }, p => p.Codec, (p, v) => p with { Codec = v });
        Choices(second.Right, "画质", new[] { (VideoQuality.High, "高"), (VideoQuality.Ultra, "极高") }, p => p.Quality, (p, v) => p with { Quality = v });
        RecordingCaption("HEVC：画质高、体积小。系统无可用编码器时自动使用 H.264。");
        var audio = AddGroup("声音", RecordingPage);
        RecordingSwitch(audio, "录制系统声音", p => p.SystemAudio, (p, v) => p with { SystemAudio = v });
        RecordingSwitch(audio, "录制麦克风", p => p.Microphone, (p, v) => p with { Microphone = v });
        RecordingCaption("录制时可在选区旁的选项条里临时更改，会记住上次的选择。");
        var recording = AddGroup("录制", RecordingPage);
        RecordingSwitch(recording, "显示鼠标指针", p => p.ShowCursor, (p, v) => p with { ShowCursor = v });
        RecordingSwitch(recording, "高亮鼠标点击", p => p.HighlightClicks, (p, v) => p with { HighlightClicks = v }, "点击处出现杏色圆圈（右键为珊瑚色），会录进视频。");
        RecordingSwitch(recording, "开始前 3 秒倒计时", p => p.Countdown, (p, v) => p with { Countdown = v }, "倒计时期间按 Esc 取消，按 Enter 立即开始。");
        RecordingSwitch(recording, "完成后在屏幕角落显示缩略图", p => p.Thumbnail, (p, v) => p with { Thumbnail = v }, "缩略图上可以预览、拷贝文件、导出 GIF、移到回收站。");
        var gif = AddGroup("GIF", RecordingPage);
        var export = MakeButton("选择录屏…", ConvertExistingRecording);
        AddControl(gif, "将录屏转为 GIF", export, "GIF 保存在视频旁边。");
        Choices(gif, "帧率", new[] { (10, "10 fps"), (15, "15 fps"), (20, "20 fps") }, p => p.GifFrameRate, (p, v) => p with { GifFrameRate = v });
        Choices(gif, "最大宽度", new[] { (0, "原宽"), (1280, "1280"), (960, "960"), (640, "640") }, p => p.GifMaxWidth, (p, v) => p with { GifMaxWidth = v });
        RecordingCaption("刚录完可在缩略图上点「GIF」；之前的录屏用上面的「选择录屏…」。GIF 最多 256 色，适合界面演示。");
    }
    private void ConvertExistingRecording()
    {
        var dialog = new OpenFileDialog { Title = "选择录屏转为 GIF", Filter = "视频文件|*.mp4;*.mov;*.m4v;*.wmv|所有文件|*.*", InitialDirectory = RecordingPath() };
        if (dialog.ShowDialog(this) != true) return;
        app.ExportExistingGif(dialog.FileName, this);
    }
    private string RecordingPath() => app.Settings.RecordingOptions.Directory ?? RecordingController.DefaultDirectory;
    private void ChangeRecording(Func<RecordingPreferences, RecordingPreferences> change) => ShowStatus(app.ChangeRecordingOptions(change(app.Settings.RecordingOptions)));
    private void RecordingCaption(string text) => RecordingPage.Children.Add(new TextBlock { Text = text, Style = (Style)FindResource("Caption"), Margin = new Thickness(7, -6, 7, 14) });
    private void RecordingSwitch(Panel group, string name, Func<RecordingPreferences, bool> read, Func<RecordingPreferences, bool, RecordingPreferences> change, string? caption = null)
    {
        var toggle = new CheckBox { Style = (Style)FindResource("Switch"), IsChecked = read(app.Settings.RecordingOptions) };
        preferenceRefreshers.Add(() => toggle.IsChecked = read(app.Settings.RecordingOptions));
        toggle.Click += (_, _) => { ChangeRecording(p => change(p, toggle.IsChecked == true)); toggle.IsChecked = read(app.Settings.RecordingOptions); };
        System.Windows.Automation.AutomationProperties.SetName(toggle, name); AddControl(group, name, toggle, caption);
    }
    private void Choices<T>(Panel group, string title, (T Value, string Text)[] choices, Func<RecordingPreferences, T> read, Func<RecordingPreferences, T, RecordingPreferences> change)
    {
        var width = group.Tag is "SettingsPair" ? 56 : title == "最大宽度" ? 54 : title == "帧率" ? 58 : 62;
        var segments = new WarmSegments<T>(choices, () => read(app.Settings.RecordingOptions), value => ChangeRecording(p => change(p, value)), width);
        AddControl(group, title, segments); preferenceRefreshers.Add(() => segments.Refresh());
    }
    private static (StackPanel Left, StackPanel Right) Pair(Panel parent)
    {
        if (parent.Children.Count > 0) { var line = new Border { Height = .5, Margin = new Thickness(50, 0, 0, 0) }; line.SetResourceReference(Border.BackgroundProperty, "Hairline"); parent.Children.Add(line); }
        var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(.5) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
        var divider = new Border { Margin = new Thickness(0, 9, 0, 9) }; divider.SetResourceReference(Border.BackgroundProperty, "Hairline"); Grid.SetColumn(divider, 1); grid.Children.Add(divider);
        var left = new StackPanel { Tag = "SettingsPair" }; var right = new StackPanel { Tag = "SettingsPair" }; grid.Children.Add(left); grid.Children.Add(right); Grid.SetColumn(right, 2); parent.Children.Add(grid);
        return (left, right);
    }
}
