using System.Runtime.InteropServices;

namespace Velos.Windows;

public sealed record TrayMenuItem(string? Title, Action? Invoke = null);

public sealed class TrayIcon : IDisposable
{
    private const uint Id = 1;
    private const uint Callback = 0x8001;
    private const uint Add = 0, Modify = 1, Delete = 2, SetVersion = 4;
    private const uint MessageFlag = 1, IconFlag = 2, TipFlag = 4, InfoFlag = 0x10, ShowTipFlag = 0x80;
    private const int ContextMenu = 0x7b, Select = 0x400, KeySelect = 0x401;
    private readonly nint window;
    private readonly Func<int, byte[]> loadIconPng;
    private nint icon;
    private bool ownsIcon;
    private readonly Func<IReadOnlyList<TrayMenuItem>> menuItems;
    private readonly Action activate;
    private readonly uint taskbarCreated = RegisterWindowMessage("TaskbarCreated");
    private bool visible;
    private bool added;
    private bool version4;

    public TrayIcon(nint window, Func<IReadOnlyList<TrayMenuItem>> menuItems, Func<int, byte[]> loadIconPng, Action activate)
    {
        this.window = window;
        this.menuItems = menuItems;
        this.loadIconPng = loadIconPng;
        this.activate = activate;
    }

    private void LoadTaskbarIcon()
    {
        var taskbar = FindWindow("Shell_TrayWnd", null);
        var dpi = taskbar == 0 ? 96u : Math.Max(96u, GetDpiForWindow(taskbar));
        var size = Math.Max(16, GetSystemMetricsForDpi(49, dpi)); // SM_CXSMICON
        var png = loadIconPng(size);
        var next = CreateIconFromResourceEx(png, (uint)png.Length, true, 0x00030000, size, size, 0);
        if (ownsIcon)
            DestroyIcon(icon);
        ownsIcon = next != 0;
        icon = ownsIcon ? next : LoadIcon(0, 32512);
    }

    public bool SetVisible(bool value)
    {
        visible = value;
        if (!visible)
        {
            if (added)
            {
                var data = Data();
                ShellNotifyIcon(Delete, ref data);
                added = false;
            }
            return true;
        }

        return added || AddToTaskbar();
    }

    private bool AddToTaskbar()
    {
        LoadTaskbarIcon();
        var data = Data();
        data.Flags = MessageFlag | IconFlag | TipFlag | ShowTipFlag;
        data.CallbackMessage = Callback;
        data.Icon = icon;
        data.Tip = "Velos · 左键打开界面，右键显示菜单";
        added = ShellNotifyIcon(Add, ref data);
        if (added)
        {
            data.Version = 4;
            version4 = ShellNotifyIcon(SetVersion, ref data);
        }
        return added;
    }

    public bool Notify(string text)
    {
        if (!added)
            return false;

        var data = Data();
        data.Flags = InfoFlag;
        data.InfoTitle = "Velos";
        data.Info = text;
        data.InfoFlags = 0x10; // NIIF_NOSOUND
        return ShellNotifyIcon(Modify, ref data);
    }

    public bool HandleMessage(int message, nint wParam, nint lParam)
    {
        if (message == taskbarCreated)
        {
            added = false;
            if (visible)
                AddToTaskbar();
            return true;
        }

        if ((message == 0x001a || message == 0x02e0) && added)
        {
            LoadTaskbarIcon();
            var data = Data();
            data.Flags = IconFlag;
            data.Icon = icon;
            ShellNotifyIcon(Modify, ref data);
        }

        if (message != Callback)
            return false;

        switch ((int)lParam & 0xffff)
        {
            case ContextMenu:
                var x = unchecked((short)(int)wParam);
                var y = unchecked((short)((int)wParam >> 16));
                if (x == -1 && y == -1 && GetCursorPos(out var cursor))
                    ShowMenu(cursor.X, cursor.Y);
                else
                    ShowMenu(x, y);
                break;
            case Select:
            case KeySelect:
                activate();
                break;
            case 0x0202 when !version4: // 旧托盘协议 WM_LBUTTONUP。
                activate();
                break;
            case 0x0205 when !version4: // 旧托盘协议 WM_RBUTTONUP。
                if (GetCursorPos(out var rightClick)) ShowMenu(rightClick.X, rightClick.Y);
                break;
        }
        return true;
    }

