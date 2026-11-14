using Velos.Core.Hotkeys;

namespace Velos.Core.Settings;

public sealed record AppSettings
{
    public bool HasCompletedWelcome { get; init; }
    public bool ShowTrayIcon { get; init; } = true;
    public Hotkey Screenshot { get; init; } = Hotkey.Default(HotkeyAction.Screenshot);
    public Hotkey Recording { get; init; } = Hotkey.Default(HotkeyAction.Recording);
    public Hotkey Translation { get; init; } = Hotkey.Default(HotkeyAction.Translation);
    public ScreenshotPreferences ScreenshotOptions { get; init; } = new();
    public RecordingPreferences RecordingOptions { get; init; } = new();
    public TranslationPreferences TranslationOptions { get; init; } = new();

    public Hotkey GetHotkey(HotkeyAction action) => action switch
    {
        HotkeyAction.Screenshot => Screenshot,
        HotkeyAction.Recording => Recording,
        HotkeyAction.Translation => Translation,
        _ => throw new ArgumentOutOfRangeException(nameof(action))
    };

    public AppSettings WithHotkey(HotkeyAction action, Hotkey value) => action switch
    {
        HotkeyAction.Screenshot => this with { Screenshot = value },
        HotkeyAction.Recording => this with { Recording = value },
        HotkeyAction.Translation => this with { Translation = value },
        _ => throw new ArgumentOutOfRangeException(nameof(action))
    };
}
