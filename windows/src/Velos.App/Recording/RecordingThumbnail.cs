using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.VisualBasic.FileIO;
using Velos.Core.Settings;
using Velos.Core.Recording;
using Velos.Screenshot;
using Velos.Windows.Capture;
using Velos.Windows.Recording;
using Velos.UI;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.Recording;

internal sealed class RecordingThumbnail : Window
{
    private string path;
    private readonly string videoPath;
    private readonly Action<string> notify;
    private readonly Func<RecordingPreferences> read;
    private readonly TextBlock status;
    private readonly Button gif;
    private readonly Button close;
    private readonly Button delete;
    private readonly StackPanel tools;
    private readonly TextBlock duration;
    private readonly Display display;
    private readonly double scale;
    private bool isGif;
    private readonly CancellationTokenSource lifetime = new();
    private readonly DispatcherTimer dismiss = new() { Interval = TimeSpan.FromSeconds(10) };
    private CancellationTokenSource? conversion;
    private Task conversionFinished = Task.CompletedTask;
    internal Task PendingConversion => conversionFinished;
    private Point? drag;
    public RecordingThumbnail(string path, Display display, double scale, Func<RecordingPreferences> read, Action<string> notify, Action<string> preview, Action<string>? beforeDelete = null)
    {
        this.path = videoPath = path; this.read = read; this.notify = notify; this.display = display; this.scale = scale;
        Title = "Velos 录屏缩略图"; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        ShowActivated = false; ShowInTaskbar = false; Topmost = true; Background = CaptureChrome.Paper;
        var poster = new Image { Stretch = Stretch.UniformToFill, Cursor = Cursors.Hand };
        status = new TextBlock { Text = "录屏已保存", Foreground = CaptureChrome.Ink, FontFamily = Velos.UI.WarmTheme.Text,
            FontSize = 12, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(8), VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
        gif = CaptureChrome.Button("GIF", "导出 GIF", Convert);
        Button copyButton = null!;
        copyButton = CaptureChrome.IconButton(ActionIcon.Copy, "复制文件", () => { if (CopyFile(this.path, notify)) WarmMotion.Copied(copyButton); });
        delete = CaptureChrome.IconButton("\ue74d", "移到回收站", () => { beforeDelete?.Invoke(this.path); Recycle(); }); delete.HorizontalAlignment = HorizontalAlignment.Right; delete.VerticalAlignment = VerticalAlignment.Top; delete.Margin = new Thickness(5);
        tools = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(5), Children =
        {
            gif,
            copyButton,
            CaptureChrome.IconButton("\ue8b7", "显示文件", () => { try { Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{this.path}\"") { UseShellExecute = true }); } catch { notify("无法打开文件夹。"); } })
        }};
        close = CaptureChrome.IconButton("\ue711", "关闭缩略图（转换中关闭会取消）", () => { conversion?.Cancel(); WarmMotion.CloseWindow(this); });
        close.HorizontalAlignment = HorizontalAlignment.Left; close.VerticalAlignment = VerticalAlignment.Top; close.Margin = new Thickness(3);
        foreach (var button in tools.Children.Cast<Button>().Append(close).Append(delete))
        { button.MinWidth = button.Width = button.Height = button.MinHeight = 26; button.Padding = new Thickness(3, 0, 3, 0); button.Background = CaptureChrome.Paper; button.FontSize = 9.5; button.Resources["CaptureRadius"] = new CornerRadius(13); if (button.Content is ActionIconView icon) button.Content = new ActionIconView(icon.Kind, 12); }
        gif.FontWeight = FontWeights.ExtraBold;
        duration = new TextBlock { Text = "▶ 00:00", FontSize = 10, FontFamily = Velos.UI.WarmTheme.Text, Foreground = CaptureChrome.Ink, FontWeight = FontWeights.SemiBold };
        var badge = new Border { Background = CaptureChrome.Paper, CornerRadius = new CornerRadius(9), Padding = new Thickness(6, 3, 6, 3), Margin = new Thickness(7),
            Child = duration, IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Left };
        status.IsHitTestVisible = false;
        var grid = new Grid { Children = { poster, badge, status, close, delete, tools } };
        close.Visibility = delete.Visibility = tools.Visibility = Visibility.Collapsed;
        Content = new Border { BorderBrush = CaptureChrome.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12),
            Child = grid };
        poster.MouseLeftButtonDown += (_, e) => { if (conversion is not null) return; drag = e.GetPosition(poster); poster.CaptureMouse(); };
        poster.MouseLeftButtonUp += (_, _) =>
        {
            if (drag is null || conversion is not null) return; drag = null; poster.ReleaseMouseCapture();
            if (isGif) { try { Process.Start(new ProcessStartInfo(this.path) { UseShellExecute = true }); } catch { notify("无法打开 GIF。"); } }
            else preview(this.path); Close();
        };
        poster.MouseMove += (_, e) =>
        {
            if (drag is not { } start || e.LeftButton != MouseButtonState.Pressed) return;
            var at = e.GetPosition(poster);
            if (Math.Abs(at.X - start.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(at.Y - start.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            drag = null; poster.ReleaseMouseCapture();
            var data = new DataObject(); data.SetFileDropList(new StringCollection { this.path });
            try { if (DragDrop.DoDragDrop(poster, data, DragDropEffects.Copy) != DragDropEffects.None) Close(); } catch (Exception error) { notify($"无法拖出文件。（0x{error.HResult:X8}）"); }
        };
        poster.LostMouseCapture += (_, _) => drag = null;
        MouseEnter += (_, _) => { dismiss.Stop(); close.Visibility = Visibility.Visible; delete.Visibility = tools.Visibility = conversion is null ? Visibility.Visible : Visibility.Collapsed; badge.Visibility = ActualWidth < tools.ActualWidth + badge.ActualWidth + 18 ? Visibility.Collapsed : Visibility.Visible; };
        MouseLeave += (_, _) => { badge.Visibility = Visibility.Visible; if (conversion is null) { close.Visibility = delete.Visibility = tools.Visibility = Visibility.Collapsed; dismiss.Start(); } };
        dismiss.Tick += (_, _) => { dismiss.Stop(); WarmMotion.CloseWindow(this); };
        Closed += (_, _) => { dismiss.Stop(); lifetime.Cancel(); conversion?.Cancel(); lifetime.Dispose(); Desktop.ForgetScreenshotWindow(new WindowInteropHelper(this).Handle); };
        _ = LoadPoster(poster, lifetime.Token);
    }
    private async Task LoadPoster(Image target, CancellationToken token)
    {
        try
        {
            var result = await ReadPoster(path, token);
            if (!token.IsCancellationRequested && result.Image is { } image)
            {
                target.Source = image; duration.Text = (isGif ? "GIF " : "▶ ") + RecordingGeometry.Clock(result.Duration);
                var size = Velos.Core.Screenshot.ScreenshotLayout.ThumbnailSize(new(image.PixelWidth, image.PixelHeight), scale); Place(size.Width, size.Height);
            }
        }
        catch (OperationCanceledException) { }
        catch { if (!token.IsCancellationRequested) { status.Text = "点击预览录屏"; status.Visibility = Visibility.Visible; } }
        finally { if (!token.IsCancellationRequested) { if (!IsVisible) Place(240, 135); if (conversion is null && !IsMouseOver) dismiss.Start(); } }
    }
    private void Place(double dipWidth, double dipHeight)
    {
        var width = (int)Math.Ceiling(dipWidth * scale); var height = (int)Math.Ceiling(dipHeight * scale);
        var hwnd = new WindowInteropHelper(this).EnsureHandle(); Desktop.MakeNonActivating(hwnd);
        Desktop.ExcludeForScreenshots(hwnd);
        ThumbnailShelf.Place(this, display, scale, width, height, bounds =>
        {
            Desktop.Position(hwnd, bounds);
            if (!IsVisible) { Show(); Desktop.Position(hwnd, bounds); WarmMotion.EnterWindow(this); }
            Desktop.RoundWindow(hwnd, bounds.Width, bounds.Height, (int)(12 * scale));
        });
    }
    internal static Task<(BitmapSource? Image, TimeSpan Duration)> ReadPoster(string path, CancellationToken token) => Task.Run<(BitmapSource?, TimeSpan)>(() =>
    {
        token.ThrowIfCancellationRequested(); using var reader = new VideoReader(path, 600);
        var sample = reader.Read(); if (sample is null) return (null, reader.Duration);
        var pixels = sample.Value.Pixels;
        var image = BitmapSource.Create(pixels.Width, pixels.Height, 96, 96, PixelFormats.Bgr32, null, pixels.Bgra, pixels.Width * 4);
        image.Freeze(); return (image, reader.Duration);
    }, token);
    private async void Convert()
    {
        if (conversion is not null) { conversion.Cancel(); return; }
        if (isGif) return;
        drag = null; Mouse.Capture(null); dismiss.Stop(); conversion = new CancellationTokenSource(); delete.Visibility = tools.Visibility = Visibility.Collapsed; close.Visibility = Visibility.Visible;
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); conversionFinished = finished.Task;
        status.Text = "正在生成 GIF…"; status.Visibility = Visibility.Visible;
        try
        {
            var options = read();
            var output = await GifExporter.Export(videoPath, options.GifFrameRate, options.GifMaxWidth,
                new Progress<double>(fraction => status.Text = $"正在生成 GIF {fraction:P0}"), conversion.Token);
            path = output; isGif = true; gif.Visibility = Visibility.Collapsed; duration.Text = duration.Text.Replace("▶", "GIF");
            status.Visibility = Visibility.Collapsed;
        }
        catch (OperationCanceledException) { status.Text = "已取消"; }
        catch (Exception error) { status.Text = "转换失败"; notify($"无法导出 GIF。（0x{error.HResult:X8}）"); }
        finally { conversion.Dispose(); conversion = null; delete.Visibility = tools.Visibility = IsMouseOver ? Visibility.Visible : Visibility.Collapsed; if (IsVisible && !IsMouseOver) dismiss.Start(); finished.TrySetResult(); }
    }
    internal void ExportGif() => Convert();
    private void Recycle()
    {
        if (conversion is not null) { notify("请先取消 GIF 转换再删除录屏。"); return; }
        try { FileSystem.DeleteFile(path, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin); Close(); }
        catch (Exception error) { notify($"无法移到回收站。（0x{error.HResult:X8}）"); }
    }
    internal static bool CopyFile(string path, Action<string> notify)
    {
        try { Clipboard.SetFileDropList(new StringCollection { path }); return true; }
        catch (Exception error) { notify($"无法复制录屏文件。（0x{error.HResult:X8}）"); }
        return false;
    }
#if DEBUG
    internal void DebugHover() { dismiss.Stop(); close.Visibility = delete.Visibility = tools.Visibility = Visibility.Visible; }
    internal async Task<string> DebugConvert()
    {
        Convert(); while (conversion is not null) await Task.Delay(10);
        if (!isGif) throw new InvalidOperationException("缩略图没有切换为 GIF。"); return path;
    }
#endif
}

