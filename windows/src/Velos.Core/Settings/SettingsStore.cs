using System.Text.Json;
using Velos.Core.Hotkeys;

namespace Velos.Core.Settings;

public sealed class SettingsStore(string filePath)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };

    public (AppSettings Settings, string? Warning) Load()
    {
        try
        {
            using var input = File.OpenRead(filePath);
            var settings = JsonSerializer.Deserialize<AppSettings>(input, JsonOptions) ?? throw new JsonException();
            foreach (var action in Enum.GetValues<HotkeyAction>())
            {
                if (HotkeyConflicts.Validate(settings.GetHotkey(action), action, settings.GetHotkey) is not null)
                    return (new AppSettings
                    {
                        ShowTrayIcon = settings.ShowTrayIcon,
                        ScreenshotOptions = settings.ScreenshotOptions ?? new ScreenshotPreferences(),
                        RecordingOptions = settings.RecordingOptions ?? new RecordingPreferences(),
                        TranslationOptions = settings.TranslationOptions ?? new TranslationPreferences()
                    }, "保存的快捷键无效，已使用默认快捷键。");
            }
            return (settings with { ScreenshotOptions = settings.ScreenshotOptions ?? new ScreenshotPreferences(),
                RecordingOptions = settings.RecordingOptions ?? new RecordingPreferences(),
                TranslationOptions = settings.TranslationOptions ?? new TranslationPreferences() }, null);
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
        {
            return (new AppSettings(), null);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        {
            return (new AppSettings(), "无法读取设置，当前使用默认值。");
        }
    }

    public void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(filePath)!);
        var pendingPath = filePath + ".tmp";
        using (var output = File.Create(pendingPath))
        {
            JsonSerializer.Serialize(output, settings, JsonOptions);
            output.Flush(flushToDisk: true);
        }
        File.Move(pendingPath, filePath, overwrite: true);
    }
}
