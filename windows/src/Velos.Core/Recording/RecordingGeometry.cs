using System.Drawing;
using Velos.Core.Settings;

namespace Velos.Core.Recording;

public static class RecordingGeometry
{
    public static Size OutputSize(Size native, RecordingResolution resolution)
    {
        var width = native.Width & ~1;
        var height = native.Height & ~1;
        if (width < 2 || height < 2) throw new ArgumentException("录制区域至少需要 2×2 像素。");
        if (resolution == RecordingResolution.P1080 && (width > 1920 || height > 1080))
        {
            var scale = Math.Min(1920d / width, 1080d / height);
            width = Math.Max(2, (int)(width * scale) & ~1);
            height = Math.Max(2, (int)(height * scale) & ~1);
        }
        return new Size(width, height);
    }

    public static uint BitRate(Size size, int fps, VideoCodec codec, VideoQuality quality)
    {
        var coefficient = codec == VideoCodec.Hevc ? 0.07 : 0.11;
        if (quality == VideoQuality.Ultra) coefficient *= 2;
        return (uint)Math.Clamp((double)size.Width * size.Height * fps * coefficient, 4_000_000, 160_000_000);
    }

    public static string Clock(TimeSpan duration) => duration.TotalHours >= 1
        ? $"{(int)duration.TotalHours}:{duration.Minutes:00}:{duration.Seconds:00}"
        : $"{(int)duration.TotalMinutes:00}:{duration.Seconds:00}";
}
