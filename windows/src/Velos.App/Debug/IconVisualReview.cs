#if DEBUG
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velos.UI;

namespace Velos;

public partial class App
{
    private static bool WriteIconSheets(string profile)
    {
        var valid = true;
        foreach (var dark in new[] { false, true })
        foreach (var scale in new[] { 1d, 1.25, 1.5, 2 })
        {
            var root = new Canvas { Width = 800, Height = 440, Background = dark ? WarmTheme.Brush(56, 44, 38) : WarmTheme.Brush(255, 246, 236) };
            var ink = dark ? WarmTheme.Brush(250, 235, 219) : WarmTheme.Brush(92, 69, 51);
            var kinds = Enum.GetValues<ActionIcon>();
            for (var i = 0; i < kinds.Length; i++)
            {
                var kind = kinds[i];
                var tile = new StackPanel { Width = 80, Height = 72 };
                var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Height = 38 };
                row.Children.Add(new ActionIconView(kind, 16) { Ink = ink, Margin = new Thickness(0, 0, 8, 0) });
                row.Children.Add(new ActionIconView(kind, 28) { Ink = ink });
                tile.Children.Add(row);
                tile.Children.Add(new TextBlock { Text = kind.ToString(), FontFamily = WarmTheme.Text, FontSize = 10, Foreground = ink, HorizontalAlignment = HorizontalAlignment.Center });
                Canvas.SetLeft(tile, i % 10 * 80); Canvas.SetTop(tile, i / 10 * 72 + 4); root.Children.Add(tile);

                // 检查实际像素输出，避免遗漏分支或误用缺字字体使按钮空白。
                var icon = new ActionIconView(kind, 16) { Ink = ink };
                icon.Measure(new Size(16, 16)); icon.Arrange(new Rect(0, 0, 16, 16));
                var rendered = new RenderTargetBitmap((int)(16 * scale), (int)(16 * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
                rendered.Render(icon);
                var pixels = new byte[rendered.PixelWidth * rendered.PixelHeight * 4]; rendered.CopyPixels(pixels, rendered.PixelWidth * 4, 0);
                valid &= Enumerable.Range(0, pixels.Length / 4).Count(p => pixels[p * 4 + 3] > 32) >= 4;
            }
            root.Measure(new Size(800, 440)); root.Arrange(new Rect(0, 0, 800, 440)); root.UpdateLayout();
            var sheet = new RenderTargetBitmap((int)(800 * scale), (int)(440 * scale), 96 * scale, 96 * scale, PixelFormats.Pbgra32);
            sheet.Render(root);
            var png = new PngBitmapEncoder(); png.Frames.Add(BitmapFrame.Create(sheet));
            using var output = File.Create(Path.Combine(profile, $"图标-{(dark ? "深色" : "浅色")}-{scale * 100:0}%.png")); png.Save(output);
        }
        return valid;
    }
}
#endif
