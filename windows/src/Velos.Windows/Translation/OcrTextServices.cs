using System.Globalization;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using Windows.Data.Text;
using Velos.Core.Translation;

namespace Velos.Windows.Translation;

// AppKit/NaturalLanguage 的字体测量、拼写及分词适配；仅在 OCR 工作进程排版时存在。
internal sealed class OcrTextServices : IDisposable
{
    private readonly nint dc, font, previous;
    private readonly Dictionary<string, double> widths = [];
    private readonly Dictionary<string, bool> spellings = [];
    private readonly WordsSegmenter? segmenter;
    private IChecker? checker;
    public OcrTextServices(TranslateLanguage? language)
    {
        dc = CreateCompatibleDC(0); font = CreateFont(-13, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, "Segoe UI");
        if (dc != 0 && font != 0) previous = SelectObject(dc, font);
        try { segmenter = new WordsSegmenter(language?.Code ?? "en"); } catch (Exception error) when (error is ArgumentException or COMException) { }
        object? factory = null;
        try
        {
            factory = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("7ab36653-1796-484b-bdfa-e74f1db7c1dc"))!);
            if (factory is IFactory native) {
                var culture = language is null ? "en-US" : language.Code == "zh-Hans" ? "zh-CN" : language.Code == "zh-Hant" ? "zh-TW" : CultureInfo.CreateSpecificCulture(language.Code).Name;
                if (native.IsSupported(culture, out var supported) == 0 && supported) native.CreateSpellChecker(culture, out checker);
            }
        }
        catch (Exception error) when (error is COMException or ArgumentException or TypeLoadException) { }
        finally { if (factory is not null && Marshal.IsComObject(factory)) Marshal.ReleaseComObject(factory); }
    }
    public double Measure13(string text)
    {
        if (widths.TryGetValue(text, out var cached)) return cached;
        var result = dc != 0 && GetTextExtentPoint32(dc, text, text.Length, out var size) ? size.Width : new StringInfo(text).LengthInTextElements * 7d;
        widths[text] = result; return result;
    }
    public bool Spelled(string text)
    {
        if (spellings.TryGetValue(text, out var cached)) return cached;
        var correct = false; IErrors? errors = null; nint error = 0;
        try { if (text.Length > 0 && checker?.Check(text, out errors) == 0 && errors is not null) correct = errors.Next(out error) == 1; }
        catch (COMException) { }
        finally { if (error != 0) Marshal.Release(error); if (errors is not null) Marshal.ReleaseComObject(errors); }
        spellings[text] = correct; return correct;
    }
    public int CountWords(string text)
    {
        try { if (segmenter is not null) return segmenter.GetTokens(text).Count(word => word.Text.Any(char.IsLetterOrDigit) && !word.Text.Any(char.IsPunctuation)); }
        catch (Exception error) when (error is ArgumentException or COMException) { }
        return System.Text.RegularExpressions.Regex.Matches(text, @"[\p{L}\p{N}]+").Count;
    }
    public void Dispose()
    {
        if (checker is not null) { Marshal.ReleaseComObject(checker); checker = null; }
        if (dc != 0) { if (previous != 0) SelectObject(dc, previous); DeleteDC(dc); }
        if (font != 0) DeleteObject(font);
    }
    [ComImport, Guid("8e018a9d-2415-4677-bf08-794ea61f94bb"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface IFactory
    {
        [PreserveSig] int SupportedLanguages(out IEnumString languages);
        [PreserveSig] int IsSupported([MarshalAs(UnmanagedType.LPWStr)] string language, [MarshalAs(UnmanagedType.Bool)] out bool supported);
        [PreserveSig] int CreateSpellChecker([MarshalAs(UnmanagedType.LPWStr)] string language, out IChecker checker);
    }
    [ComImport, Guid("b6fd0b71-e2bc-4653-8d05-f197e412770b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface IChecker
    {
        [PreserveSig] int Language(out nint language);
        [PreserveSig] int Check([MarshalAs(UnmanagedType.LPWStr)] string text, out IErrors errors);
    }
    [ComImport, Guid("803e3bd4-2828-4410-8290-418d1d73c762"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)] private interface IErrors
    { [PreserveSig] int Next(out nint error); }
    [StructLayout(LayoutKind.Sequential)] private struct Extent { public int Width, Height; }
    [DllImport("gdi32.dll")] private static extern nint CreateCompatibleDC(nint source);
    [DllImport("gdi32.dll", EntryPoint = "CreateFontW", CharSet = CharSet.Unicode)] private static extern nint CreateFont(int height, int width, int angle, int orientation, int weight, uint italic, uint underline, uint strike, uint charset, uint precision, uint clipping, uint quality, uint pitch, string name);
    [DllImport("gdi32.dll")] private static extern nint SelectObject(nint dc, nint value);
    [DllImport("gdi32.dll", EntryPoint = "GetTextExtentPoint32W", CharSet = CharSet.Unicode)] private static extern bool GetTextExtentPoint32(nint dc, string text, int count, out Extent extent);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(nint dc);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint value);
}
