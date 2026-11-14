namespace Velos.Core.Settings;

public enum VideoCodec { Hevc, H264 }
public enum VideoQuality { High, Ultra }
public enum RecordingResolution { Native, P1080 }

public sealed record RecordingPreferences
{
    public string? Directory { get; init; }
    public RecordingResolution Resolution { get; init; }
    public int FrameRate { get; init; } = 60;
    public VideoCodec Codec { get; init; }
    public VideoQuality Quality { get; init; }
    public bool SystemAudio { get; init; } = true;
    public bool Microphone { get; init; }
    public string? MicrophoneId { get; init; }
    public bool ShowCursor { get; init; } = true;
    public bool Countdown { get; init; }
    public bool HighlightClicks { get; init; }
    public bool Thumbnail { get; init; } = true;
    public int GifFrameRate { get; init; } = 15;
    public int GifMaxWidth { get; init; } = 960;
}
