using System.Globalization;
using System.Text.Json.Serialization;

namespace Velos.Core.Hotkeys;

[Flags]
public enum HotkeyModifiers : uint
{
    None = 0,
    Alt = 1,
    Control = 2,
    Shift = 4,
    Windows = 8
}

public enum HotkeyAction
{
    Screenshot,
    Recording,
    Translation
}

public readonly record struct Hotkey
{
    private const HotkeyModifiers ModifierMask = HotkeyModifiers.Alt | HotkeyModifiers.Control |
        HotkeyModifiers.Shift | HotkeyModifiers.Windows;

    [JsonConstructor]
    public Hotkey(uint keyCode, HotkeyModifiers modifiers)
    {
        KeyCode = keyCode;
        Modifiers = modifiers & ModifierMask;
    }

    public uint KeyCode { get; }
    public HotkeyModifiers Modifiers { get; }

    [JsonIgnore]
    public bool IsFunctionKey => KeyCode is >= 0x70 and <= 0x83;

    [JsonIgnore]
    public string? KeyName => KeyCode switch
    {
        >= 'A' and <= 'Z' or >= '0' and <= '9' => ((char)KeyCode).ToString(),
        >= 0x60 and <= 0x69 => $"小键盘 {(KeyCode - 0x60).ToString(CultureInfo.InvariantCulture)}",
        >= 0x70 and <= 0x83 => $"F{(KeyCode - 0x6f).ToString(CultureInfo.InvariantCulture)}",
        0x08 => "Backspace",
        0x09 => "Tab",
        0x0d => "Enter",
        0x1b => "Esc",
        0x20 => "空格",
        0x21 => "Page Up",
        0x22 => "Page Down",
        0x23 => "End",
        0x24 => "Home",
        0x25 => "←",
        0x26 => "↑",
        0x27 => "→",
        0x28 => "↓",
        0x2c => "Print Screen",
        0x2d => "Insert",
        0x2e => "Delete",
        0xba => ";",
        0xbb => "=",
        0xbc => ",",
        0xbd => "-",
        0xbe => ".",
        0xbf => "/",
        0xc0 => "`",
        0xdb => "[",
        0xdc => "\\",
        0xdd => "]",
        0xde => "'",
        _ => null
    };

    public static Hotkey Default(HotkeyAction action) => action switch
    {
        HotkeyAction.Screenshot => new Hotkey('A', HotkeyModifiers.Alt),
        HotkeyAction.Recording => new Hotkey('S', HotkeyModifiers.Alt),
        HotkeyAction.Translation => new Hotkey('D', HotkeyModifiers.Alt),
        _ => throw new ArgumentOutOfRangeException(nameof(action))
    };

    public static string Title(HotkeyAction action) => action switch
    {
        HotkeyAction.Screenshot => "截图",
        HotkeyAction.Recording => "录屏",
        HotkeyAction.Translation => "截屏翻译",
        _ => throw new ArgumentOutOfRangeException(nameof(action))
    };

    public override string ToString()
    {
        var keys = new List<string>(5);
        if (Modifiers.HasFlag(HotkeyModifiers.Control)) keys.Add("Ctrl");
        if (Modifiers.HasFlag(HotkeyModifiers.Alt)) keys.Add("Alt");
        if (Modifiers.HasFlag(HotkeyModifiers.Shift)) keys.Add("Shift");
        if (Modifiers.HasFlag(HotkeyModifiers.Windows)) keys.Add("Win");
        keys.Add(KeyName ?? "未知按键");
        return string.Join("+", keys);
    }
}