internal sealed class VideoPreviewWindow : Window
{
    internal string FilePath { get; }
    internal void Resume() { if (WindowState == WindowState.Minimized) SystemCommands.RestoreWindow(this); Activate(); SetPlaying(true); }
#if DEBUG
    private readonly TaskCompletionSource<bool> opened = new();
    internal Task<bool> DebugOpened => opened.Task;
    internal void DebugMute() { media.IsMuted = true; RefreshActions(); }
    internal void DebugPause() => SetPlaying(false);
    internal bool DebugPositionTimer => timer.IsEnabled;
    internal void DebugSeek(double seconds) => seek.Value = seconds;
    internal double DebugPosition => media.Position.TotalSeconds;
    internal bool DebugActionsMatchState => (play.Content as ActionIconView)?.Kind == (playing ? ActionIcon.Pause : ActionIcon.Play) &&
        (volume.Content as ActionIconView)?.Kind == (media.IsMuted ? ActionIcon.Mute : ActionIcon.Volume);
#endif
    private readonly MediaElement media;
    private readonly Button play, volume;
    private readonly Slider seek;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private bool scrubbing, syncingPosition, playing = true;
    public VideoPreviewWindow(string path, Action<string> notify)
    {
        FilePath = Path.GetFullPath(path);
        Title = Path.GetFileName(path); Width = 860; Height = 540; MinWidth = 420; MinHeight = 280;
        WindowStartupLocation = WindowStartupLocation.CenterScreen; FontFamily = Velos.UI.WarmTheme.Text;
        Background = CaptureChrome.Paper;
        media = new MediaElement { Source = new Uri(path), LoadedBehavior = MediaState.Manual, UnloadedBehavior = MediaState.Manual,
            Stretch = Stretch.Uniform, ScrubbingEnabled = true };
        seek = new Slider { Minimum = 0, Maximum = 1, SmallChange = 1, LargeChange = 5, MinWidth = 160, VerticalAlignment = VerticalAlignment.Center, Style = CaptureChrome.SliderStyle };
        seek.Resources["CaptureDivider"] = Velos.UI.WarmTheme.Floating.Divider;
        play = CaptureChrome.IconButton(ActionIcon.Pause, "暂停播放", () => SetPlaying(!playing));
        volume = CaptureChrome.IconButton(ActionIcon.Volume, "静音", () => { media.IsMuted = !media.IsMuted; RefreshActions(); });
        var controls = new DockPanel { Margin = new Thickness(12, 4, 12, 8), LastChildFill = true };
        var left = new StackPanel { Orientation = Orientation.Horizontal, Children = { play,
            volume } };
        var right = new StackPanel { Orientation = Orientation.Horizontal, Children = {
            CaptureChrome.IconButton("\ue8c8", "复制文件", () => RecordingThumbnail.CopyFile(path, notify)),
            CaptureChrome.IconButton("\ue8b7", "显示录屏文件", () => { try { Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true }); } catch { notify("无法打开文件夹。"); } }) } };
        DockPanel.SetDock(left, Dock.Left); DockPanel.SetDock(right, Dock.Right); controls.Children.Add(left); controls.Children.Add(right); controls.Children.Add(seek);
        var root = new DockPanel { Background = CaptureChrome.Paper }; DockPanel.SetDock(controls, Dock.Bottom); root.Children.Add(controls); root.Children.Add(media); Content = root;
        media.MediaOpened += (_, _) =>
        {
            if (media.NaturalDuration.HasTimeSpan) seek.Maximum = media.NaturalDuration.TimeSpan.TotalSeconds;
            var scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
            var origin = PointToScreen(new Point()); var display = Desktop.Displays().FirstOrDefault(d => d.Bounds.Contains((int)origin.X, (int)origin.Y)) ?? Desktop.Displays().First();
            if (media.NaturalVideoWidth > 0 && media.NaturalVideoHeight > 0)
            {
                var aspect = (double)media.NaturalVideoWidth / media.NaturalVideoHeight;
                Width = Math.Min(display.WorkArea.Width / scale * .75, Math.Max(480, media.NaturalVideoWidth / scale));
                Height = Math.Min(display.WorkArea.Height / scale * .75, Width / aspect + 78);
            }
            SetPlaying(playing);
        };
