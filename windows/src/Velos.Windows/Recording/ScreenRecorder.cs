using System.Diagnostics;
using System.Drawing;
using Velos.Core.Recording;
using Velos.Core.Settings;
using Velos.Windows.Capture;

namespace Velos.Windows.Recording;

public sealed class ScreenRecorder : IAsyncDisposable
{
    private readonly CancellationTokenSource stop = new();
    private readonly RecordingTimeline timeline = new();
    private readonly StereoMixer mixer = new();
    private readonly List<Task> tasks = [];
    private readonly RecordingPreferences options;
    private VideoWriter? writer;
    private readonly object frameSync = new();
    private readonly Action<string> warning;
    private CapturedPixels? latest;
    private bool microphoneMuted;
    private volatile bool stopping;
    private Task? completion;
    private long audioPosition;
    private readonly TaskCompletionSource first = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private CapturedPixels? initialFrame;
    private volatile bool started;
    public TimeSpan Elapsed => timeline.Elapsed(Now);
    public bool IsPaused { get; private set; }
    public VideoCodec ActualCodec => writer?.ActualCodec ?? options.Codec;
    public bool MicrophoneMuted { get => Volatile.Read(ref microphoneMuted); set => Volatile.Write(ref microphoneMuted, value); }
    public static TimeSpan Now => TimeSpan.FromSeconds((double)Stopwatch.GetTimestamp() / Stopwatch.Frequency);

    private ScreenRecorder(RecordingPreferences options, Action<string> warning)
    {
        this.options = options;
        this.warning = warning;
    }

    public static async Task<ScreenRecorder> Start(string path, Display display, Rectangle area, RecordingPreferences options,
        Action<string> warning, Action<Exception> interrupted, CancellationToken cancellation = default)
        => await StartWithCapture(path, new Size(area.Width & ~1, area.Height & ~1), options, warning, interrupted,
            (receive, token) => WindowsCapture.StreamRegion(display,
                new Rectangle(area.X - display.Bounds.X, area.Y - display.Bounds.Y, area.Width & ~1, area.Height & ~1), receive, token, options.ShowCursor), cancellation: cancellation);

#if DEBUG
    public static Task<ScreenRecorder> DebugStartWindow(string path, nint window, Size size, Action<string> warning, Action<Exception> interrupted, bool withAudio = false)
        => StartWithCapture(path, size, new RecordingPreferences { Codec = VideoCodec.H264, FrameRate = 30, SystemAudio = withAudio, Microphone = withAudio }, warning, interrupted,
            (receive, token) => WindowsCapture.DebugStreamWindow(window, new Rectangle(0, 0, size.Width, size.Height), receive, token), false);
    public void DebugAudio(int source, float[] stereo)
    { if (timeline.Adjusted(Now) is { } time) mixer.Add(source, (long)Math.Round(time.TotalSeconds * StereoMixer.SampleRate), stereo); }
#endif

    private static async Task<ScreenRecorder> StartWithCapture(string path, Size input, RecordingPreferences options,
        Action<string> warning, Action<Exception> interrupted, Func<Action<CapturedPixels>, CancellationToken, Task> captureFrames, bool captureAudio = true, CancellationToken cancellation = default)
    {
        var output = RecordingGeometry.OutputSize(input, options.Resolution);
        var recorder = new ScreenRecorder(options, warning);
        using var cancelStartup = cancellation.Register(() => { try { recorder.stop.Cancel(); } catch (ObjectDisposedException) { } });
        try
        {
            cancellation.ThrowIfCancellationRequested();
            var capture = captureFrames(recorder.Receive, recorder.stop.Token);
            recorder.tasks.Add(capture);
            _ = recorder.WatchCapture(capture, interrupted);
            await recorder.first.Task.WaitAsync(TimeSpan.FromSeconds(4), cancellation);
            cancellation.ThrowIfCancellationRequested();
            if (capture.IsCompleted) { await capture; throw new InvalidOperationException("屏幕采集在启动期间已结束。"); }
            recorder.writer = await VideoWriter.Create(path, input, output, options, options.SystemAudio || options.Microphone);
            cancellation.ThrowIfCancellationRequested();
            lock (recorder.frameSync)
            {
                recorder.timeline.Start(Now);
                // 首帧保底覆盖全程静止的画面；初始化写入器期间的其余帧不入队。
                Volatile.Write(ref recorder.latest, Interlocked.Exchange(ref recorder.initialFrame, null));
                recorder.started = true;
            }
            if (capture.IsCompleted) { await capture; throw new InvalidOperationException("屏幕采集在启动期间已结束。"); }
            var video = recorder.PumpVideo();
            recorder.tasks.Add(video);
            _ = recorder.WatchCapture(video, interrupted);
            if (options.SystemAudio || options.Microphone)
            {
                var audio = recorder.PumpAudio();
                recorder.tasks.Add(audio);
                _ = recorder.WatchCapture(audio, interrupted);
            }
            if (captureAudio && options.SystemAudio) recorder.StartAudio(0, true, null);
            if (captureAudio && options.Microphone) recorder.StartAudio(1, false, options.MicrophoneId);
            return recorder;
        }
        catch { await recorder.DisposeAsync(); throw; }
    }

