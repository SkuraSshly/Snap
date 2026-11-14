using System.Runtime.InteropServices;

namespace Velos.Windows.Capture;

/// <summary>FrontmostAppGuard 的 Win32 对应：仅选区期间监听前台变化，不抢回用户已切走的焦点。</summary>
public sealed class SelectionFocus : IDisposable
{
    private readonly nint previous = GetForegroundWindow();
    private readonly uint process = (uint)Environment.ProcessId;
    private readonly Action<SelectionFocus> lost;
    private readonly WinEvent callback;
    private nint hook;
    private bool watching, finished;
    public SelectionFocus(Action<SelectionFocus> lost)
    {
        this.lost = lost; callback = OnForeground;
        hook = SetWinEventHook(3, 3, 0, callback, 0, 0, 0); // EVENT_SYSTEM_FOREGROUND / OUTOFCONTEXT
        Observe(GetForegroundWindow());
    }
    private void OnForeground(nint h, uint e, nint window, int id, int child, uint thread, uint time) => Observe(window);
    private void Observe(nint window)
    {
        if (finished || window == 0) return;
        GetWindowThreadProcessId(window, out var owner);
        Changed(owner);
    }
    private void Changed(uint owner)
    {
        if (finished || owner == 0) return;
        if (owner == process) watching = true;
        else if (watching) { Stop(); lost(this); }
    }
    private void Stop() { finished = true; if (hook != 0) { UnhookWinEvent(hook); hook = 0; } }
    public void Finish(bool restoreFocus = true)
    {
        var wasFinished = finished; Stop();
        if (!restoreFocus || wasFinished || previous == 0 || !IsWindow(previous)) return;
        GetWindowThreadProcessId(GetForegroundWindow(), out var owner);
        GetWindowThreadProcessId(previous, out var previousOwner);
        if (owner == process && previousOwner != process) SetForegroundWindow(previous);
    }
    public void Dispose() => Finish();
#if DEBUG
    public bool DebugInstalled => hook != 0;
    public void DebugForeground(uint owner) => Changed(owner);
#endif
    private delegate void WinEvent(nint hook, uint e, nint hwnd, int objectId, int child, uint thread, uint time);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint hwnd, out uint process);
    [DllImport("user32.dll")] private static extern nint SetWinEventHook(uint min, uint max, nint module, WinEvent callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(nint hook);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern bool IsWindow(nint window);
}
