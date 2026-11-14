#if DEBUG
using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;
using Velos.Core.Settings;
using Velos.Core.Recording;
using Velos.Windows.Recording;
using Windows.Media.Editing;
using Windows.Storage;
using PixelSize = System.Drawing.Size;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Velos.Recording;
using Velos.Windows.Capture;
using Velos.Screenshot;
using Velos.UI;
using PixelRect = System.Drawing.Rectangle;

namespace Velos;

public partial class App
{
    private async void RunRecordingSelfTest(string profile, bool idle)
    {
        Directory.CreateDirectory(profile);
        var results = new List<string>();
        var exit = 1;
        try
        {
            var path = Path.Combine(profile, "合成录屏.mp4");
            var size = new PixelSize(320, 180);
            await using (var writer = await VideoWriter.Create(path, size, size,
                new RecordingPreferences { Codec = VideoCodec.H264, FrameRate = 30 }, withAudio: true).WaitAsync(TimeSpan.FromSeconds(15)))
            {
                results.Add("通过  创建 H.264 与 AAC 系统编码管线");
                for (var frame = 0; frame < 30; frame++)
                {
                    var pixels = new byte[size.Width * size.Height * 4];
                    for (var i = 0; i < pixels.Length; i += 4)
                    {
                        var top = i / 4 / size.Width < size.Height / 2;
                        pixels[i] = top ? (byte)30 : (byte)220; pixels[i + 1] = (byte)(40 + frame * 4); pixels[i + 2] = top ? (byte)220 : (byte)30; pixels[i + 3] = 255;
                    }
                    writer.AddVideo(new(pixels, TimeSpan.FromSeconds(frame / 30d), TimeSpan.FromSeconds(1d / 30)));
                    var mixer = new StereoMixer();
                    var tone = new float[1600 * 2];
                    for (var i = 0; i < 1600; i++) tone[i * 2] = tone[i * 2 + 1] = (float)(Math.Sin((frame * 1600 + i) * 440 * Math.Tau / 48000) * 0.2);
                    mixer.Add(0, frame * 1600, tone);
                    await writer.AddAudio(new(mixer.Read(frame * 1600, 1600, false), TimeSpan.FromSeconds(frame / 30d), TimeSpan.FromSeconds(1d / 30)), CancellationToken.None);
                    await Task.Delay(34);
                }
                await writer.Complete();
            }
            var clip = await MediaClip.CreateFromFileAsync(await StorageFile.GetFileFromPathAsync(path));
            var video = clip.GetVideoEncodingProperties();
            if (video.Width != 320 || video.Height != 180 || clip.OriginalDuration.TotalSeconds < 0.9)
                throw new InvalidOperationException("合成视频尺寸或时长不正确。");
            results.Add($"通过  合成 MP4 可解码，{video.Width}×{video.Height}，{clip.OriginalDuration.TotalSeconds:0.000} 秒");
            await Task.Run(() =>
            {
                using var reader = new VideoReader(path); var first = reader.Read()!.Value.Pixels;
                var top = (20 * first.Width + 20) * 4; var bottom = (150 * first.Width + 20) * 4;
                if (first.Bgra[top + 2] < 180 || first.Bgra[top] > 80 || first.Bgra[bottom] < 180 || first.Bgra[bottom + 2] > 80)
                    throw new InvalidOperationException("视频方向或红蓝通道不正确。");
            });
            results.Add("通过  MP4 上下方向、RGB 通道与输入原生像素一致");
            var gif = await GifExporter.Export(path, 15, 160, null, CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(15));
            using (var stream = File.OpenRead(gif))
            {
                var decoder = new GifBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                if (decoder.Frames.Count < 2 || decoder.Frames[0].PixelWidth != 160 || decoder.Frames[0].PixelHeight != 90)
                    throw new InvalidOperationException("GIF 画面或尺寸不正确。");
                results.Add($"通过  顺序解码并导出 GIF，160×90，{decoder.Frames.Count} 帧");
            }
            await VerifyGifBoundaries(path, gif, profile, results);
            var devices = await WasapiCapture.Microphones();
            results.Add($"通过  枚举麦克风设备（{devices.Count}）");
            await WasapiCapture.DebugValidate(true);
            results.Add("通过  WASAPI 系统声音接口与 48kHz 立体声格式预检（未启动声音采集）");
            if (devices.Count > 0) { await WasapiCapture.DebugValidate(false); results.Add("通过  WASAPI 麦克风接口与 48kHz 立体声格式预检（未启动声音采集）"); }
            var complexGif = Path.Combine(profile, "合成复杂调色板.gif");
            var random = new Random(37); var raster = new uint[256 * 128];
            var palette = new uint[] { 0xff000000, 0xff0000ff, 0xff00ff00, 0xffff0000, 0xffffff00, 0xffff00ff, 0xff00ffff, 0xffffffff };
            for (var i = 0; i < raster.Length; i++) raster[i] = palette[random.Next(palette.Length)];
            using (var encoder = new GifEncoder(complexGif, 256, 128)) { encoder.Add(raster, 0); encoder.Finish(.2); }
            using (var stream = File.OpenRead(complexGif))
            {
                var decoder = new GifBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                var pixels = new FormatConvertedBitmap(decoder.Frames[0], PixelFormats.Bgra32, null, 0);
                var decoded = new uint[raster.Length]; pixels.CopyPixels(decoded, 256 * 4, 0);
                if (!decoded.SequenceEqual(raster)) throw new InvalidOperationException("GIF LZW 字典扩宽或重置错误。");
            }
            results.Add("通过  复杂调色板 GIF 可由系统逐像素解码，覆盖 LZW 字典扩宽与重置");
            var hevcPath = Path.Combine(profile, "合成HEVC缩放.mp4");
            await using (var encoder = await VideoWriter.Create(hevcPath, size, new PixelSize(160, 90), new RecordingPreferences { Codec = VideoCodec.Hevc, FrameRate = 30 }, false))
            {
                for (var f = 0; f < 6; f++) { encoder.AddVideo(new(new byte[320 * 180 * 4], TimeSpan.FromSeconds(f / 30d), TimeSpan.FromSeconds(1d / 30))); await Task.Delay(35); }
                await encoder.Complete(); results.Add("通过  HEVC 首选／H.264 回退管线，实际编码 " + encoder.ActualCodec);
            }
            await Task.Run(() => { using var reader = new VideoReader(hevcPath); if (reader.Width != 160 || reader.Height != 90) throw new InvalidOperationException($"视频缩放尺寸错误：{reader.Width}×{reader.Height}。"); });
            results.Add("通过  明确缩放后编码 320×180 → 160×90，文件实际尺寸一致");
            await TestRecordingEngine(profile, results);
            await TestRecordingUI(profile, path, results);
            exit = 0;
        }
        catch (Exception error) { results.Add("失败  " + error); }
        finally
        {
            foreach (var window in Windows.Cast<Window>().ToArray()) window.Close();
            File.WriteAllLines(Path.Combine(profile, "结果.txt"), results);
            if (idle && exit == 0) { File.WriteAllText(Path.Combine(profile, "空闲就绪.txt"), ""); await Task.Delay(TimeSpan.FromSeconds(38)); }
            Shutdown(exit);
        }
    }

