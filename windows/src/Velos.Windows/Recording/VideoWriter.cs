using System.Drawing;
using System.Threading.Channels;
using Velos.Core.Settings;
using Velos.Core.Recording;

namespace Velos.Windows.Recording;

public sealed record MediaPacket(byte[] Bytes, TimeSpan Time, TimeSpan Duration);

/// <summary>专用 MTA 线程上的 Media Foundation Sink Writer。待编码队列有界。</summary>
public sealed class VideoWriter : IAsyncDisposable
{
    private readonly Channel<(bool Video, MediaPacket Packet)> queue = Channel.CreateBounded<(bool, MediaPacket)>(new BoundedChannelOptions(4)
        { FullMode = BoundedChannelFullMode.Wait, SingleReader = true, SingleWriter = false });
    private readonly CancellationTokenSource stop = new();
    private Task worker = Task.CompletedTask;
    public VideoCodec ActualCodec { get; private set; }

    private VideoWriter() { }

    public static async Task<VideoWriter> Create(string path, Size input, Size output, RecordingPreferences options, bool withAudio)
    {
        var instance = new VideoWriter();
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        instance.worker = Task.Factory.StartNew(() =>
        {
            try
            {
                var scaler = new VideoScaler(input, output);
                using var writer = new FoundationWriter(path, output, output, options, withAudio);
                instance.ActualCodec = writer.ActualCodec;
                ready.TrySetResult();
                while (instance.queue.Reader.WaitToReadAsync(instance.stop.Token).AsTask().GetAwaiter().GetResult())
                    while (instance.queue.Reader.TryRead(out var frame))
                        writer.Write(frame.Video, frame.Video ? frame.Packet with { Bytes = scaler.Scale(frame.Packet.Bytes) } : frame.Packet);
                writer.Complete();
            }
            catch (Exception error)
            {
                ready.TrySetException(error);
                instance.queue.Writer.TryComplete(error);
                throw;
            }
        }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        try { await ready.Task; return instance; }
        catch { await instance.DisposeAsync(); throw; }
    }

    public void AddVideo(MediaPacket packet)
    {
        if (worker.IsFaulted) worker.GetAwaiter().GetResult();
        queue.Writer.TryWrite((true, packet));
    }

    public ValueTask AddAudio(MediaPacket packet, CancellationToken cancellation) => queue.Writer.WriteAsync((false, packet), cancellation);

    public async Task Complete()
    {
        queue.Writer.TryComplete();
        await worker.WaitAsync(TimeSpan.FromSeconds(30));
    }

    public async ValueTask DisposeAsync()
    {
        queue.Writer.TryComplete();
        stop.Cancel();
        try { await worker; }
        catch (Exception) when (stop.IsCancellationRequested) { }
        stop.Dispose();
    }
}
