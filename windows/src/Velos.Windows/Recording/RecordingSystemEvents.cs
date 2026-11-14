using System.Runtime.InteropServices;

namespace Velos.Windows.Recording;

public enum RecordingSystemEvent { DisplayOff, SessionLocked, SessionDisconnected, Suspend }

/// <summary>仅在录制期间注册；所有消息由主窗口的消息回调转入，无定时查询。</summary>
public sealed class RecordingSystemEvents : IDisposable
{
    private static readonly Guid ConsoleDisplayState = new("6fe69556-704a-47a0-8f24-c28d936fda47");
    private readonly nint window;
    private readonly Action<RecordingSystemEvent> changed;
    private nint power;
    private bool disposed;
    public bool SessionRegistered { get; }
    public bool DisplayRegistered => power != 0;
    public RecordingSystemEvents(nint window, Action<RecordingSystemEvent> changed)
    {
        this.window = window; this.changed = changed;
        SessionRegistered = WTSRegisterSessionNotification(window, 0);
        var setting = ConsoleDisplayState; power = RegisterPowerSettingNotification(window, in setting, 0);
    }
    public void HandleMessage(int message, nint wParam, nint lParam)
    {
        if (disposed) return;
        if (message == 0x02b1 && SessionRegistered)
        {
            if (wParam == 7) changed(RecordingSystemEvent.SessionLocked);
            else if (wParam == 2 || wParam == 4 || wParam == 6) changed(RecordingSystemEvent.SessionDisconnected);
        }
        else if (message == 0x0218)
        {
            if (wParam == 4) changed(RecordingSystemEvent.Suspend);
            else if (wParam == 0x8013 && power != 0 && lParam != 0 && Marshal.PtrToStructure<Guid>(lParam) == ConsoleDisplayState
                && Marshal.ReadInt32(lParam, 16) == 4 && Marshal.ReadInt32(lParam, 20) == 0)
                changed(RecordingSystemEvent.DisplayOff);
        }
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        if (SessionRegistered) WTSUnRegisterSessionNotification(window);
        if (power != 0) { UnregisterPowerSettingNotification(power); power = 0; }
    }
    [DllImport("wtsapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool WTSRegisterSessionNotification(nint window, uint flags);
    [DllImport("wtsapi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool WTSUnRegisterSessionNotification(nint window);
    [DllImport("user32.dll", SetLastError = true)] private static extern nint RegisterPowerSettingNotification(nint recipient, in Guid setting, uint flags);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UnregisterPowerSettingNotification(nint handle);
}
