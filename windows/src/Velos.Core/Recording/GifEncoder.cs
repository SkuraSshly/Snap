using System.Buffers.Binary;

namespace Velos.Core.Recording;

/// <summary>移植自 GIFEncoder.swift。流式 GIF89a，逐帧局部调色板、差分矩形、透明像素和延时回填。</summary>
public sealed class GifEncoder : IDisposable
{
    private readonly FileStream stream;
    private readonly uint[] reference;
    private readonly int width;
    private readonly int height;
    private long? delayOffset;
    private double lastTime;
    private bool finished;
    public int FramesWritten { get; private set; }

    public GifEncoder(string path, int width, int height)
    {
        if (width is < 1 or > 65535 || height is < 1 or > 65535) throw new ArgumentOutOfRangeException(nameof(width));
        this.width = width;
        this.height = height;
        reference = new uint[checked(width * height)];
        stream = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
        stream.Write("GIF89a"u8);
        Write16(width);
        Write16(height);
        stream.Write([0x70, 0, 0, 0x21, 0xff, 0x0b]);
        stream.Write("NETSCAPE2.0"u8);
        stream.Write([3, 1, 0, 0, 0]);
    }

    public void Add(ReadOnlySpan<uint> bgra, double time)
    {
        ObjectDisposedException.ThrowIf(finished, this);
        if (bgra.Length != reference.Length || !double.IsFinite(time) || time < lastTime) throw new ArgumentException("GIF 帧尺寸或时间无效。");
        var pixels = new uint[bgra.Length];
        var minX = width;
        var minY = height;
        var maxX = -1;
        var maxY = -1;
        for (var y = 0; y < height; y++)
        for (var x = 0; x < width; x++)
        {
            var index = y * width + x;
            var pixel = bgra[index];
            pixels[index] = ((pixel >> 16) & 255) | (pixel & 0xff00) | ((pixel & 255) << 16);
            if (FramesWritten > 0 && !Differs(pixels[index], reference[index])) continue;
            minX = Math.Min(minX, x);
            minY = Math.Min(minY, y);
            maxX = Math.Max(maxX, x);
            maxY = Math.Max(maxY, y);
        }
        if (maxX < 0) return;
        var rect = new System.Drawing.Rectangle(minX, minY, maxX - minX + 1, maxY - minY + 1);
        var changed = new bool[rect.Width * rect.Height];
        for (var y = 0; y < rect.Height; y++)
        for (var x = 0; x < rect.Width; x++)
        {
            var at = (rect.Y + y) * width + rect.X + x;
            changed[y * rect.Width + x] = FramesWritten == 0 || Differs(pixels[at], reference[at]);
        }
        var (palette, indices) = GifQuantizer.Quantize(pixels, width, rect, changed);
        PatchDelay(time);
        lastTime = time;
        stream.Write([0x21, 0xf9, 4, (byte)(FramesWritten == 0 ? 4 : 5)]);
        delayOffset = stream.Position;
        stream.Write([0, 0, (byte)(FramesWritten == 0 ? 0 : 255), 0, 0x2c]);
        Write16(rect.X);
        Write16(rect.Y);
        Write16(rect.Width);
        Write16(rect.Height);
        stream.WriteByte(0x87);
        for (var i = 0; i < 256; i++)
        {
            var color = i < palette.Length ? palette[i] : 0;
            stream.Write([(byte)color, (byte)(color >> 8), (byte)(color >> 16)]);
        }
        stream.Write(GifLzw.Encode(indices));
        for (var y = 0; y < rect.Height; y++)
        for (var x = 0; x < rect.Width; x++)
        {
            if (!changed[y * rect.Width + x]) continue;
            var at = (rect.Y + y) * width + rect.X + x;
            reference[at] = pixels[at];
        }
        FramesWritten++;
    }

    public void Finish(double endTime)
    {
        if (finished) return;
        if (FramesWritten == 0) throw new InvalidOperationException("没有可导出的 GIF 画面。");
        PatchDelay(endTime);
        stream.WriteByte(0x3b);
        stream.Flush(true);
        stream.Dispose();
        finished = true;
    }

    private void PatchDelay(double until)
    {
        if (delayOffset is not { } offset) return;
        var end = stream.Position;
        stream.Position = offset;
        var delay = Math.Round(until * 100, MidpointRounding.AwayFromZero) - Math.Round(lastTime * 100, MidpointRounding.AwayFromZero);
        Write16((int)Math.Clamp(delay, 2, 65535));
        stream.Position = end;
        delayOffset = null;
    }

    private void Write16(int value)
    {
        Span<byte> bytes = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16LittleEndian(bytes, (ushort)value);
        stream.Write(bytes);
    }

    private static bool Differs(uint a, uint b) => Math.Abs((int)(a & 255) - (int)(b & 255)) > 3 ||
        Math.Abs((int)((a >> 8) & 255) - (int)((b >> 8) & 255)) > 3 ||
        Math.Abs((int)((a >> 16) & 255) - (int)((b >> 16) & 255)) > 3;

    public void Dispose() { finished = true; stream.Dispose(); }
}
