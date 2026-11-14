using Microsoft.Win32;

namespace Velos.Windows;

public sealed class LaunchAtLogin(string valueName)
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private readonly string command = $"\"{Environment.ProcessPath}\" --login";

    public bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        var savedCommand = key?.GetValue(valueName) as string;
        return string.Equals(savedCommand, command, StringComparison.OrdinalIgnoreCase);
    }

    public void SetEnabled(bool enabled)
    {
        if (enabled)
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            key.SetValue(valueName, command, RegistryValueKind.String);
        }
        else
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            key?.DeleteValue(valueName, throwOnMissingValue: false);
        }
    }
}
