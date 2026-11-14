using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Drawing;
using System.Threading.Channels;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

namespace Velos.Windows.Capture;

public sealed record CapturedPixels(int Width, int Height, byte[] Bgra);

public static class WindowsCapture
{
    private static readonly Guid ItemInteropId = new("3628e81b-3cac-4c60-b7f4-23ce0e0c3356");
    private static readonly Guid ItemId = new("79c3f95b-31f7-4ec2-a464-632ef5d30760");

    public static Task<CapturedPixels> FreezeDisplay(Display display, bool includeCursor, CancellationToken cancellation)
        => Task.Run(() => Freeze(display.Handle, false, includeCursor, cancellation), cancellation);

    public static Task StreamRegion(Display display, Rectangle region, Action<CapturedPixels> onFrame, CancellationToken cancellation, bool includeCursor = false)
        => Task.Factory.StartNew(() => Stream(display.Handle, false, region, onFrame, cancellation, includeCursor), cancellation,
            TaskCreationOptions.LongRunning, TaskScheduler.Default);

#if DEBUG
    public static Task<CapturedPixels> DebugFreezeWindow(nint window, CancellationToken cancellation)
        => Task.Run(() => Freeze(window, true, false, cancellation), cancellation);

    public static Task DebugStreamWindow(nint window, Rectangle region, Action<CapturedPixels> onFrame, CancellationToken cancellation)
        => Task.Factory.StartNew(() => Stream(window, true, region, onFrame, cancellation, false), cancellation,
            TaskCreationOptions.LongRunning, TaskScheduler.Default);

    public static Task<System.Drawing.Size> DebugMonitorSize(Display display) => Task.Run(() =>
    {
        Marshal.ThrowExceptionForHR(RoInitialize(1));
        try
        {
            var size = CreateItem(display.Handle, false).Size;
            return new System.Drawing.Size(size.Width, size.Height);
        }
        finally { RoUninitialize(); }
    });
#endif

