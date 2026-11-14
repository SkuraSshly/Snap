using System.Globalization;

namespace Velos.Core.Screenshot;

public readonly record struct AnnotationColor(uint Rgb, double? Opacity);

/// <summary>对应 Annotation/ColorPicker.swift 的 ColorCode；八位十六进制末尾为 alpha。</summary>
public static class AnnotationColorCode
{
    public static AnnotationColor? Parse(string text)
    {
        var code = text.Trim().ToLowerInvariant();
        if (code.StartsWith("rgb", StringComparison.Ordinal))
        {
            var open = code.IndexOf('('); var close = code.LastIndexOf(')');
            if (open < 0 || close <= open) return null;
            var pieces = code[(open + 1)..close].Split(',');
            if (pieces.Length is not (3 or 4)) return null;
            var values = new double[pieces.Length];
            for (var i = 0; i < values.Length; i++)
                if (!double.TryParse(pieces[i].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out values[i]) ||
                    !double.IsFinite(values[i]) || values[i] < 0 || values[i] > (i == 3 ? 1 : 255)) return null;
            uint Channel(int i) => (uint)Math.Round(values[i], MidpointRounding.AwayFromZero);
            return new AnnotationColor(Channel(0) << 16 | Channel(1) << 8 | Channel(2), values.Length == 4 ? values[3] : null);
        }
        if (code.StartsWith('#')) code = code[1..]; else if (code.StartsWith("0x", StringComparison.Ordinal)) code = code[2..];
        if (code.Length == 3) code = string.Concat(code.Select(c => new string(c, 2)));
        if (code.Length is not (6 or 8) || code.Any(c => !char.IsAsciiHexDigit(c)) || !uint.TryParse(code, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var hex)) return null;
        return code.Length == 8 ? new AnnotationColor(hex >> 8, (hex & 255) / 255d) : new AnnotationColor(hex, null);
    }
    public static string Hex(uint rgb) => $"#{rgb & 0xffffff:X6}";
}
