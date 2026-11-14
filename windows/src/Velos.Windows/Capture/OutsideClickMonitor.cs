using System.ComponentModel;
using System.Drawing;
using System.Runtime.InteropServices;

namespace Velos.Windows.Capture;

// 对应 TranslationWindow 的全局鼠标按下监听：只观察，不吞掉任何输入。
public sealed class OutsideClickMonitor : IDisposable
{
    private readonly Hook callback;
    private nint hook;
    public OutsideClickMonitor(nint window, Action outside)
    {
        callback = (code, message, data) =>
        {
            if (code >= 0 && ((int)message is 0x0201 or 0x0204))
            {
                var point = Marshal.PtrToStructure<MouseData>(data).Point;
                var target = GetAncestor(WindowFromPoint(point), 2);
                var belongs = false;
                var current = target;
                for (var depth = 0; current != 0 && depth < 32; depth++, current = GetWindow(current, 4))
                { if (current == window) { belongs = true; break; } }
                if (!belongs) outside();
            }
            return CallNextHookEx(hook, code, message, data);
        };
        hook = SetWindowsHookEx(14, callback, GetModuleHandle(null), 0);
        if (hook == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public void Dispose() { if (hook == 0) return; UnhookWindowsHookEx(hook); hook = 0; }
    private delegate nint Hook(int code, nint message, nint data);
    [StructLayout(LayoutKind.Sequential)] private struct MouseData { public Point Point; public uint MouseDataValue, Flags, Time; public nuint ExtraInfo; }
    [DllImport("user32.dll", SetLastError = true)] private static extern nint SetWindowsHookEx(int id, Hook callback, nint module, uint thread);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] private static extern nint CallNextHookEx(nint hook, int code, nint message, nint data);
    [DllImport("user32.dll")] private static extern nint WindowFromPoint(Point point);
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint window, uint flags);
    [DllImport("user32.dll")] private static extern nint GetWindow(nint window, uint command);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern nint GetModuleHandle(string? name);
}
