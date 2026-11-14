using System.Drawing;
using System.Runtime.InteropServices;
using Velos.Core.Recording;
using Velos.Core.Settings;

namespace Velos.Windows.Recording;

internal sealed unsafe class FoundationWriter : IDisposable
{
    private static readonly Guid MajorType = new("48eba18e-f8c9-4687-bf11-0a74c9f96a8f");
    private static readonly Guid Subtype = new("f7e34c9a-42e8-4714-b74b-cb29d72c35e5");
    private static readonly Guid VideoMajor = new("73646976-0000-0010-8000-00aa00389b71");
    private static readonly Guid AudioMajor = new("73647561-0000-0010-8000-00aa00389b71");
    private static readonly Guid H264 = new("34363248-0000-0010-8000-00aa00389b71");
    private static readonly Guid Hevc = new("43564548-0000-0010-8000-00aa00389b71");
    private static readonly Guid Rgb32 = new("00000016-0000-0010-8000-00aa00389b71");
    private static readonly Guid Aac = new("00001610-0000-0010-8000-00aa00389b71");
    private static readonly Guid Pcm = new("00000001-0000-0010-8000-00aa00389b71");
    private static readonly Guid FrameSize = new("1652c33d-d6b2-4012-b834-72030849a37d");
    private static readonly Guid FrameRate = new("c459a2e8-3d2c-4e44-b132-fee5156c7bb0");
    private static readonly Guid PixelAspect = new("c6376a1e-8d0a-4027-be45-6d9a0ad39bb6");
    private static readonly Guid Interlace = new("e2724bb8-e676-4806-b4b2-a8d6efb44ccd");
    private static readonly Guid BitRate = new("20332624-fb0d-4d9e-bd0d-cbf6786c102e");
    private static readonly Guid Stride = new("644b4e48-1e02-4516-b0eb-c01ca9d49ac6");
    private static readonly Guid Channels = new("37e48bf5-645e-4c5b-89de-ada9e29b696a");
    private static readonly Guid SampleRate = new("5faeeae7-0290-4c31-9e8a-c534f68d9dba");
    private static readonly Guid AudioBits = new("f2deb57f-40fa-4764-aa33-ed4f2d1ff669");
    private static readonly Guid ByteRate = new("1aab75c8-cfef-451c-ab95-ac034b8e1731");
    private static readonly Guid BlockAlign = new("322de230-9eeb-43bd-ab7a-ff412251541d");
    private nint writer;
    private uint videoStream, audioStream;
    private readonly bool withAudio;
    private bool platformStarted;
    private bool comStarted;
    public VideoCodec ActualCodec { get; private set; }

    public FoundationWriter(string path, Size input, Size output, RecordingPreferences options, bool withAudio)
    {
        this.withAudio = withAudio;
        try
        {
            Marshal.ThrowExceptionForHR(CoInitializeEx(0, 0));
            comStarted = true;
            Marshal.ThrowExceptionForHR(MFStartup(0x20070, 0));
            platformStarted = true;
            ActualCodec = options.Codec;
            try { Configure(path, input, output, options); }
            catch (COMException) when (options.Codec == VideoCodec.Hevc)
            {
                Release(writer);
                writer = 0;
                ActualCodec = VideoCodec.H264;
                Configure(path, input, output, options);
            }
        }
        catch { Dispose(); throw; }
    }

