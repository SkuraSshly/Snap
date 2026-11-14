using System.Buffers.Binary;

namespace Velos.Core.Recording;

/// <summary>按 48kHz 时间线混合两路立体声。缺失输入补静音，超出 ±1 的部分削波。</summary>
public sealed class StereoMixer
{
    public const int SampleRate = 48_000;
    private sealed record Chunk(long Start, float[] Samples)
    {
        public long End => Start + Samples.Length / 2;
    }
    private readonly object sync = new();
    private readonly Queue<Chunk>[] sources = [new(), new()];
    private long consumed;

    public void Add(int source, long position, float[] samples)
    {
        lock (sync)
        {
            if (position + samples.Length / 2 <= consumed) return;
            var queue = sources[source];
            queue.Enqueue(new Chunk(position, samples));
            while (queue.Count > 0 && queue.Peek().End < position - SampleRate) queue.Dequeue();
        }
    }

    public byte[] Read(long start, int frames, bool microphoneMuted)
    {
        var mix = new float[frames * 2];
        lock (sync)
        {
            for (var source = 0; source < sources.Length; source++)
            {
                var queue = sources[source];
                foreach (var chunk in queue)
                {
                    if (source == 1 && microphoneMuted) continue;
                    var low = Math.Max(start, chunk.Start);
                    var high = Math.Min(start + frames, chunk.End);
                    for (var position = low; position < high; position++)
                    {
                        var target = checked((int)(position - start) * 2);
                        var offset = checked((int)(position - chunk.Start) * 2);
                        mix[target] += chunk.Samples[offset];
                        mix[target + 1] += chunk.Samples[offset + 1];
                    }
                }
                while (queue.Count > 0 && queue.Peek().End <= start + frames) queue.Dequeue();
            }
            consumed = start + frames;
        }
        var bytes = new byte[frames * 4];
        for (var i = 0; i < mix.Length; i++)
            BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(i * 2), (short)Math.Round(Math.Clamp(mix[i], -1, 1) * 32767));
        return bytes;
    }
}
