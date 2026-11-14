using System.Buffers.Binary;
using System.Runtime.InteropServices;

namespace Velos.Core.LongCapture;

public enum ScrollAxis { Vertical, Horizontal }

/// <summary>按行存放的 BGRA8 像素，允许 GPU 读回时的行尾填充。</summary>
public sealed class ScrollFrame
{
    public ScrollFrame(int width, int height, int stride, byte[] pixels)
    {
        if (width < 1 || height < 1 || stride < checked(width * 4) || pixels.Length < checked(stride * height))
            throw new ArgumentException("长截图帧的尺寸或行距无效。");
        Width = width;
        Height = height;
        Stride = stride;
        Pixels = pixels;
    }

    public int Width { get; }
    public int Height { get; }
    public int Stride { get; }
    public byte[] Pixels { get; }
    public uint At(int x, int y) => BinaryPrimitives.ReadUInt32LittleEndian(Pixels.AsSpan(y * Stride + x * 4, 4));
    internal ReadOnlySpan<uint> Row(int y) => MemoryMarshal.Cast<byte, uint>(Pixels.AsSpan(y * Stride, Width * 4));
}
