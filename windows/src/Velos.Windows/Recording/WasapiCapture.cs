using System.Runtime.InteropServices;

namespace Velos.Windows.Recording;

public sealed record AudioDevice(string Id, string Name);
public sealed record AudioPacket(TimeSpan Time, float[] Stereo);

/// <summary>共享模式 WASAPI。系统音频使用 loopback，系统音频引擎统一重采样为 48kHz 双声道浮点。</summary>
public static unsafe class WasapiCapture
{
    private static readonly Guid EnumeratorClass = new("bcde0395-e52f-467c-8e3d-c4579291692e");
    private static readonly Guid EnumeratorInterface = new("a95664d2-9614-4f35-a746-de8db63617e6");
    private static readonly Guid AudioClientInterface = new("1cb9ad4c-dbfa-4c32-b178-c2f568a703b2");
    private static readonly Guid CaptureClientInterface = new("c8adbd64-e71e-48a0-a4de-185c395cd317");

    public static Task Run(bool loopback, string? deviceId, Action<AudioPacket> receive, CancellationToken cancellation) =>
        Task.Factory.StartNew(() => Capture(loopback, deviceId, receive, cancellation), cancellation, TaskCreationOptions.LongRunning, TaskScheduler.Default);

    public static Task<IReadOnlyList<AudioDevice>> Microphones() => Task.Run<IReadOnlyList<AudioDevice>>(() =>
    {
        Marshal.ThrowExceptionForHR(CoInitializeEx(0, 0));
        nint enumerator = 0, collection = 0;
        try
        {
            enumerator = CreateEnumerator();
            var enumerate = (delegate* unmanaged[Stdcall]<nint, int, uint, nint*, int>)Method(enumerator, 3);
            Marshal.ThrowExceptionForHR(enumerate(enumerator, 1, 1, &collection));
            uint count;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint*, int>)Method(collection, 3))(collection, &count));
            var devices = new List<AudioDevice>();
            var value = stackalloc byte[24];
            for (uint i = 0; i < count; i++)
            {
                nint device = 0, id = 0, properties = 0;
                try
                {
                    Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, nint*, int>)Method(collection, 4))(collection, i, &device));
                    Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, nint*, int>)Method(device, 5))(device, &id));
                    var identifier = Marshal.PtrToStringUni(id)!;
                    var name = "麦克风";
                    if (((delegate* unmanaged[Stdcall]<nint, uint, nint*, int>)Method(device, 4))(device, 0, &properties) >= 0)
                    {
                        var key = new PropertyKey { Format = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), Id = 14 };
                        new Span<byte>(value, 24).Clear();
                        try
                        {
                            if (((delegate* unmanaged[Stdcall]<nint, PropertyKey*, byte*, int>)Method(properties, 5))(properties, &key, value) >= 0 && *(ushort*)value == 31)
                                name = Marshal.PtrToStringUni(*(nint*)(value + 8)) ?? name;
                        }
                        finally { PropVariantClear(value); }
                    }
                    devices.Add(new(identifier, name));
                }
                finally { if (id != 0) Marshal.FreeCoTaskMem(id); Release(properties); Release(device); }
            }
            return devices;
        }
        finally { Release(collection); Release(enumerator); CoUninitialize(); }
    });