    private void ShowMenu(int x, int y)
    {
        var menu = CreatePopupMenu();
        if (menu == 0)
            return;

        var items = menuItems();
        uint selection;
        try
        {
            for (var index = 0; index < items.Count; index++)
            {
                var item = items[index];
                uint flags = item.Title is null ? 0x800u : item.Invoke is null ? 1u : 0u;
                AppendMenu(menu, flags, (nuint)(index + 1), item.Title);
            }

            SetForegroundWindow(window);
            selection = TrackPopupMenu(menu, 0x100 | 0x80 | 0x02, x, y, 0, window, 0);
            PostMessage(window, 0, 0, 0);
        }
        finally
        {
            DestroyMenu(menu);
        }

        if (selection > 0 && selection <= items.Count)
            items[(int)selection - 1].Invoke?.Invoke();
    }

    private NotifyIconData Data() => new()
    {
        Size = (uint)Marshal.SizeOf<NotifyIconData>(),
        Window = window,
        Id = Id,
        Tip = "",
        Info = "",
        InfoTitle = ""
    };

    public void Dispose()
    {
        SetVisible(false);
        if (ownsIcon)
            DestroyIcon(icon);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public nint Window;
        public uint Id, Flags, CallbackMessage;
        public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags;
        public Guid Guid;
        public nint BalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Point
    {
        public int X, Y;
    }

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShellNotifyIcon(uint message, ref NotifyIconData data);

    [DllImport("user32.dll", EntryPoint = "FindWindowW", CharSet = CharSet.Unicode)]
    private static extern nint FindWindow(string className, string? title);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll")] private static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("user32.dll")] private static extern nint CreateIconFromResourceEx(
        byte[] data, uint length, [MarshalAs(UnmanagedType.Bool)] bool icon, uint version, int width, int height, uint flags);

    [DllImport("user32.dll", EntryPoint = "LoadIconW")]
    private static extern nint LoadIcon(nint instance, nint resource);

    [DllImport("user32.dll", EntryPoint = "RegisterWindowMessageW", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string name);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(nint icon);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll")]
    private static extern nint CreatePopupMenu();

    [DllImport("user32.dll", EntryPoint = "AppendMenuW", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenu(nint menu, uint flags, nuint id, string? text);

    [DllImport("user32.dll")]
    private static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint window, nint bounds);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint window);

    [DllImport("user32.dll", EntryPoint = "PostMessageW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(nint window, uint message, nint wParam, nint lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyMenu(nint menu);

#if DEBUG
    public bool DebugUsesReferenceIcon => ownsIcon;

    public bool DebugIconExists()
    {
        var identifier = new NotifyIconIdentifier
        {
            Size = (uint)Marshal.SizeOf<NotifyIconIdentifier>(),
            Window = window,
            Id = Id
        };
        return Shell_NotifyIconGetRect(ref identifier, out _) == 0;
    }

    public bool DebugSimulateTaskbarRecreated()
    {
        var data = Data();
        if (!ShellNotifyIcon(Delete, ref data) || DebugIconExists())
            return false;
        HandleMessage((int)taskbarCreated, 0, 0);
        return DebugIconExists();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NotifyIconIdentifier
    {
        public uint Size;
        public nint Window;
        public uint Id;
        public Guid Guid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("shell32.dll", ExactSpelling = true)]
    private static extern int Shell_NotifyIconGetRect(ref NotifyIconIdentifier identifier, out Rect iconLocation);
#endif
}