    private void Receive(CapturedPixels pixels)
    {
        if (!first.Task.IsCompleted) { Interlocked.CompareExchange(ref initialFrame, pixels, null); first.TrySetResult(); }
        lock (frameSync)
            if (writer is not null && timeline.Adjusted(Now) is not null) Volatile.Write(ref latest, pixels);
    }

    private async Task WatchCapture(Task capture, Action<Exception> interrupted)
    {
        try { await capture; }
        catch (Exception error)
        {
            first.TrySetException(error);
            if (!stopping && started) interrupted(error);
        }
    }

    private void StartAudio(int source, bool loopback, string? device)
    {
        var task = WasapiCapture.Run(loopback, device, packet =>
        {
            if (timeline.Adjusted(packet.Time) is { } time)
                mixer.Add(source, (long)Math.Round(time.TotalSeconds * StereoMixer.SampleRate), packet.Stereo);
        }, stop.Token);
        tasks.Add(WatchAudio(task, loopback));
    }

    private async Task WatchAudio(Task task, bool loopback)
    {
        try { await task; }
        catch (Exception error)
        {
            if (!stopping) warning($"{(loopback ? "系统声音" : "麦克风")}无法采集，本次该声源按静音处理。（0x{error.HResult:X8}）");
        }
    }

    private async Task PumpVideo()
    {
        var duration = TimeSpan.FromSeconds(1d / (options.FrameRate == 30 ? 30 : 60));
        using var timer = new PeriodicTimer(duration);
        do
        {
            if (timeline.Adjusted(Now) is { } time && Volatile.Read(ref latest) is { } pixels)
                writer!.AddVideo(new(pixels.Bgra, time, duration));
        } while (await timer.WaitForNextTickAsync(stop.Token));
    }

    private async Task PumpAudio()
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMilliseconds(10));
        while (await timer.WaitForNextTickAsync(stop.Token))
        {
            // 为 WASAPI 事件回调和声源之间的抖动保留 100ms，不提前把尚未抵达的声音写成静音。
            var available = (long)(Math.Max(0, Elapsed.TotalSeconds - .1) * StereoMixer.SampleRate);
            while (available - audioPosition >= 1024)
            {
                var duration = TimeSpan.FromSeconds(1024d / StereoMixer.SampleRate);
                await writer!.AddAudio(new(mixer.Read(audioPosition, 1024, MicrophoneMuted), TimeSpan.FromSeconds((double)audioPosition / StereoMixer.SampleRate), duration), stop.Token);
                audioPosition += 1024;
            }
        }
    }

    public void TogglePause()
    {
        if (stopping) return;
        lock (frameSync)
        {
            if (IsPaused) timeline.Resume(Now);
            else timeline.Pause(Now);
            IsPaused = !IsPaused;
        }
    }

    public Task Stop() => completion ??= Finish();

    private async Task Finish()
    {
        stopping = true;
        lock (frameSync) timeline.Pause(Now);
        stop.Cancel();
        foreach (var task in tasks)
        {
            try { await task; }
            catch (OperationCanceledException) { }
            catch (Exception error) { warning($"采集已中断，正在保存已录制部分。（0x{error.HResult:X8}）"); }
        }
        if (latest is { } final)
            writer!.AddVideo(new(final.Bgra, Elapsed, TimeSpan.FromSeconds(1d / (options.FrameRate == 30 ? 30 : 60))));
        if (options.SystemAudio || options.Microphone)
        {
            var end = (long)(Elapsed.TotalSeconds * StereoMixer.SampleRate);
            while (audioPosition < end)
            {
                var count = (int)Math.Min(1024, end - audioPosition);
                await writer!.AddAudio(new(mixer.Read(audioPosition, count, MicrophoneMuted), TimeSpan.FromSeconds((double)audioPosition / StereoMixer.SampleRate),
                    TimeSpan.FromSeconds((double)count / StereoMixer.SampleRate)), CancellationToken.None);
                audioPosition += count;
            }
        }
        if (writer is not null) await writer.Complete();
    }

    public async ValueTask DisposeAsync()
    {
        stopping = true;
        stop.Cancel();
        foreach (var task in tasks)
        {
            try { await task; }
            catch (Exception) when (stop.IsCancellationRequested) { }
        }
        if (writer is not null) await writer.DisposeAsync();
        latest = null;
        initialFrame = null;
        stop.Dispose();
    }
}
