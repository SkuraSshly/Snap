using System.Drawing;
using System.Runtime.InteropServices;

namespace Velos.Windows.Capture;

public sealed record Display(nint Handle, Rectangle Bounds, Rectangle WorkArea);

public static class Desktop
{
    private static readonly HashSet<nint> screenshotWindows = [];
    public static bool RecordingActive { get; private set; }

    public static void SetRecordingActive(bool active)
    {
        RecordingActive = active;
        foreach (var window in screenshotWindows) ExcludeFromCapture(window, !active);
    }

    public static bool ExcludeForScreenshots(nint window)
    {
        screenshotWindows.Add(window);
        return ExcludeFromCapture(window, !RecordingActive);
    }
    public static void ForgetScreenshotWindow(nint window) => screenshotWindows.Remove(window);

    public static IReadOnlyList<Display> Displays()
    {
        var displays = new List<Display>();
        EnumDisplayMonitors(0, 0, (monitor, _, _, _) =>
        {
            var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            if (GetMonitorInfo(monitor, ref info))
                displays.Add(new Display(monitor, info.Monitor.Rectangle, info.Work.Rectangle));
            return true;
        }, 0);
        return displays;
    }

    public static Point Pointer()
    {
        GetCursorPos(out var point);
        return point;
    }

    public static IReadOnlyList<Rectangle> WindowBounds(IReadOnlySet<nint> excluded)
    {
        var result = new List<Rectangle>();
        var desktop = GetShellWindow();
        EnumWindows((window, _) =>
        {
            if (window == desktop || excluded.Contains(window) || screenshotWindows.Contains(window) ||
                GetWindowDisplayAffinity(window, out var affinity) && affinity == 0x11 || !IsWindowVisible(window) || IsIconic(window))
                return true;
            if (IsDesktopBackground(window))
                return true;
            if (DwmGetWindowAttribute(window, 14, out int cloaked, sizeof(int)) == 0 && cloaked != 0)
                return true;
            if (DwmGetWindowAttribute(window, 9, out NativeRect rect, Marshal.SizeOf<NativeRect>()) != 0 &&
                !GetWindowRect(window, out rect))
                return true;
            var bounds = rect.Rectangle;
            if (bounds.Width >= 4 && bounds.Height >= 4)
                result.Add(bounds);
            return true;
        }, 0);
        return result;
    }

    private static unsafe bool IsDesktopBackground(nint window)
    {
        Span<char> name = stackalloc char[32];
        fixed (char* buffer = name)
        {
            var length = GetClassName(window, buffer, name.Length);
            return name[..length] is "Progman" or "WorkerW";
        }
    }

    public static bool Position(nint window, Rectangle bounds)
        => SetWindowPos(window, 0, bounds.X, bounds.Y, bounds.Width, bounds.Height, 0x0014);
    public static bool Move(nint window, int x, int y)
        => SetWindowPos(window, 0, x, y, 0, 0, 0x0015);
    public static Rectangle WindowRectangle(nint window) => GetWindowRect(window, out var bounds) ? bounds.Rectangle : Rectangle.Empty;

    public static bool ExcludeFromCapture(nint window, bool exclude)
        => SetWindowDisplayAffinity(window, exclude ? 0x11u : 0u);

#if DEBUG
    public static bool DebugIsExcluded(nint window) => GetWindowDisplayAffinity(window, out var affinity) && affinity == 0x11;
#endif
    [DllImport("user32.dll")] private static extern bool GetWindowDisplayAffinity(nint window, out uint affinity);

    public static void FlushComposition() => DwmFlush();

    public static void MakeClickThrough(nint window)
    {
        const int extendedStyle = -20;
        SetWindowLongPtr(window, extendedStyle, GetWindowLongPtr(window, extendedStyle) | 0x08000020);
    }

    public static void MakeNonActivating(nint window)
    {
        const int extendedStyle = -20;
        SetWindowLongPtr(window, extendedStyle, GetWindowLongPtr(window, extendedStyle) | 0x08000000);
    }

