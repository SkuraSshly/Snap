using System.Runtime.InteropServices;
using Velos.Windows.Capture;

namespace Velos.Windows.Recording;

/// <summary>Media Foundation 顺序解码器，用于缩略图与流式 GIF 导出。</summary>
public sealed unsafe class VideoReader : IDisposable
{
    private const uint FirstVideo = 0xfffffffc;
    private nint reader;
    private bool started;
    private bool comStarted;
    private int stride;
    public int Width { get; private set; }
    public int Height { get; private set; }
    public TimeSpan Duration { get; private set; }

    public VideoReader(string path, int maxWidth = 0)
    {
        Marshal.ThrowExceptionForHR(CoInitializeEx(0, 0));
        comStarted = true;
        nint attributes = 0, media = 0, native = 0;
        try
        {
            Marshal.ThrowExceptionForHR(MFStartup(0x20070, 0));
            started = true;
            Marshal.ThrowExceptionForHR(MFCreateAttributes(out attributes, 2));
            Set32(attributes, new("0f81da2c-b537-4672-a8b2-a681b17307a3"), 1);
            Marshal.ThrowExceptionForHR(MFCreateSourceReaderFromURL(Path.GetFullPath(path), attributes, out reader));
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, int, int>)Method(reader, 4))(reader, 0xfffffffe, 0));
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, int, int>)Method(reader, 4))(reader, FirstVideo, 1));
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, nint*, int>)Method(reader, 6))(reader, FirstVideo, &native));
            var sizeKey = new Guid("1652c33d-d6b2-4012-b834-72030849a37d");
            ulong size;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, Guid*, ulong*, int>)Method(native, 8))(native, &sizeKey, &size));
            Width = (int)(size >> 32); Height = (int)(size & 0xffffffff);
            // HEVC 等编码器可以补齐编码块；显示尺寸由 MFVideoArea 定义。
            var aperture = stackalloc byte[16]; uint apertureBytes;
            foreach (var key in new[] { new Guid("d7388766-18fe-48c6-a177-ee894867c8c4"), new Guid("66758743-7e5f-400d-980a-aa8596c85696") })
            {
                var apertureKey = key;
                if (((delegate* unmanaged[Stdcall]<nint, Guid*, byte*, uint, uint*, int>)Method(native, 15))(native, &apertureKey, aperture, 16, &apertureBytes) >= 0 && apertureBytes == 16)
                {
                    var displayWidth = *(int*)(aperture + 8); var displayHeight = *(int*)(aperture + 12);
                    if (displayWidth > 0 && displayWidth <= Width && displayHeight > 0 && displayHeight <= Height) { Width = displayWidth; Height = displayHeight; break; }
                }
            }
            if (Width < 1 || Height < 1) throw new InvalidOperationException("文件中没有视频画面。");
            if (maxWidth > 0 && Width > maxWidth)
            {
                Height = Math.Max(1, (int)Math.Round((double)Height * maxWidth / Width));
                Width = maxWidth;
            }
            Marshal.ThrowExceptionForHR(MFCreateMediaType(out media));
            SetGuid(media, new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f"), new("73646976-0000-0010-8000-00aa00389b71"));
            SetGuid(media, new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5"), new("00000016-0000-0010-8000-00aa00389b71"));
            var outputSize = ((ulong)Width << 32) | (uint)Height;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, Guid*, ulong, int>)Method(media, 22))(media, &sizeKey, outputSize));
            Set32(media, new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6"), (uint)(Width * 4));
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, nint, nint, int>)Method(reader, 7))(reader, FirstVideo, 0, media));
            stride = Width * 4;
            nint current = 0;
            try
            {
                Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, nint*, int>)Method(reader, 6))(reader, FirstVideo, &current));
                var strideKey = new Guid("644b4e48-1e02-4516-b0eb-c01ca9d49ac6"); uint actualStride;
                if (((delegate* unmanaged[Stdcall]<nint, Guid*, uint*, int>)Method(current, 7))(current, &strideKey, &actualStride) >= 0) stride = unchecked((int)actualStride);
            }
            finally { Release(current); }
            var durationKey = new Guid("6c990d33-bb8e-477a-8598-0d5d96fcd88a");
            var value = stackalloc byte[24];
            new Span<byte>(value, 24).Clear();
            try
            {
                if (((delegate* unmanaged[Stdcall]<nint, uint, Guid*, byte*, int>)Method(reader, 12))(reader, 0xffffffff, &durationKey, value) >= 0)
                    Duration = TimeSpan.FromTicks(*(long*)(value + 8));
            }
            finally { PropVariantClear(value); }
        }
        catch { Dispose(); throw; }
        finally { Release(native); Release(media); Release(attributes); }
    }

    public (CapturedPixels Pixels, TimeSpan Time)? Read()
    {
        while (true)
        {
            uint stream, flags;
            long time;
            nint sample = 0, buffer = 0;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, uint, uint*, uint*, long*, nint*, int>)Method(reader, 9))
                (reader, FirstVideo, 0, &stream, &flags, &time, &sample));
            try
            {
                if ((flags & 2) != 0) return null;
                if (sample == 0) continue;
                Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, nint*, int>)Method(sample, 41))(sample, &buffer));
                nint data;
                uint max, length;
                Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, nint*, uint*, uint*, int>)Method(buffer, 3))(buffer, &data, &max, &length));
                try
                {
                    var bytes = new byte[checked(Width * Height * 4)];
                    if (Math.Abs(stride) < Width * 4 || length < (long)Math.Abs(stride) * Height) throw new InvalidOperationException("解码帧尺寸不完整。");
                    for (var y = 0; y < Height; y++) Marshal.Copy(data + (stride < 0 ? (Height - 1 - y) * -stride : y * stride), bytes, y * Width * 4, Width * 4);
                    return (new(Width, Height, bytes), TimeSpan.FromTicks(time));
                }
                finally { Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, int>)Method(buffer, 4))(buffer)); }
            }
            finally { Release(buffer); Release(sample); }
        }
    }

    private static nint Method(nint target, int index) => (*(nint**)target)[index];
    private static void Set32(nint target, Guid key, uint value) => Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, Guid*, uint, int>)Method(target, 21))(target, &key, value));
    private static void SetGuid(nint target, Guid key, Guid value) => Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, Guid*, Guid*, int>)Method(target, 24))(target, &key, &value));
    private static void Release(nint target) { if (target != 0) Marshal.Release(target); }
    public void Dispose()
    {
        Release(reader); reader = 0;
        if (started) { MFShutdown(); started = false; }
        if (comStarted) { CoUninitialize(); comStarted = false; }
    }
    [DllImport("ole32.dll")] private static extern int CoInitializeEx(nint reserved, uint apartment);
    [DllImport("ole32.dll")] private static extern void CoUninitialize();
    [DllImport("ole32.dll")] private static extern int PropVariantClear(byte* value);
    [DllImport("mfplat.dll")] private static extern int MFStartup(uint version, uint flags);
    [DllImport("mfplat.dll")] private static extern int MFShutdown();
    [DllImport("mfplat.dll")] private static extern int MFCreateAttributes(out nint attributes, uint initialSize);
    [DllImport("mfplat.dll")] private static extern int MFCreateMediaType(out nint media);
    [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode)] private static extern int MFCreateSourceReaderFromURL(string url, nint attributes, out nint reader);
}
