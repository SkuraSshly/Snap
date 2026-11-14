using System.Buffers.Binary;
using Velos.Core.Recording;
using Velos.Core.Settings;

internal static class RecordingTests
{
    public static (string Name, Action Run)[] Cases(Action<bool, string> check) =>
    [
        ("录屏原生分辨率只裁掉奇数边缘", () => check(RecordingGeometry.OutputSize(new(3841, 2161), RecordingResolution.Native) == new System.Drawing.Size(3840, 2160), "原生像素")),
        ("1080p 录屏按比例缩小且保持偶数", () => check(RecordingGeometry.OutputSize(new(3840, 2160), RecordingResolution.P1080) == new System.Drawing.Size(1920, 1080), "1080p")),
        ("录屏码率按 Mac 系数计算并限幅", () =>
        {
            check(RecordingGeometry.BitRate(new(1920, 1080), 60, VideoCodec.H264, VideoQuality.High) == 13_685_760, "H.264 高画质");
            check(RecordingGeometry.BitRate(new(100, 100), 30, VideoCodec.Hevc, VideoQuality.High) == 4_000_000, "最小码率");
        }),
        ("暂停区间从音画时间线中扣除", () =>
        {
            var timeline = new RecordingTimeline();
            timeline.Start(TimeSpan.FromSeconds(10));
            timeline.Pause(TimeSpan.FromSeconds(12));
            check(timeline.Adjusted(TimeSpan.FromSeconds(13)) is null, "丢弃暂停内数据");
            check(timeline.Elapsed(TimeSpan.FromSeconds(20)) == TimeSpan.FromSeconds(2), "暂停时计时冻结");
            timeline.Resume(TimeSpan.FromSeconds(15));
            check(timeline.Adjusted(TimeSpan.FromSeconds(16)) == TimeSpan.FromSeconds(3), "扣除暂停");
            check(timeline.Adjusted(TimeSpan.FromSeconds(14)) is null, "迟到的暂停样本丢弃");
        }),
        ("双声源混音削波与麦克风静音", () =>
        {
            var mixer = new StereoMixer();
            mixer.Add(0, 0, [0.8f, -0.8f]); mixer.Add(1, 0, [0.8f, -0.8f]);
            var pcm = mixer.Read(0, 1, false);
            check(BinaryPrimitives.ReadInt16LittleEndian(pcm) == 32767 && BinaryPrimitives.ReadInt16LittleEndian(pcm.AsSpan(2)) == -32767, "削波");
            mixer.Add(0, 1, [0.5f, 0.5f]); mixer.Add(1, 1, [0.5f, 0.5f]);
            check(BinaryPrimitives.ReadInt16LittleEndian(mixer.Read(1, 1, true)) == 16384, "麦克风静音");
        }),
        ("GIF 首帧完整且相同帧延长停留时间", () =>
        {
            var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".gif");
            using var encoder = new GifEncoder(path, 16, 12);
            var pixels = Enumerable.Repeat(0xff996633u, 16 * 12).ToArray();
            encoder.Add(pixels, 0); encoder.Add(pixels, 0.1);
            for (var y = 3; y < 7; y++) for (var x = 3; x < 7; x++) pixels[y * 16 + x] = 0xffff0000;
            encoder.Add(pixels, 0.2); encoder.Finish(0.4);
            var bytes = File.ReadAllBytes(path);
            check(encoder.FramesWritten == 2 && bytes.AsSpan(0, 6).SequenceEqual("GIF89a"u8) && bytes[^1] == 0x3b, "GIF 格式");
            check(BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(6)) == 16 && BinaryPrimitives.ReadUInt16LittleEndian(bytes.AsSpan(8)) == 12, "尺寸");
            check(bytes[36] == 20, "首帧延时 0.2 秒");
        })
    ];
}
