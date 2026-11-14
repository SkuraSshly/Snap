namespace Velos.Core.Hotkeys;

public static class HotkeyConflicts
{
    private static readonly HashSet<Hotkey> Editing = CreateEditingShortcuts();

    public static string? Validate(Hotkey candidate, HotkeyAction action, Func<HotkeyAction, Hotkey> assigned)
    {
        var problem = ValidateKey(candidate);
        if (problem is not null)
            return problem;

        foreach (var other in Enum.GetValues<HotkeyAction>())
        {
            if (other != action && candidate == assigned(other))
                return $"{candidate} 已经是「{Hotkey.Title(other)}」的快捷键。";
        }

        if (Editing.Contains(candidate))
            return $"{candidate} 是常用的编辑快捷键，设为全局快捷键会影响其他应用。";

        var systemName = SystemShortcutName(candidate);
        return systemName is null ? null : $"{candidate} 与 Windows 保留快捷键「{systemName}」冲突。";
    }

    public static string Occupied(Hotkey hotkey) => $"{hotkey} 已被 Windows 或其他程序占用。";

    private static string? ValidateKey(Hotkey hotkey)
    {
        if (hotkey.KeyName is null)
            return "不支持这个按键，请换一个。";

        const HotkeyModifiers strong = HotkeyModifiers.Control | HotkeyModifiers.Alt | HotkeyModifiers.Windows;
        if ((hotkey.Modifiers & strong) == 0 && !hotkey.IsFunctionKey)
            return "请包含 Ctrl 或 Alt，F1–F20 可以单独使用。";
        return null;
    }

    private static HashSet<Hotkey> CreateEditingShortcuts()
    {
        const HotkeyModifiers ctrl = HotkeyModifiers.Control;
        var keys = "ACVXZQWSNOPTFHM".Select(c => new Hotkey(c, ctrl)).ToHashSet();
        foreach (var code in new uint[] { 0xbc, 0xc0, 0x09, 0x20 })
            keys.Add(new Hotkey(code, ctrl));
        keys.Add(new Hotkey('Z', ctrl | HotkeyModifiers.Shift));
        keys.Add(new Hotkey('Y', ctrl));
        keys.Add(new Hotkey('V', ctrl | HotkeyModifiers.Shift));
        keys.Add(new Hotkey(0x09, ctrl | HotkeyModifiers.Shift));
        return keys;
    }

    private static string? SystemShortcutName(Hotkey hotkey)
    {
        const HotkeyModifiers alt = HotkeyModifiers.Alt, ctrl = HotkeyModifiers.Control, shift = HotkeyModifiers.Shift;
        if (hotkey.Modifiers.HasFlag(HotkeyModifiers.Windows))
            return "Win 组合键";
        if (hotkey.KeyCode == 0x7b)
            return "调试器（F12）";
        if (hotkey.KeyCode == 0x2c)
            return "系统截屏";

        return (hotkey.KeyCode, hotkey.Modifiers) switch
        {
            (0x09, alt) or (0x09, alt | shift) => "切换应用",
            (0x1b, alt) or (0x1b, alt | shift) => "循环切换窗口",
            (0x73, alt) => "关闭窗口",
            (0x20, alt) => "窗口菜单",
            (0x1b, ctrl) => "开始菜单",
            (0x1b, ctrl | shift) => "任务管理器",
            (0x2e, ctrl | alt) => "安全选项",
            _ => null
        };
    }
}
