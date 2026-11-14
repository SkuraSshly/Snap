using System.Diagnostics;
using System.Threading.Channels;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velos.Core.LongCapture;
using Velos.Windows.Capture;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.LongCapture;

// 对应 Mac LongCaptureEngine：采集的生命周期和拼接只在这里管理。
// WGC 回调交接一帧后等待串行队列处理，系统帧池负责丢弃过时帧，不积压原尺寸位图。
internal sealed class LongCaptureEngine : IAsyncDisposable
{
    internal sealed record Update(ScrollStitcher.EventKind Event, int Length, BitmapSource? Preview, int? Motion, bool Limited);
    public Action<Update>? OnUpdate { get; set; }
    public Action<Exception>? OnError { get; set; }
    private readonly Channel<Action> commands = Channel.CreateUnbounded<Action>(new() { SingleReader = true, AllowSynchronousContinuations = false });
    private readonly CancellationTokenSource stop = new();
    private readonly Task processor;
    private readonly double scale;
    private ScrollStitcher stitcher;
    private Task capture = Task.CompletedTask;
    private bool started, disposed;
    private volatile bool stopped;
    private int width, height;
    private bool previewDirty, flushScheduled;
    private long lastPreview;

    public LongCaptureEngine(double scale)
    {
        this.scale = scale; stitcher = NewStitcher();
        processor = Task.Run(async () => { await foreach (var command in commands.Reader.ReadAllAsync()) command(); });
    }
    private ScrollStitcher NewStitcher() => new(ScrollAxis.Vertical, edgeMargin: ((int)Math.Round(4 * scale), (int)Math.Round(18 * scale)));
    private Task<T> Enqueue<T>(Func<T> command)
    {
        var result = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!commands.Writer.TryWrite(() => { try { result.SetResult(command()); } catch (Exception error) { result.SetException(error); } }))
            result.SetException(new ObjectDisposedException(nameof(LongCaptureEngine)));
        return result.Task;
    }
    public void Start(Display display, PixelRect area)
    {
        if (started || stopped) return;
        started = true;
        var crop = new PixelRect(area.X - display.Bounds.X, area.Y - display.Bounds.Y, area.Width, area.Height);
        capture = WindowsCapture.StreamRegion(display, crop, Receive, stop.Token, includeCursor: false);
        _ = ObserveCapture(capture);
    }
    private async Task ObserveCapture(Task active)
    {
        try { await active.ConfigureAwait(false); }
        catch (OperationCanceledException) when (stopped) { }
        catch (Exception error) { if (!stopped) OnError?.Invoke(error); }
    }
    private void Receive(CapturedPixels pixels)
    {
        if (stopped) return;
        Enqueue(() => { if (!stopped) Process(new ScrollFrame(pixels.Width, pixels.Height, pixels.Width * 4, pixels.Bgra)); return 0; }).GetAwaiter().GetResult();
    }
    private void Process(ScrollFrame frame)
    {
        var result = stitcher.Add(frame);
        if (result.Kind != ScrollStitcher.EventKind.Lost) previewDirty = true;
        Send(result.Kind, stitcher.LastShift, result.Kind == ScrollStitcher.EventKind.Started);
    }
    private void Send(ScrollStitcher.EventKind kind, int? motion = null, bool force = false)
    {
        BitmapSource? image = null;
        var now = Stopwatch.GetTimestamp();
        if (previewDirty && width > 0 && height > 0)
        {
            if (force || now - lastPreview >= Stopwatch.Frequency / 30)
            {
                image = stitcher.PreviewSized(width, height) is { } frame ? Bitmap(frame) : null;
                previewDirty = false; lastPreview = now;
            }
            else ScheduleFlush();
        }
        OnUpdate?.Invoke(new(kind, stitcher.Length, image, motion, stitcher.ReachedLimit));
    }
    private void ScheduleFlush()
    {
        if (flushScheduled || stopped) return;
        flushScheduled = true; _ = FlushLater();
    }
    private async Task FlushLater()
    {
        try
        {
            await Task.Delay(40, stop.Token).ConfigureAwait(false);
            await Enqueue(() => { flushScheduled = false; if (!stopped && previewDirty) Send(ScrollStitcher.EventKind.Unchanged); return 0; }).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (Exception error) { if (!stopped) OnError?.Invoke(error); }
    }
    public void SetPreviewSize(int pixelWidth, int pixelHeight)
    {
        if (stopped || disposed) return;
        commands.Writer.TryWrite(() => {
            if (width == pixelWidth && height == pixelHeight) return;
            width = pixelWidth; height = pixelHeight; previewDirty = true;
            if (width > 0 && height > 0) ScheduleFlush();
        });
    }
    public async Task StopAsync()
    {
        if (disposed) return;
        stopped = true; stop.Cancel();
        try { await capture.ConfigureAwait(false); }
        catch (Exception) { /* 中断时保留已拼接的像素，仍可生成图像。 */ }
        await Enqueue(() => 0).ConfigureAwait(false);
    }
    public Task<BitmapSource?> MakeImageAsync() => Enqueue(() => stitcher.MakeImage() is { } frame ? Bitmap(frame) : null);
    public async ValueTask DisposeAsync()
    {
        if (disposed) return;
        await StopAsync().ConfigureAwait(false); disposed = true;
        OnUpdate = null; OnError = null;
        await Enqueue(() => { stitcher = NewStitcher(); return 0; }).ConfigureAwait(false);
        commands.Writer.TryComplete(); await processor.ConfigureAwait(false); stop.Dispose();
    }
    private static BitmapSource Bitmap(ScrollFrame frame)
    {
        var image = BitmapSource.Create(frame.Width, frame.Height, 96, 96, PixelFormats.Bgr32, null, frame.Pixels, frame.Stride);
        image.Freeze(); return image;
    }
#if DEBUG
    public void DebugFeed(ScrollFrame frame) => Enqueue(() => { Process(frame); return 0; }).GetAwaiter().GetResult();
    public void DebugCaptureWindow(nint window, PixelRect region)
    { started = true; capture = WindowsCapture.DebugStreamWindow(window, region, Receive, stop.Token); _ = ObserveCapture(capture); }
#endif
}
