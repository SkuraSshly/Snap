using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Velos.Windows.Capture;

public sealed class ClipboardOwner(nint window) : IDisposable
{
    private const uint DibFormat = 8;
    private readonly uint pngFormat = RegisterClipboardFormat("PNG");
    private PendingImage? pending;
    private long copyRevision;

    public async Task CopyImage(byte[] png, Func<byte[]> makeDib, Action? firstRead)
    {
        if (pngFormat == 0)
            throw new InvalidOperationException("无法注册 PNG 剪贴板格式。");
        var revision = ++copyRevision;
        for (var attempt = 0; !OpenClipboard(window); attempt++)
        {
            if (attempt == 7)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "剪贴板正忙，请重试。");
            await Task.Delay(22);
            if (revision != copyRevision)
                return;
        }
        try
        {
            if (!EmptyClipboard())
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法清空剪贴板。");
            pending = new PendingImage(png, makeDib, firstRead);
            SetClipboardData(pngFormat, 0);
            SetClipboardData(DibFormat, 0);
            if (!IsClipboardFormatAvailable(pngFormat) || !IsClipboardFormatAvailable(DibFormat))
                throw new InvalidOperationException("无法写入截图剪贴板格式。");
        }
        finally { CloseClipboard(); }
    }

    public bool HandleMessage(int message, nint wParam)
    {
        switch (message)
        {
            case 0x0305: // WM_RENDERFORMAT
                Render(unchecked((uint)wParam), notify: true);
                return true;
            case 0x0306: // WM_RENDERALLFORMATS
                RenderAll();
                return true;
            case 0x0307: // WM_DESTROYCLIPBOARD
                pending = null;
                return true;
            default:
                return false;
        }
    }

    private void Render(uint format, bool notify)
    {
        if (pending is not { } data)
            return;
        var png = format == pngFormat;
        if ((!png && format != DibFormat) || (png ? data.PngRendered : data.DibRendered))
            return;
        try
        {
            var bytes = png ? data.Png : data.MakeDib();
            if (!Transfer(format, bytes))
                return;
            if (png) data.PngRendered = true;
            else data.DibRendered = true;
            if (notify && data.FirstRead is { } action)
            {
                data.FirstRead = null;
                action();
            }
            if (data.PngRendered && data.DibRendered)
                pending = null;
        }
        catch (Exception error) when (error is InvalidOperationException or ExternalException or ArgumentException)
        {
            // 剪贴板读方可以重试。保留其他格式供系统继续请求。
        }
    }

    private static bool Transfer(uint format, byte[] bytes)
    {
        var memory = TransferMemory.Create(bytes);
        if (memory == 0)
            return false;
        if (SetClipboardData(format, memory) != 0)
            return true; // 所有权交给系统剪贴板。
        TransferMemory.Free(memory);
        return false;
    }

    private void RenderAll()
    {
        if (pending is null || !OpenClipboard(window))
            return;
        try
        {
            if (GetClipboardOwner() == window)
            {
                Render(pngFormat, notify: false);
                Render(DibFormat, notify: false);
            }
        }
        finally { CloseClipboard(); }
    }

    public void Dispose()
    {
        CancelCopyAttempt();
        RenderAll();
        pending = null;
    }

    public void CancelCopyAttempt() => copyRevision++;

    private sealed class PendingImage(byte[] png, Func<byte[]> makeDib, Action? firstRead)
    {
        public byte[] Png { get; } = png;
        public Func<byte[]> MakeDib { get; } = makeDib;
        public Action? FirstRead { get; set; } = firstRead;
        public bool PngRendered { get; set; }
        public bool DibRendered { get; set; }
    }

    [DllImport("user32.dll", EntryPoint = "RegisterClipboardFormatW", CharSet = CharSet.Unicode)]
    private static extern uint RegisterClipboardFormat(string name);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool OpenClipboard(nint owner);
    [DllImport("user32.dll")] private static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError = true)] private static extern bool EmptyClipboard();
    [DllImport("user32.dll")] private static extern nint GetClipboardOwner();
    [DllImport("user32.dll")] private static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll")] private static extern nint SetClipboardData(uint format, nint data);
}

public static class TransferMemory
{
    public static nint Create(byte[] bytes)
    {
        var memory = GlobalAlloc(2, (nuint)bytes.Length); // GMEM_MOVEABLE
        if (memory == 0)
            return 0;
        var pointer = GlobalLock(memory);
        if (pointer == 0)
        {
            Free(memory);
            return 0;
        }
        try { Marshal.Copy(bytes, 0, pointer, bytes.Length); }
        finally { GlobalUnlock(memory); }
        return memory;
    }

    public static void Free(nint memory) => GlobalFree(memory);

    [DllImport("kernel32.dll")] private static extern nint GlobalAlloc(uint flags, nuint size);
    [DllImport("kernel32.dll")] private static extern nint GlobalLock(nint memory);
    [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(nint memory);
    [DllImport("kernel32.dll")] private static extern nint GlobalFree(nint memory);
}