    private static void Stream(nint target, bool isWindow, Rectangle region, Action<CapturedPixels> onFrame, CancellationToken cancellation, bool includeCursor)
    {
        Marshal.ThrowExceptionForHR(RoInitialize(1));
        try
        {
            cancellation.ThrowIfCancellationRequested();
            if (!GraphicsCaptureSession.IsSupported())
                throw new NotSupportedException("当前系统或桌面会话不支持屏幕采集。");
            var item = CreateItem(target, isWindow);
            var size = item.Size;
            if (region.Width < 1 || region.Height < 1 || !new Rectangle(0, 0, size.Width, size.Height).Contains(region))
                throw new InvalidOperationException("显示器布局已变化，请重新选择区域。");

            using var device = new D3DReadback();
            using var projection = device.CreateProjection();
            using var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                projection, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);
            using var session = pool.CreateCaptureSession(item);
            session.IsCursorCaptureEnabled = includeCursor;

            var signals = Channel.CreateBounded<byte>(1);
            void OnFrame(Direct3D11CaptureFramePool _, object __) => signals.Writer.TryWrite(0);
            void OnClosed(GraphicsCaptureItem _, object __) =>
                signals.Writer.TryComplete(new InvalidOperationException("采集目标已关闭或移除。"));
            pool.FrameArrived += OnFrame;
            item.Closed += OnClosed;
            try
            {
                session.StartCapture();
                using var firstFrameDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
                firstFrameDeadline.CancelAfter(TimeSpan.FromSeconds(3));
                var first = true;
                CapturedPixels? previousPixels = null;
                long lastRead = 0;
                while (!cancellation.IsCancellationRequested)
                {
                    try
                    {
                        signals.Reader.ReadAsync(first ? firstFrameDeadline.Token : cancellation).AsTask().GetAwaiter().GetResult();
                    }
                    catch (OperationCanceledException) when (first && !cancellation.IsCancellationRequested)
                    {
                        throw new InvalidOperationException("等待选区画面超时，请重新开始长截图。");
                    }
                    catch (ChannelClosedException error)
                    {
                        throw new InvalidOperationException(error.InnerException?.Message ?? "采集目标已关闭。", error);
                    }
                    var timestamp = Stopwatch.GetTimestamp();
                    var remaining = Stopwatch.Frequency / 60 - (timestamp - lastRead);
                    if (!first && remaining > 0 &&
                        cancellation.WaitHandle.WaitOne(TimeSpan.FromSeconds((double)remaining / Stopwatch.Frequency)))
                        break;
                    var frame = pool.TryGetNextFrame();
                    if (frame is null)
                        continue;
                    if (pool.TryGetNextFrame() is { } latest)
                    {
                        frame.Dispose();
                        frame = latest;
                    }
                    CapturedPixels pixels;
                    using (frame)
                    {
                        if (frame.ContentSize.Width != size.Width || frame.ContentSize.Height != size.Height)
                            throw new InvalidOperationException("采集目标尺寸已变化，请重新选择区域。");
                        pixels = device.Read(frame.Surface, size.Width, size.Height, region);
                    }
                    if (!HasVisiblePixels(pixels)) continue;
                    first = false;
                    lastRead = Stopwatch.GetTimestamp();
                    if (previousPixels is not null && pixels.Bgra.AsSpan().SequenceEqual(previousPixels.Bgra)) continue;
                    previousPixels = pixels;
                    onFrame(pixels);
                }
            }
            finally
            {
                pool.FrameArrived -= OnFrame;
                item.Closed -= OnClosed;
                signals.Writer.TryComplete();
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        finally { RoUninitialize(); }
    }

    private static CapturedPixels Freeze(nint target, bool isWindow, bool includeCursor, CancellationToken cancellation)
    {
        Marshal.ThrowExceptionForHR(RoInitialize(1)); // RO_INIT_MULTITHREADED
        try
        {
            cancellation.ThrowIfCancellationRequested();
            if (!GraphicsCaptureSession.IsSupported())
                throw new NotSupportedException("当前系统或桌面会话不支持屏幕采集。");

            var item = CreateItem(target, isWindow);
            var size = item.Size;
            if (size.Width <= 0 || size.Height <= 0)
                throw new InvalidOperationException("采集目标没有可用画面。");

            using var device = new D3DReadback();
            using var projection = device.CreateProjection();
            using var pool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                projection, DirectXPixelFormat.B8G8R8A8UIntNormalized, 1, size);
            using var session = pool.CreateCaptureSession(item);
            session.IsCursorCaptureEnabled = includeCursor;

            var arrived = Channel.CreateBounded<byte>(1);
            void OnFrame(Direct3D11CaptureFramePool _, object __) => arrived.Writer.TryWrite(0);
            pool.FrameArrived += OnFrame;
            try
            {
                session.StartCapture();
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
                deadline.CancelAfter(TimeSpan.FromSeconds(3));
                try
                {
                    while (true)
                    {
                        arrived.Reader.ReadAsync(deadline.Token).AsTask().GetAwaiter().GetResult();
                        using var frame = pool.TryGetNextFrame();
                        if (frame is null) continue;
                        if (frame.ContentSize.Width != size.Width || frame.ContentSize.Height != size.Height)
                            throw new InvalidOperationException("采集目标尺寸已变化，请重新截图。");
                        var pixels = device.Read(frame.Surface, size.Width, size.Height);
                        // DWM 在窗口首次提交或桌面恢复时可能先给出全透明占位帧。
                        // 黑色屏幕仍有 alpha；占位帧不能作为用户的截图结果。
                        if (HasVisiblePixels(pixels)) return pixels;
                    }
                }
                catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
                {
                    throw new InvalidOperationException("采集目标尚未提供可见画面，请等待窗口显示后重试。");
                }
            }
            finally
            {
                pool.FrameArrived -= OnFrame;
            }
        }
        finally
        {
            RoUninitialize();
        }
    }