    public static bool RoundWindow(nint window, int width, int height, int radius)
    {
        var region = CreateRoundRectRgn(0, 0, width + 1, height + 1, radius * 2, radius * 2);
        if (region == 0)
            return false;
        if (SetWindowRgn(window, region, true) != 0)
            return true; // 系统接管 HRGN。
        DeleteObject(region);
        return false;
    }

    public static bool TryAcrylic(nint window, bool dark)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22621))
            return false;
        var useDark = dark ? 1 : 0;
        var backdrop = 3; // DWMSBT_TRANSIENTWINDOW
        DwmSetWindowAttribute(window, 20, in useDark, sizeof(int));
        return DwmSetWindowAttribute(window, 38, in backdrop, sizeof(int)) == 0;
    }

    public static bool TryRegisterEscape(nint window, int id) => RegisterHotKey(window, id, 0x4000, 0x1b);
    public static void UnregisterKey(nint window, int id) => UnregisterHotKey(window, id);

    public static unsafe uint? ChooseRgb(nint owner, uint rgb)
    {
        var custom = stackalloc uint[16];
        new Span<uint>(custom, 16).Clear();
        var options = new ChooseColorInfo
        {
            Size = Marshal.SizeOf<ChooseColorInfo>(), Owner = owner, Result = SwapRedBlue(rgb),
            CustomColors = (nint)custom, Flags = 3 // CC_RGBINIT | CC_FULLOPEN
        };
        return ChooseColor(ref options) ? SwapRedBlue(options.Result) : null;
    }

    private static uint SwapRedBlue(uint value) => ((value & 0xff) << 16) | (value & 0xff00) | ((value >> 16) & 0xff);

    [StructLayout(LayoutKind.Sequential)]
    private struct ChooseColorInfo
    {
        public int Size;
        public nint Owner, Instance;
        public uint Result;
        public nint CustomColors;
        public uint Flags;
        public nint CustomData, Hook, Template;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left, Top, Right, Bottom;
        public readonly Rectangle Rectangle => Rectangle.FromLTRB(Left, Top, Right, Bottom);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public int Size;
        public NativeRect Monitor, Work;
        public uint Flags;
    }

    private delegate bool MonitorCallback(nint monitor, nint dc, nint bounds, nint data);
    private delegate bool WindowCallback(nint window, nint data);

    [DllImport("user32.dll")] private static extern bool EnumDisplayMonitors(nint dc, nint rect, MonitorCallback callback, nint data);
    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW")] private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback callback, nint data);
    [DllImport("user32.dll")] private static extern nint GetShellWindow();
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint window);
    [DllImport("user32.dll", EntryPoint = "GetClassNameW")] private static extern unsafe int GetClassName(nint window, char* name, int limit);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint window, out NativeRect rect);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint order, int x, int y, int w, int h, uint flags);
    [DllImport("user32.dll")] private static extern bool SetWindowDisplayAffinity(nint window, uint affinity);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint window, uint attribute, out NativeRect value, int size);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint window, uint attribute, out int value, int size);
    [DllImport("dwmapi.dll")] private static extern int DwmFlush();
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(nint window, int attribute, in int value, int size);
    private static nint GetWindowLongPtr(nint window, int index) =>
        nint.Size == 8 ? GetWindowLong64(window, index) : GetWindowLong32(window, index);
    private static nint SetWindowLongPtr(nint window, int index, nint value) =>
        nint.Size == 8 ? SetWindowLong64(window, index, value) : SetWindowLong32(window, index, (int)value);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern nint GetWindowLong64(nint window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern nint SetWindowLong64(nint window, int index, nint value);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] private static extern int GetWindowLong32(nint window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] private static extern int SetWindowLong32(nint window, int index, int value);
    [DllImport("user32.dll")] private static extern int SetWindowRgn(nint window, nint region, bool redraw);
    [DllImport("gdi32.dll")] private static extern nint CreateRoundRectRgn(int left, int top, int right, int bottom, int width, int height);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint handle);
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(nint window, int id);
    [DllImport("comdlg32.dll", EntryPoint = "ChooseColorW")] private static extern bool ChooseColor(ref ChooseColorInfo options);
}
