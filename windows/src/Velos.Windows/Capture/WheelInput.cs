using System.Drawing;
using System.Runtime.InteropServices;

namespace Velos.Windows.Capture;

/// <summary>只在用户开启自动滚动后发送无坐标滚轮；不监听、不拦截用户输入。</summary>
public sealed class WheelInput
{
    private readonly uint? integrity = ReadIntegrity((uint)Environment.ProcessId);
    private nint lastTarget, lastForeground;
    private bool trusted;
    private double carry;

    public bool Scroll(double dip, Point pointer)
    {
        var hovered = GetAncestor(WindowFromPoint(pointer), 2); var foreground = GetForegroundWindow();
        if (hovered != lastTarget || foreground != lastForeground)
        {
            lastTarget = hovered; lastForeground = foreground; carry = 0;
            trusted = integrity is { } own && CanSendTo(hovered, own) && (foreground == hovered || CanSendTo(foreground, own));
        }
        if (!trusted) return false;
        SystemParametersInfo(0x0068, 0, out var lines, 0);
        var pixelsPerNotch = lines == uint.MaxValue ? 480 : Math.Max(1, lines) * 16d;
        carry += -dip * 120 / pixelsPerNotch;
        var delta = (int)carry;
        if (delta == 0) return true;
        carry -= delta;
        var input = new Input { Mouse = new MouseInput { MouseData = unchecked((uint)delta), Flags = 0x0800, ExtraInfo = 0x56454c53u } };
        return SendInput(1, in input, Marshal.SizeOf<Input>()) == 1;
    }

    private static bool CanSendTo(nint window, uint own)
    { GetWindowThreadProcessId(window, out var id); return id != 0 && ReadIntegrity(id) is { } target && target <= own; }

    private static uint? ReadIntegrity(uint id)
    {
        var process = OpenProcess(0x1000, false, id); if (process == 0) return null;
        try
        {
            if (!OpenProcessToken(process, 8, out var token)) return null;
            try
            {
                GetTokenInformation(token, 25, 0, 0, out var size); if (size == 0) return null;
                var data = Marshal.AllocHGlobal(size);
                try
                {
                    if (!GetTokenInformation(token, 25, data, size, out _)) return null;
                    var sid = Marshal.ReadIntPtr(data); var count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
                    return count > 0 ? unchecked((uint)Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)))) : null;
                }
                finally { Marshal.FreeHGlobal(data); }
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }

#if DEBUG
    public static bool DebugHasNoPointerMovement => new MouseInput { Flags = 0x0800 } is { X: 0, Y: 0, Flags: 0x0800 } && Marshal.SizeOf<Input>() == (IntPtr.Size == 8 ? 40 : 28);
#endif
    [StructLayout(LayoutKind.Sequential)] private struct Input { public uint Type; public MouseInput Mouse; }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput { public int X, Y; public uint MouseData, Flags, Time; public nuint ExtraInfo; }
    [DllImport("user32.dll")] private static extern uint SendInput(uint count, in Input input, int size);
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW")] private static extern bool SystemParametersInfo(uint action, uint param, out uint value, uint flags);
    [DllImport("user32.dll")] private static extern nint WindowFromPoint(Point point);
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint window, uint flags);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("kernel32.dll")] private static extern nint OpenProcess(uint access, bool inherit, uint id);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(nint handle);
    [DllImport("advapi32.dll")] private static extern bool OpenProcessToken(nint process, uint access, out nint token);
    [DllImport("advapi32.dll")] private static extern bool GetTokenInformation(nint token, int type, nint buffer, int size, out int required);
    [DllImport("advapi32.dll")] private static extern nint GetSidSubAuthorityCount(nint sid);
    [DllImport("advapi32.dll")] private static extern nint GetSidSubAuthority(nint sid, uint index);
}