    private static bool HasVisiblePixels(CapturedPixels pixels)
    {
        for (var i = 3; i < pixels.Bgra.Length; i += 4) if (pixels.Bgra[i] != 0) return true;
        return false;
    }

    private static unsafe GraphicsCaptureItem CreateItem(nint target, bool isWindow)
    {
        const string className = "Windows.Graphics.Capture.GraphicsCaptureItem";
        Marshal.ThrowExceptionForHR(WindowsCreateString(className, className.Length, out var name));
        try
        {
            Marshal.ThrowExceptionForHR(RoGetActivationFactory(name, in ItemInteropId, out var factory));
            try
            {
                // IGraphicsCaptureItemInterop 继承 IUnknown，CreateForWindow / CreateForMonitor 紧随其后。
                var create = (delegate* unmanaged[Stdcall]<nint, nint, Guid*, nint*, int>)
                    D3DReadback.Method(factory, isWindow ? 3 : 4);
                var iid = ItemId;
                nint item;
                Marshal.ThrowExceptionForHR(create(factory, target, &iid, &item));
                try { return GraphicsCaptureItem.FromAbi(item); }
                finally { Marshal.Release(item); }
            }
            finally { Marshal.Release(factory); }
        }
        finally { WindowsDeleteString(name); }
    }

    [DllImport("combase.dll")] private static extern int RoInitialize(uint type);
    [DllImport("combase.dll")] private static extern void RoUninitialize();
    [DllImport("combase.dll")] private static extern int RoGetActivationFactory(nint name, in Guid iid, out nint factory);
    [DllImport("combase.dll", CharSet = CharSet.Unicode)] private static extern int WindowsCreateString(string source, int length, out nint value);
    [DllImport("combase.dll")] private static extern int WindowsDeleteString(nint value);
}