#if DEBUG
    public static Task DebugValidate(bool loopback) => Task.Factory.StartNew(() => Capture(loopback, null, _ => throw new InvalidOperationException("预检不应采集声音。"), CancellationToken.None, true),
        CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
#endif

    private static void Capture(bool loopback, string? deviceId, Action<AudioPacket> receive, CancellationToken cancellation, bool validateOnly = false)
    {
        Marshal.ThrowExceptionForHR(CoInitializeEx(0, 0));
        nint enumerator = 0, device = 0, client = 0, capture = 0;
        var started = false;
        using var ready = new AutoResetEvent(false);
        try
        {
            enumerator = CreateEnumerator();
            var status = -1;
            if (!string.IsNullOrWhiteSpace(deviceId))
            {
                fixed (char* id = deviceId)
                    status = ((delegate* unmanaged[Stdcall]<nint, char*, nint*, int>)Method(enumerator, 5))(enumerator, id, &device);
            }
            if (status < 0)
                Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, int, int, nint*, int>)Method(enumerator, 4))(enumerator, loopback ? 0 : 1, 1, &device));
            var iid = AudioClientInterface;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, Guid*, uint, nint, nint*, int>)Method(device, 3))(device, &iid, 23, 0, &client));
            var format = new WaveFormat { Tag = 3, Channels = 2, SampleRate = 48000, BytesPerSecond = 384000, Align = 8, Bits = 32 };
            const uint convertPcm = 0x80000000, quality = 0x08000000, eventCallback = 0x40000;
            var flags = convertPcm | quality | eventCallback | (loopback ? 0x20000u : 0);
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, int, uint, long, long, WaveFormat*, nint, int>)Method(client, 3))
                (client, 0, flags, 1_000_000, 0, &format, 0));
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, nint, int>)Method(client, 13))(client, ready.SafeWaitHandle.DangerousGetHandle()));
            iid = CaptureClientInterface;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)Method(client, 14))(client, &iid, &capture));
            if (validateOnly) return;
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, int>)Method(client, 10))(client));
            started = true;
            WaitHandle[] waits = [cancellation.WaitHandle, ready];
            while (WaitHandle.WaitAny(waits, 500) != 0)
            {
                if (cancellation.IsCancellationRequested) break;
                uint available;
                while (!cancellation.IsCancellationRequested)
                {
                    Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint*, int>)Method(capture, 5))(capture, &available));
                    if (available == 0) break;
                    nint data;
                    uint frames, bufferFlags;
                    ulong position, clock;
                    Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, nint*, uint*, uint*, ulong*, ulong*, int>)Method(capture, 3))
                        (capture, &data, &frames, &bufferFlags, &position, &clock));
                    try
                    {
                        var samples = new float[checked((int)frames * 2)];
                        if ((bufferFlags & 2) == 0 && data != 0) Marshal.Copy(data, samples, 0, samples.Length);
                        var time = (bufferFlags & 4) == 0 ? TimeSpan.FromTicks(checked((long)clock)) :
                            TimeSpan.FromSeconds((double)System.Diagnostics.Stopwatch.GetTimestamp() / System.Diagnostics.Stopwatch.Frequency - frames / 48000d);
                        receive(new(time, samples));
                    }
                    finally { Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, int>)Method(capture, 4))(capture, frames)); }
                }
            }
        }
        finally
        {
            if (started) ((delegate* unmanaged[Stdcall]<nint, int>)Method(client, 11))(client);
            Release(capture); Release(client); Release(device); Release(enumerator);
            CoUninitialize();
        }
    }

    private static nint CreateEnumerator()
    {
        Marshal.ThrowExceptionForHR(CoCreateInstance(in EnumeratorClass, 0, 23, in EnumeratorInterface, out var result));
        return result;
    }
    private static void Release(nint value) { if (value != 0) Marshal.Release(value); }
    private static nint Method(nint instance, int index) => (*(nint**)instance)[index];
    [StructLayout(LayoutKind.Sequential)] private struct PropertyKey { public Guid Format; public uint Id; }
    [StructLayout(LayoutKind.Sequential, Pack = 2)] private struct WaveFormat
    { public ushort Tag, Channels; public uint SampleRate, BytesPerSecond; public ushort Align, Bits, Extra; }
    [DllImport("ole32.dll")] private static extern int CoInitializeEx(nint reserved, uint apartment);
    [DllImport("ole32.dll")] private static extern void CoUninitialize();
    [DllImport("ole32.dll")] private static extern int CoCreateInstance(in Guid clsid, nint outer, uint context, in Guid iid, out nint result);
    [DllImport("ole32.dll")] private static extern int PropVariantClear(byte* value);
}