#if DEBUG
        media.MediaOpened += (_, _) => opened.TrySetResult(true);
        media.MediaFailed += (_, _) => opened.TrySetResult(false);
#endif
        media.MediaEnded += (_, _) => { SetPlaying(false); media.Position = TimeSpan.Zero; SyncPosition(); };
        media.MediaFailed += (_, e) => { timer.Stop(); notify($"系统无法播放此录屏，可在文件夹中使用支持该编码的播放器。（0x{e.ErrorException.HResult:X8}）"); };
        seek.ValueChanged += (_, _) => { if (!syncingPosition) media.Position = TimeSpan.FromSeconds(seek.Value); };
        seek.PreviewMouseDown += (_, _) => scrubbing = true;
        seek.PreviewMouseUp += (_, _) => { media.Position = TimeSpan.FromSeconds(seek.Value); scrubbing = false; };
        seek.LostMouseCapture += (_, _) => { if (scrubbing) { media.Position = TimeSpan.FromSeconds(seek.Value); scrubbing = false; } };
        seek.PreviewKeyUp += (_, _) => media.Position = TimeSpan.FromSeconds(seek.Value);
        timer.Tick += (_, _) => { if (!scrubbing) SyncPosition(); };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape || e.Key == Key.W && Keyboard.Modifiers == ModifierKeys.Control) { Close(); e.Handled = true; }
            else if (e.Key == Key.Space && Keyboard.Modifiers == ModifierKeys.None) { if (!e.IsRepeat) SetPlaying(!playing); e.Handled = true; }
        };
        Loaded += (_, _) => media.Play();
        Closed += (_, _) => { timer.Stop(); media.Stop(); media.Close(); media.Source = null; };
    }
    private void SetPlaying(bool value)
    {
        playing = value;
        if (value) { media.Play(); if (media.NaturalDuration.HasTimeSpan) timer.Start(); }
        else { media.Pause(); timer.Stop(); }
        RefreshActions();
    }
    private void SyncPosition()
    {
        syncingPosition = true;
        try { seek.Value = media.Position.TotalSeconds; }
        finally { syncingPosition = false; }
    }
    private void RefreshActions()
    {
        Interaction.SetAction(play, playing ? ActionIcon.Pause : ActionIcon.Play, playing ? "暂停播放" : "播放");
        Interaction.SetAction(volume, media.IsMuted ? ActionIcon.Mute : ActionIcon.Volume, media.IsMuted ? "取消静音" : "静音");
    }
}