internal sealed unsafe class D3DReadback : IDisposable
{
    private static readonly Guid DxgiDeviceId = new("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
    private static readonly Guid DxgiAccessId = new("a9b3d012-3df2-4ee3-b8d1-8695f457d3c1");
    private static readonly Guid Texture2DId = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");
    private nint device;
    private nint context;
    private nint staging;
    private Size stagingSize;

    public D3DReadback()
    {
        const uint bgraSupport = 0x20;
        var result = D3D11CreateDevice(0, 1, 0, bgraSupport, 0, 0, 7, out device, out _, out context);
        if (result < 0)
        {
            Dispose();
            Marshal.ThrowExceptionForHR(D3D11CreateDevice(0, 5, 0, bgraSupport, 0, 0, 7, out device, out _, out context));
        }
    }

    public IDirect3DDevice CreateProjection()
    {
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(device, in DxgiDeviceId, out var dxgi));
        try
        {
            Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi, out var inspectable));
            try { return MarshalInterface<IDirect3DDevice>.FromAbi(inspectable); }
            finally { Marshal.Release(inspectable); }
        }
        finally { Marshal.Release(dxgi); }
    }

    public CapturedPixels Read(IDirect3DSurface surface, int width, int height, Rectangle? region = null)
    {
        var inspectable = ((IWinRTObject)surface).NativeObject.ThisPtr;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(inspectable, in DxgiAccessId, out var access));
        try
        {
            var getInterface = (delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)Method(access, 3);
            var iid = Texture2DId;
            nint texture;
            Marshal.ThrowExceptionForHR(getInterface(access, &iid, &texture));
            try { return ReadTexture(texture, width, height, region ?? new Rectangle(0, 0, width, height)); }
            finally { Marshal.Release(texture); }
        }
        finally { Marshal.Release(access); }
    }

    private CapturedPixels ReadTexture(nint texture, int width, int height, Rectangle region)
    {
        TextureDescription description;
        var getDesc = (delegate* unmanaged[Stdcall]<nint, TextureDescription*, void>)Method(texture, 10);
        getDesc(texture, &description); // ID3D11Texture2D::GetDesc
        if (description.Width != width || description.Height != height || description.Format != 87)
            throw new InvalidOperationException("采集画面与显示器尺寸或像素格式不匹配。");

        EnsureStaging(description, region.Size);
        if (region.X == 0 && region.Y == 0 && region.Width == width && region.Height == height)
        {
            var copy = (delegate* unmanaged[Stdcall]<nint, nint, nint, void>)Method(context, 47);
            copy(context, staging, texture); // ID3D11DeviceContext::CopyResource
        }
        else
        {
            var copy = (delegate* unmanaged[Stdcall]<nint, nint, uint, uint, uint, uint, nint, uint, TextureBox*, void>)
                Method(context, 46);
            var box = new TextureBox
            {
                Left = (uint)region.Left, Top = (uint)region.Top, Right = (uint)region.Right,
                Bottom = (uint)region.Bottom, Back = 1
            };
            copy(context, staging, 0, 0, 0, 0, texture, 0, &box);
        }

        var map = (delegate* unmanaged[Stdcall]<nint, nint, uint, uint, uint, MappedResource*, int>)Method(context, 14);
        var unmap = (delegate* unmanaged[Stdcall]<nint, nint, uint, void>)Method(context, 15);
        MappedResource mapped;
        Marshal.ThrowExceptionForHR(map(context, staging, 0, 1, 0, &mapped)); // D3D11_MAP_READ
        try
        {
            var stride = checked(region.Width * 4);
            var data = GC.AllocateUninitializedArray<byte>(checked(stride * region.Height));
            for (var row = 0; row < region.Height; row++)
            {
                var source = new ReadOnlySpan<byte>((byte*)mapped.Data + (nint)row * mapped.RowPitch, stride);
                source.CopyTo(data.AsSpan(row * stride, stride));
            }
            return new CapturedPixels(region.Width, region.Height, data);
        }
        finally { unmap(context, staging, 0); }
    }

    private void EnsureStaging(TextureDescription description, Size size)
    {
        if (staging != 0 && stagingSize == size)
            return;
        if (staging != 0)
        {
            Marshal.Release(staging);
            staging = 0;
        }
        description.Width = (uint)size.Width;
        description.Height = (uint)size.Height;
        description.Usage = 3;
        description.BindFlags = 0;
        description.CpuAccess = 0x20000;
        description.MiscFlags = 0;
        var create = (delegate* unmanaged[Stdcall]<nint, TextureDescription*, nint, nint*, int>)Method(device, 5);
        nint texture;
        Marshal.ThrowExceptionForHR(create(device, &description, 0, &texture));
        staging = texture;
        stagingSize = size;
    }

    internal static nint Method(nint instance, int index) => (*(nint**)instance)[index];

    public void Dispose()
    {
        if (staging != 0) { Marshal.Release(staging); staging = 0; }
        if (context != 0) { Marshal.Release(context); context = 0; }
        if (device != 0) { Marshal.Release(device); device = 0; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TextureDescription
    {
        public uint Width, Height, MipLevels, ArraySize, Format, SampleCount, SampleQuality, Usage, BindFlags, CpuAccess, MiscFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MappedResource
    {
        public nint Data;
        public uint RowPitch, DepthPitch;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TextureBox
    {
        public uint Left, Top, Front, Right, Bottom, Back;
    }

    [DllImport("d3d11.dll")] private static extern int D3D11CreateDevice(
        nint adapter, uint driver, nint software, uint flags, nint levels, uint levelCount, uint sdkVersion,
        out nint device, out uint level, out nint context);

    [DllImport("d3d11.dll")] private static extern int CreateDirect3D11DeviceFromDXGIDevice(nint dxgi, out nint inspectable);
}
