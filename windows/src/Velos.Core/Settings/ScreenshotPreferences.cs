namespace Velos.Core.Settings;

public enum ScreenshotFormat { Png, Jpeg, Heic }

public sealed record ScreenshotPreferences
{
    public double ScreenshotCornerRadius { get; init; }
    public string? Directory { get; init; }
    public ScreenshotFormat Format { get; init; }
    public int Quality { get; init; } = 90;
    public bool IncludeCursor { get; init; }
    public bool Downscale { get; init; }
    public bool Copy { get; init; } = true;
    public bool AutoSave { get; init; }
    public bool Thumbnail { get; init; } = true;
    public bool DismissOnPaste { get; init; } = true;
    public Dictionary<string, ToolStyle>? ToolStyles { get; init; }
}

public sealed record ToolStyle(uint Rgb, int Size, double Opacity = 1, bool Filled = false);
