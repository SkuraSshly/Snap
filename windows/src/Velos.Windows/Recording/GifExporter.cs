using System.Runtime.InteropServices;
using Microsoft.VisualBasic.FileIO;
using Velos.Core.Recording;

namespace Velos.Windows.Recording;

public static class GifExporter
{
    public static Task<string> Export(string video, int fps, int maxWidth, IProgress<double>? progress, CancellationToken cancellation) => Task.Run(() =>
    {
        if (fps is not (10 or 15 or 20)) fps = 15;
        using var reader = new VideoReader(video, maxWidth);
        var directory = Path.GetDirectoryName(video)!;
        var temporary = Path.Combine(directory, ".Velos-" + Guid.NewGuid().ToString("N") + ".gif.partial");
        try
        {
            using (var encoder = new GifEncoder(temporary, reader.Width, reader.Height))
            {
                var duration = reader.Duration.TotalSeconds;
                var frameCount = Math.Max(1, (int)Math.Ceiling(duration * fps));
                byte[]? held = null, drawn = null;
                var index = 0;
                void Emit(double until)
                {
                    while (index < frameCount && (double)index / fps < until)
                    {
                        cancellation.ThrowIfCancellationRequested();
                        if (held is not null && !ReferenceEquals(held, drawn))
                        {
                            encoder.Add(MemoryMarshal.Cast<byte, uint>(held), (double)index / fps);
                            drawn = held;
                        }
                        index++;
                        progress?.Report((double)index / frameCount);
                    }
                }
                while (reader.Read() is { } sample)
                {
                    cancellation.ThrowIfCancellationRequested();
                    if (held is not null) Emit(sample.Time.TotalSeconds);
                    held = sample.Pixels.Bgra;
                }
                Emit(double.PositiveInfinity);
                cancellation.ThrowIfCancellationRequested();
                encoder.Finish(duration);
            }
            cancellation.ThrowIfCancellationRequested();
            var stem = Path.GetFileNameWithoutExtension(video);
            for (var index = 1; ; index++)
            {
                var output = Path.Combine(directory, stem + (index == 1 ? "" : $" {index}") + ".gif");
                try { File.Move(temporary, output); return output; }
                catch (IOException) when (File.Exists(output)) { }
            }
        }
        finally
        {
            if (File.Exists(temporary)) FileSystem.DeleteFile(temporary, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin);
        }
    }, cancellation);
}