    private void Configure(string path, Size input, Size output, RecordingPreferences options)
    {
        nint attributes = 0, video = 0, rawVideo = 0, audio = 0, rawAudio = 0;
        try
        {
            Marshal.ThrowExceptionForHR(MFCreateAttributes(out attributes, 3));
            SetGuid(attributes, new("150ff23f-4abc-478b-ac4f-e1916fba1cca"), new("dc6cd05d-b9d0-40ef-bd35-fa622c1ab28a"));
            Set32(attributes, new("a634a91c-822b-41b9-a494-4de4643612b0"), 1);
            Set32(attributes, new("08b845d8-2b74-4afe-9d53-be16d2d5ae4f"), 1);
            Marshal.ThrowExceptionForHR(MFCreateSinkWriterFromURL(Path.GetFullPath(path), 0, attributes, out writer));
            video = VideoType(output, options.FrameRate, ActualCodec == VideoCodec.Hevc ? Hevc : H264);
            Set32(video, BitRate, RecordingGeometry.BitRate(output, options.FrameRate, ActualCodec, options.Quality));
            var stream = 0u;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, nint, uint*, int>)Method(writer, 3))(writer, video, &stream));
            videoStream = stream;
            rawVideo = VideoType(input, options.FrameRate, Rgb32);
            Set32(rawVideo, Stride, unchecked((uint)(input.Width * 4)));
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, nint, nint, int>)Method(writer, 4))(writer, videoStream, rawVideo, 0));
            if (withAudio)
            {
                audio = AudioType(Aac);
                Set32(audio, ByteRate, 32_000);
                Set32(audio, AudioBits, 16);
                Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, nint, uint*, int>)Method(writer, 3))(writer, audio, &stream));
                audioStream = stream;
                rawAudio = AudioType(Pcm);
                Set32(rawAudio, AudioBits, 16);
                Set32(rawAudio, BlockAlign, 4);
                Set32(rawAudio, ByteRate, StereoMixer.SampleRate * 4);
                Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, nint, nint, int>)Method(writer, 4))(writer, audioStream, rawAudio, 0));
            }
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, int>)Method(writer, 5))(writer));
        }
        finally { Release(rawAudio); Release(audio); Release(rawVideo); Release(video); Release(attributes); }
    }

    public void Write(bool video, MediaPacket packet)
    {
        if (!video && !withAudio) return;
        nint sample = 0, buffer = 0;
        try
        {
            Marshal.ThrowExceptionForHR(MFCreateMemoryBuffer((uint)packet.Bytes.Length, out buffer));
            nint data;
            uint maximum, length;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, nint*, uint*, uint*, int>)Method(buffer, 3))(buffer, &data, &maximum, &length));
            try { Marshal.Copy(packet.Bytes, 0, data, packet.Bytes.Length); }
            finally { Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, int>)Method(buffer, 4))(buffer)); }
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, int>)Method(buffer, 6))(buffer, (uint)packet.Bytes.Length));
            Marshal.ThrowExceptionForHR(MFCreateSample(out sample));
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, nint, int>)Method(sample, 42))(sample, buffer));
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, long, int>)Method(sample, 36))(sample, packet.Time.Ticks));
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, long, int>)Method(sample, 38))(sample, packet.Duration.Ticks));
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, nint, int>)Method(writer, 6))(writer, video ? videoStream : audioStream, sample));
        }
        finally { Release(sample); Release(buffer); }
    }

    public void Complete() => Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, int>)Method(writer, 11))(writer));

    private static nint VideoType(Size size, int fps, Guid subtype)
    {
        Marshal.ThrowExceptionForHR(MFCreateMediaType(out var type));
        try
        {
            SetGuid(type, MajorType, VideoMajor); SetGuid(type, Subtype, subtype);
            Set64(type, FrameSize, ((ulong)size.Width << 32) | (uint)size.Height);
            Set64(type, FrameRate, ((ulong)(fps == 30 ? 30 : 60) << 32) | 1);
            Set64(type, PixelAspect, (1UL << 32) | 1);
            Set32(type, Interlace, 2);
            return type;
        }
        catch { Release(type); throw; }
    }

    private static nint AudioType(Guid subtype)
    {
        Marshal.ThrowExceptionForHR(MFCreateMediaType(out var type));
        try
        {
            SetGuid(type, MajorType, AudioMajor); SetGuid(type, Subtype, subtype);
            Set32(type, Channels, 2); Set32(type, SampleRate, StereoMixer.SampleRate);
            return type;
        }
        catch { Release(type); throw; }
    }

    private static void Set32(nint target, Guid key, uint value) =>
        Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, Guid*, uint, int>)Method(target, 21))(target, &key, value));
    private static void Set64(nint target, Guid key, ulong value) =>
        Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, Guid*, ulong, int>)Method(target, 22))(target, &key, value));
    private static void SetGuid(nint target, Guid key, Guid value) =>
        Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, Guid*, Guid*, int>)Method(target, 24))(target, &key, &value));
    private static nint Method(nint instance, int index) => (*(nint**)instance)[index];
    private static void Release(nint value) { if (value != 0) Marshal.Release(value); }

    public void Dispose()
    {
        Release(writer); writer = 0;
        if (platformStarted) { MFShutdown(); platformStarted = false; }
        if (comStarted) { CoUninitialize(); comStarted = false; }
    }

    [DllImport("ole32.dll")] private static extern int CoInitializeEx(nint reserved, uint apartment);
    [DllImport("ole32.dll")] private static extern void CoUninitialize();
    [DllImport("mfplat.dll")] private static extern int MFStartup(uint version, uint flags);
    [DllImport("mfplat.dll")] private static extern int MFShutdown();
    [DllImport("mfplat.dll")] private static extern int MFCreateAttributes(out nint attributes, uint initialSize);
    [DllImport("mfplat.dll")] private static extern int MFCreateMediaType(out nint type);
    [DllImport("mfplat.dll")] private static extern int MFCreateSample(out nint sample);
    [DllImport("mfplat.dll")] private static extern int MFCreateMemoryBuffer(uint size, out nint buffer);
    [DllImport("mfreadwrite.dll", CharSet = CharSet.Unicode)] private static extern int MFCreateSinkWriterFromURL(string url, nint stream, nint attributes, out nint writer);
}