    private static async Task VerifyGifBoundaries(string video, string gif, string profile, List<string> results)
    {
        var original = await File.ReadAllBytesAsync(gif);
        var duplicate = await GifExporter.Export(video, 10, 160, null, CancellationToken.None);
        if (duplicate == gif || !File.Exists(duplicate) || !(await File.ReadAllBytesAsync(gif)).SequenceEqual(original))
            throw new InvalidOperationException("同名 GIF 被覆盖。");
        results.Add("通过  [G01] 同名 GIF 自动另存，原有 GIF 字节保持不变");
        foreach (var at in new[] { .25, 1d })
        {
            var existing = Directory.GetFiles(profile).Order().ToArray();
            using var cancel = new CancellationTokenSource();
            try
            {
                await GifExporter.Export(video, 15, 160, new InlineGifProgress(value => { if (value >= at) cancel.Cancel(); }), cancel.Token);
                throw new InvalidOperationException("GIF 取消仍返回了输出文件。");
            }
            catch (OperationCanceledException) when (cancel.IsCancellationRequested) { }
            if (!Directory.GetFiles(profile).Order().SequenceEqual(existing)) throw new InvalidOperationException("GIF 取消残留文件。");
            results.Add(at < 1 ? "通过  [G02] GIF 转换中取消不生成成品、不残留 partial 文件" : "通过  [G03] 最后一帧处理后取消也不发布 GIF 成品");
        }
    }
    private sealed class InlineGifProgress(Action<double> report) : IProgress<double>
    {
        public void Report(double value) => report(value);
    }

