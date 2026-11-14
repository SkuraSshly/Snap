using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace Velos.UI;

internal static class WarmTheme
{
    public static readonly FontFamily Icons = new(OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) &&
        Fonts.SystemFontFamilies.Any(font => font.Source == "Segoe Fluent Icons")
        ? "Segoe Fluent Icons" : "Segoe MDL2 Assets");
    public static readonly FontFamily Text = new(OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)
        ? "Segoe UI Variable Text, Microsoft YaHei UI" : "Segoe UI, Microsoft YaHei UI");
    public static readonly SolidColorBrush Apricot = Brush(245, 148, 92);
    public static readonly SolidColorBrush Coral = Brush(237, 94, 77);
    private static readonly FloatingPalette Light = new(false);
    private static readonly FloatingPalette Dark = new(true);
    private static readonly Dictionary<string, BitmapImage> Images = [];
    private const string Personalize = @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

    public static bool IsDark { get; private set; }
    public static FloatingPalette Floating => IsDark ? Dark : Light;

    public static void Refresh()
    {
        IsDark = Registry.GetValue(Personalize, "AppsUseLightTheme", 1) is 0;
        RefreshMenus();
    }
    private static void RefreshMenus()
    {
        if (Application.Current is not { } app) return;
        app.Resources["MenuFont"] = Text;
        app.Resources["MenuInk"] = SystemParameters.HighContrast ? SystemColors.MenuTextBrush : Floating.Ink;
        app.Resources["MenuSurface"] = SystemParameters.HighContrast ? SystemColors.MenuBrush : Floating.Paper;
        app.Resources["MenuLine"] = SystemParameters.HighContrast ? SystemColors.MenuTextBrush : Floating.Outline;
        app.Resources["MenuHover"] = SystemParameters.HighContrast ? SystemColors.HighlightBrush : Floating.Hover;
        app.Resources["MenuHoverInk"] = SystemParameters.HighContrast ? SystemColors.HighlightTextBrush : Floating.Ink;
    }
    public static bool DarkTaskbar() => Registry.GetValue(Personalize, "SystemUsesLightTheme", 1) is 0;

    public static BitmapImage Image(string asset)
    {
        if (!Images.TryGetValue(asset, out var image))
        {
            image = new BitmapImage(ResourceUri(asset));
            image.Freeze();
            Images.Add(asset, image);
        }
        return image;
    }

    public static byte[] ImageBytes(string asset)
    {
        using var input = Application.GetResourceStream(ResourceUri(asset)).Stream;
        using var output = new MemoryStream();
        input.CopyTo(output);
        return output.ToArray();
    }

    private static Uri ResourceUri(string asset) => new($"pack://application:,,,/Assets/Shared/{asset}.png");

    public static TextBlock Glyph(string glyph, double size) =>
        new() { Text = glyph, FontFamily = Icons, FontSize = size, HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center };

    public static SolidColorBrush Brush(byte red, byte green, byte blue, byte alpha = 255)
    {
        var brush = new SolidColorBrush(Color.FromArgb(alpha, red, green, blue));
        brush.Freeze();
        return brush;
    }

    public static RadialGradientBrush Glow(byte red, byte green, byte blue, byte alpha)
    {
        var brush = new RadialGradientBrush(Color.FromArgb(alpha, red, green, blue), Color.FromArgb(0, red, green, blue));
        brush.Freeze();
        return brush;
    }

    internal static Brush Badge(Brush brush)
    {
        if (brush is not SolidColorBrush solid || SystemParameters.HighContrast) return brush;
        var color = solid.Color;
        byte Light(byte value) => (byte)Math.Round(value + (255 - value) * .12);
        byte Dark(byte value) => (byte)Math.Round(value * .93);
        var gradient = new LinearGradientBrush(Color.FromArgb(color.A, Light(color.R), Light(color.G), Light(color.B)),
            Color.FromArgb(color.A, Dark(color.R), Dark(color.G), Dark(color.B)), 90); gradient.Freeze(); return gradient;
    }

#if DEBUG
    internal static void DebugSetDark(bool dark) { IsDark = dark; RefreshMenus(); }
#endif
}

internal sealed class FloatingPalette(bool dark)
{
    public Brush Surface { get; } = SystemParameters.HighContrast ? SystemColors.WindowBrush : new LinearGradientBrush(
        dark ? Color.FromRgb(69, 55, 47) : Color.FromRgb(255, 250, 244), dark ? Color.FromRgb(56, 44, 38) : Color.FromRgb(246, 237, 227), 90);
    public SolidColorBrush Ink { get; } = dark ? WarmTheme.Brush(250, 235, 219) : WarmTheme.Brush(92, 69, 51);
    public SolidColorBrush Tint { get; } = dark ? WarmTheme.Brush(61, 48, 41, 128) : WarmTheme.Brush(255, 246, 236, 128);
    public SolidColorBrush Paper { get; } = dark ? WarmTheme.Brush(61, 48, 41) : WarmTheme.Brush(255, 246, 236);
    public SolidColorBrush Outline { get; } = dark ? WarmTheme.Brush(255, 230, 204, 41) : WarmTheme.Brush(115, 84, 56, 41);
    public SolidColorBrush Hover { get; } = dark ? WarmTheme.Brush(255, 219, 189, 33) : WarmTheme.Brush(158, 107, 66, 28);
    public SolidColorBrush Pressed { get; } = dark ? WarmTheme.Brush(255, 219, 189, 63) : WarmTheme.Brush(158, 107, 66, 53);
    public SolidColorBrush Divider { get; } = dark ? WarmTheme.Brush(250, 235, 219, 36) : WarmTheme.Brush(92, 69, 51, 36);
}
