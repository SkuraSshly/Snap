using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using Velos.Core.Translation;

namespace Velos.Windows.Translation;

// NLLanguageRecognizer 的 Windows 适配；ELS 在本机检测拉丁文字语种，不再一律当英语。
// https://learn.microsoft.com/windows/win32/intl/microsoft-language-detection
internal static class LanguageDetector
{
    private static readonly Lazy<Service> detector = new(CreateService);
    public static TranslateLanguage? Detect(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var normalized = text.Normalize(NormalizationForm.FormC);
        if (normalized.Length > 8192) normalized = normalized[..8192];
        try
        {
            var service = detector.Value; if (service.IsInvalid) return null;
            var pinned = GCHandle.Alloc(normalized, GCHandleType.Pinned); var added = false;
            try
            {
                service.DangerousAddRef(ref added);
                var bag = new PropertyBag { Size = (nuint)Marshal.SizeOf<PropertyBag>() };
                if (MappingRecognizeText(service.DangerousGetHandle(), pinned.AddrOfPinnedObject(), (uint)normalized.Length, 0, 0, ref bag) != 0) return null;
                try
                {
                    if (bag.Count == 0 || bag.Ranges == 0) return null;
                    var range = Marshal.PtrToStructure<DataRange>(bag.Ranges);
                    if (range.Data == 0 || range.DataSize is < 2 or > 65536) return null;
                    var names = Marshal.PtrToStringUni(range.Data, (int)range.DataSize / 2)?.Split('\0', StringSplitOptions.RemoveEmptyEntries) ?? [];
                    return names.Select(TranslateLanguage.FromLocale).FirstOrDefault(language => language is not null);
                }
                finally { MappingFreePropertyBag(ref bag); }
            }
            finally { if (added) service.DangerousRelease(); pinned.Free(); }
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException or ExternalException) { return null; }
    }
    private static Service CreateService()
    {
        var guid = Marshal.AllocHGlobal(16);
        try
        {
            Marshal.StructureToPtr(new Guid("cf7e00b1-909b-4d95-a8f4-611f7c377702"), guid, false);
            var options = new EnumOptions { Size = (nuint)Marshal.SizeOf<EnumOptions>(), Guid = guid };
            var result = MappingGetServices(ref options, out var pointer, out var count);
            if (result == 0 && count > 0) return new Service(pointer);
            if (pointer != 0) MappingFreeServices(pointer);
            return new Service(0);
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException) { return new Service(0); }
        finally { Marshal.FreeHGlobal(guid); }
    }
    private sealed class Service : SafeHandleZeroOrMinusOneIsInvalid
    {
        public Service(nint pointer) : base(true) => SetHandle(pointer);
        protected override bool ReleaseHandle() => MappingFreeServices(handle) == 0;
    }
    [StructLayout(LayoutKind.Sequential)] private struct EnumOptions
    { public nuint Size; public nint Category, InputLanguage, OutputLanguage, InputScript, OutputScript, InputType, OutputType, Guid; public uint Flags; }
    [StructLayout(LayoutKind.Sequential)] private struct PropertyBag
    { public nuint Size; public nint Ranges; public uint Count; public nint ServiceData; public uint ServiceSize; public nint CallerData; public uint CallerSize; public nint Context; }
    [StructLayout(LayoutKind.Sequential)] private struct DataRange
    { public uint Start, End; public nint Description; public uint DescriptionLength; public nint Data; public uint DataSize; public nint ContentType, ActionIds; public uint ActionCount; public nint ActionNames; }
    [DllImport("elscore.dll")] private static extern int MappingGetServices(ref EnumOptions options, out nint services, out uint count);
    [DllImport("elscore.dll")] private static extern int MappingFreeServices(nint services);
    [DllImport("elscore.dll")] private static extern int MappingRecognizeText(nint service, nint text, uint length, uint index, nint options, ref PropertyBag bag);
    [DllImport("elscore.dll")] private static extern int MappingFreePropertyBag(ref PropertyBag bag);
}