    private async Task TestRecordingEngine(string profile, List<string> results)
    {
        var grid = new Grid(); grid.RowDefinitions.Add(new RowDefinition()); grid.RowDefinitions.Add(new RowDefinition());
        var top = new Border { Background = Brushes.Coral }; var bottom = new Border { Background = Brushes.CornflowerBlue };
        grid.Children.Add(top); grid.Children.Add(bottom); Grid.SetRow(bottom, 1);
        var fixture = new Window { WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false, Topmost = true,
            Content = grid, Width = 320, Height = 180, Left = 30, Top = 30, Title = "Velos 录屏合成窗口" };
        try
        {
            var hwnd = new WindowInteropHelper(fixture).EnsureHandle(); fixture.Show();
            HwndSource.FromHwnd(hwnd)!.CompositionTarget!.RenderMode = RenderMode.SoftwareOnly;
            Desktop.Position(hwnd, new PixelRect(40, 40, 320, 180)); fixture.UpdateLayout();
            await SettleUI(); await Task.Delay(200);
            var failures = new List<string>();
            var path = Path.Combine(profile, "合成采集与暂停.mp4");
            await using var recorder = await ScreenRecorder.DebugStartWindow(path, hwnd, new PixelSize(320, 180), failures.Add,
                error => failures.Add(error.Message), withAudio: true);
            var tone = new float[480 * 2]; for (var i = 0; i < 480; i++) tone[i * 2] = tone[i * 2 + 1] = (float)(.1 * Math.Sin(i * 440 * Math.Tau / 48000));
            var audio = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(10) };
            audio.Tick += (_, _) => { recorder.DebugAudio(0, tone); recorder.DebugAudio(1, tone); }; audio.Start();
            try
            {
            await Task.Delay(500); recorder.TogglePause(); var pausedAt = recorder.Elapsed; await Task.Delay(450);
            if (Math.Abs((recorder.Elapsed - pausedAt).TotalMilliseconds) > 5) throw new InvalidOperationException("暂停期间计时未冻结。");
            recorder.TogglePause(); top.Background = Brushes.Gold; await Task.Delay(500); await recorder.Stop();
            }
            finally { audio.Stop(); }
            await Task.Run(() => { using var reader = new VideoReader(path);
                if (reader.Width != 320 || reader.Height != 180 || reader.Duration.TotalSeconds is < .85 or > 1.35)
                    throw new InvalidOperationException("暂停录制时长或原生尺寸不正确：" + reader.Duration); });
            if (failures.Count != 0) throw new InvalidOperationException(string.Join("；", failures));
            var clip = await MediaClip.CreateFromFileAsync(await StorageFile.GetFileFromPathAsync(path)); var properties = clip.EmbeddedAudioTracks.Single().GetAudioEncodingProperties();
            if (properties.ChannelCount != 2 || properties.SampleRate != 48000) throw new InvalidOperationException("混音音轨格式错误。");
            results.Add("通过  WGC 合成窗口、双声源注入、暂停扣时、音频尾部收齐与 MP4 收尾，原生 320×180、48kHz 立体声");
        }
        finally { fixture.Close(); }
    }
    private async Task TestRecordingUI(string profile, string video, List<string> results)
    {
        var monitor = Desktop.Displays().First();
        var bounds = new PixelRect(monitor.WorkArea.X + 20, monitor.WorkArea.Y + 20, Math.Min(1280, monitor.WorkArea.Width - 40), Math.Min(800, monitor.WorkArea.Height - 40));
        var display = new Display(monitor.Handle, bounds, bounds); var area = new PixelRect(bounds.X + 160, bounds.Y + 140, 640, 420);
        foreach (var dark in new[] { false, true })
        {
            WarmTheme.DebugSetDark(dark); var suffix = dark ? "深色" : "浅色";
            OpenSettings(); ((RadioButton)settingsWindow!.FindName("RecordingTab")).IsChecked = true;
            await SettleUI();
            WriteSettingsImage(settingsWindow, Path.Combine(profile, "录屏设置-" + suffix + ".png"));
            ((ScrollViewer)settingsWindow.FindName("PageScroll")).ScrollToBottom();
            await SettleUI();
            WriteSettingsImage(settingsWindow, Path.Combine(profile, "录屏设置底部-" + suffix + ".png")); settingsWindow.Close();
            var options = new RecordingPreferences();
            var selector = new RecordingSelectionWindow(display, [], () => options, p => options = p, _ => { }, () => { });
            selector.ShowOnDisplay(); selector.Surface.DebugDrag(new System.Drawing.Point(160, 140), new System.Drawing.Point(800, 560));
            var scale = VisualTreeHelper.GetDpi(selector).DpiScaleX;
            await SettleUI();
            await Task.Delay(100);
            var inside = selector.PointToScreen(new Point(400 / scale, 330 / scale));
            if (DebugWindowAt(new((int)inside.X, (int)inside.Y)) != new WindowInteropHelper(selector).Handle)
                throw new InvalidOperationException("录屏选区内部点击穿透到下层窗口。");
            var selectedArea = selector.Surface.Region;
            selector.Surface.DebugDrag(new System.Drawing.Point(400, 330), new System.Drawing.Point(430, 350));
            if (selector.Surface.Region?.X != selectedArea?.X + 30 || selector.Surface.Region?.Y != selectedArea?.Y + 20)
                throw new InvalidOperationException("录屏选区内部无法拖动区域。");
            results.Add("通过  " + suffix + "录屏透明选区原生命中测试与内部拖动");
            WriteRecordingComposite(display, [selector], Path.Combine(profile, "录屏选区-" + suffix + ".png"));
            selector.Close();
            var frame = new RecordingFrameWindow(display, area, scale);
            var pauseClicks = 0;
            using (var bar = new RecordingControlBar(display, area, scale, true, () => TimeSpan.FromSeconds(90), () => pauseClicks++, () => { }, () => { }))
            {
                await Task.Delay(300);
                if (!Desktop.DebugIsExcluded(new WindowInteropHelper(bar.Window).Handle)) throw new InvalidOperationException("录屏控制条未排除。");
                WriteRecordingComposite(display, [frame, bar.Window], Path.Combine(profile, "录屏中-" + suffix + ".png"));
                frame.SetPaused(true); bar.Refresh(true, true);
                bar.Window.UpdateLayout();
                bar.DebugPauseClick();
                if (pauseClicks != 1 || !bar.DebugButtonIsGuarded || bar.DebugPauseName != "继续录制" || bar.DebugMicrophoneIcon != ActionIcon.MicrophoneOff)
                    throw new InvalidOperationException($"录屏按钮状态错误：点击={pauseClicks}，拖动保护={bar.DebugButtonIsGuarded}，名称={bar.DebugPauseName}，静音图标={bar.DebugMicrophoneIcon}。");
                WriteRecordingComposite(display, [frame, bar.Window], Path.Combine(profile, "录屏暂停-" + suffix + ".png"));
            }
            frame.Close(); var countdown = new RecordingCountdownWindow(area, scale);
            await SettleUI();
            WriteRecordingComposite(display, [countdown], Path.Combine(profile, "录屏倒计时-" + suffix + ".png")); countdown.Finish(false);
            if (await countdown.Completion) throw new InvalidOperationException("倒计时取消失败。");
            var thumbnail = new RecordingThumbnail(video, display, scale, () => options, _ => { }, _ => { });
            await Task.Delay(300); thumbnail.DebugHover(); WriteRecordingComposite(display, [thumbnail], Path.Combine(profile, "录屏缩略图-" + suffix + ".png"));
            var shotAsset = new ShotImage(ShotEncoding.Encode(SyntheticImage(240, 135)), 240, 135, scale, area, display);
            var shotThumb = new ShotThumbnail(shotAsset, () => { }, () => { }, () => { }, () => { });
            shotThumb.Place(new PixelRect(0, 0, (int)(shotThumb.Width * scale), (int)(shotThumb.Height * scale)));
            await Task.Delay(280);
            var recordingHandle = new WindowInteropHelper(thumbnail).Handle; var shotHandle = new WindowInteropHelper(shotThumb).Handle;
            if (!Desktop.DebugIsExcluded(recordingHandle) || !Desktop.DebugIsExcluded(shotHandle)) throw new InvalidOperationException("缩略图未统一从截图排除。");
            Desktop.SetRecordingActive(true);
            if (Desktop.DebugIsExcluded(recordingHandle) || Desktop.DebugIsExcluded(shotHandle)) throw new InvalidOperationException("录制中缩略图未恢复可见。");
            Desktop.SetRecordingActive(false);
            results.Add("通过  Mac 语义：两种缩略图统一截图排除、录制时可见");
            var shotOrigin = shotThumb.PointToScreen(new Point()); var videoOrigin = thumbnail.PointToScreen(new Point());
            if (videoOrigin.Y + thumbnail.ActualHeight * scale >= shotOrigin.Y || ThumbnailShelf.DebugMoving || ThumbnailShelf.DebugCount != 2)
                throw new InvalidOperationException("截图与录屏缩略图重叠，或重排动画没有停止。");
            WriteRecordingComposite(display, [thumbnail, shotThumb], Path.Combine(profile, "混合缩略图-" + suffix + ".png"));
            shotThumb.Close(); await Task.Delay(280);
            if (ThumbnailShelf.DebugCount != 1 || ThumbnailShelf.DebugMoving) throw new InvalidOperationException("移除缩略图后重排没有释放。");
            var stack = new List<ShotThumbnail>();
            for (var i = 0; i < 6; i++) { var entry = new ShotThumbnail(shotAsset, () => { }, () => { }, () => { }, () => { }); stack.Add(entry); entry.Place(new PixelRect(0, 0, (int)(entry.Width * scale), (int)(entry.Height * scale))); }
            if (ThumbnailShelf.DebugCount != 7 || stack.Any(t => t.IsClosed)) throw new InvalidOperationException("连续截图错误地使用固定四张上限。");
            foreach (var entry in stack) entry.Close(); await Task.Delay(260);
            results.Add("通过  Mac 语义：连续缩略图按时限堆叠，不因固定数量取消或关闭");
            results.Add("通过  " + suffix + "截图和录屏缩略图共用排列，进出与重排结束后无动画计时器");
            var exported = await thumbnail.DebugConvert().WaitAsync(TimeSpan.FromSeconds(10));
            if (!File.Exists(exported) || !exported.EndsWith(".gif")) throw new InvalidOperationException("缩略图 GIF 导出失败。");
            thumbnail.DebugHover(); WriteRecordingComposite(display, [thumbnail], Path.Combine(profile, "GIF缩略图-" + suffix + ".png")); thumbnail.Close();
            var playbackFailures = new List<string>(); var preview = new VideoPreviewWindow(video, playbackFailures.Add); preview.DebugMute(); preview.Show();
            if (!await preview.DebugOpened.WaitAsync(TimeSpan.FromSeconds(8))) throw new InvalidOperationException("系统视频预览未打开：" + string.Join("；", playbackFailures));
            preview.DebugPause(); if (!preview.DebugActionsMatchState) throw new InvalidOperationException("播放器暂停／静音图标未随实际状态更新。");
            if (preview.DebugPositionTimer) throw new InvalidOperationException("暂停后播放器仍在轮询进度。");
            results.Add("通过  [V01] 暂停视频后停止进度轮询");
            preview.DebugSeek(.45);
            await WaitFor(() => Math.Abs(preview.DebugPosition - .45) < .15, "视频进度拉条实际寻址");
            results.Add("通过  [V02] 不按鼠标／键盘也能通过滚轮更新的拉条值实际寻址");
            await Task.Delay(200); WriteTranslationImage(preview, Path.Combine(profile, "录屏视频预览-" + suffix + ".png")); preview.Close();
            results.Add("通过  " + suffix + "录屏设置、选区、控制条、暂停、倒计时、视频／GIF 缩略图、系统预览及排除状态");
        }
        WarmTheme.Refresh();
    }
    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "WindowFromPoint")]
    private static extern nint DebugWindowAt(System.Drawing.Point point);
    private static void WriteRecordingComposite(Display display, IEnumerable<Window> windows, string path)
    {
        var drawing = new DrawingVisual();
        using (var context = drawing.RenderOpen())
        {
            context.DrawImage(SyntheticImage(display.Bounds.Width, display.Bounds.Height), new Rect(0, 0, display.Bounds.Width, display.Bounds.Height));
            foreach (var window in windows.Where(w => w.IsVisible))
            {
                var content = (FrameworkElement)window.Content; content.UpdateLayout();
                var origin = content.PointToScreen(new Point()); var dpi = VisualTreeHelper.GetDpi(content);
                var rect = new Rect(origin.X - display.Bounds.X, origin.Y - display.Bounds.Y, content.ActualWidth * dpi.DpiScaleX, content.ActualHeight * dpi.DpiScaleY);
                var bitmap = new RenderTargetBitmap(Math.Max(1, (int)Math.Ceiling(rect.Width)), Math.Max(1, (int)Math.Ceiling(rect.Height)), dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
                var snapshot = new DrawingVisual(); using (var dc = snapshot.RenderOpen()) dc.DrawRectangle(new VisualBrush(content), null, new Rect(0, 0, content.ActualWidth, content.ActualHeight));
                bitmap.Render(snapshot); context.DrawImage(bitmap, rect);
            }
        }
        var output = new RenderTargetBitmap(display.Bounds.Width, display.Bounds.Height, 96, 96, PixelFormats.Pbgra32); output.Render(drawing);
        File.WriteAllBytes(path, ShotEncoding.Encode(output));
    }
}
#endif



