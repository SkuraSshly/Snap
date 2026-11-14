using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Velos.Windows.Capture;

/// <summary>从预乘 BGRA 矢量栅格创建独立光标；CreateIconIndirect 复制位图，临时 GDI 对象立即释放。</summary>
public sealed class NativeCursor : SafeHandleZeroOrMinusOneIsInvalid
{
    private NativeCursor(nint value) : base(true) => SetHandle(value);
    protected override bool ReleaseHandle() => DestroyIcon(handle);

    public static NativeCursor Create(byte[] pixels, int width, int height, int hotspotX, int hotspotY)
    {
        if (width <= 0 || height <= 0 || pixels.Length != checked(width * height * 4)) throw new ArgumentException("光标像素尺寸不符。");
        var header = new BitmapHeader { Size = 40, Width = width, Height = -height, Planes = 1, BitCount = 32, ImageSize = (uint)pixels.Length };
        var color = CreateDIBSection(0, ref header, 0, out var memory, 0, 0);
        if (color == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        nint mask = 0;
        try
        {
            Marshal.Copy(pixels, 0, memory, pixels.Length);
            mask = CreateBitmap(width, height, 1, 1, new byte[checked(((width + 15) / 16 * 2) * height)]);
            if (mask == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            var info = new IconInfo { HotspotX = (uint)hotspotX, HotspotY = (uint)hotspotY, Mask = mask, Color = color };
            var cursor = CreateIconIndirect(ref info);
            if (cursor == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            return new NativeCursor(cursor);
        }
        finally { if (mask != 0) DeleteObject(mask); DeleteObject(color); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct BitmapHeader
    {
        public uint Size; public int Width, Height; public ushort Planes, BitCount; public uint Compression, ImageSize;
        public int XPixelsPerMeter, YPixelsPerMeter; public uint Used, Important;
    }
    [StructLayout(LayoutKind.Sequential)] private struct IconInfo
    {
        public int IsIcon; public uint HotspotX, HotspotY; public nint Mask, Color;
    }
    [DllImport("gdi32.dll", SetLastError = true)] private static extern nint CreateDIBSection(nint dc, ref BitmapHeader header, uint usage, out nint bits, nint section, uint offset);
    [DllImport("gdi32.dll", SetLastError = true)] private static extern nint CreateBitmap(int width, int height, uint planes, uint bits, byte[] data);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint value);
    [DllImport("user32.dll", SetLastError = true)] private static extern nint CreateIconIndirect(ref IconInfo info);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(nint value);
}
