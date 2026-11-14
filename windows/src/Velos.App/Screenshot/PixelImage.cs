using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Velos.Screenshot;

// 独立像素块送入合成器；不能仅保留指向整张长图的 CroppedBitmap 视图。
internal sealed class PixelImage
{
    private const int TileSize = 2048;
    private readonly int width, height;
    private readonly List<(BitmapSource Image, Rect Bounds)> tiles = [];

    public PixelImage(BitmapSource source)
    {
        width = source.PixelWidth; height = source.PixelHeight;
        if (source.PixelWidth <= TileSize && source.PixelHeight <= TileSize)
        {
            tiles.Add((source, new Rect(0, 0, source.PixelWidth, source.PixelHeight)));
            return;
        }
        for (var y = 0; y < source.PixelHeight; y += TileSize)
        for (var x = 0; x < source.PixelWidth; x += TileSize)
        {
            var region = new Int32Rect(x, y, Math.Min(TileSize, source.PixelWidth - x), Math.Min(TileSize, source.PixelHeight - y));
            var stride = checked((region.Width * source.Format.BitsPerPixel + 7) / 8);
            var pixels = new byte[checked(stride * region.Height)];
            source.CopyPixels(region, pixels, stride, 0);
            var tile = BitmapSource.Create(region.Width, region.Height, source.DpiX, source.DpiY, source.Format, source.Palette, pixels, stride);
            tile.Freeze();
            tiles.Add((tile, new Rect(region.X, region.Y, region.Width, region.Height)));
        }
    }

    public void Draw(DrawingContext drawing, Rect destination, Rect? visible = null)
    {
        var scaleX = destination.Width / width;
        var scaleY = destination.Height / height;
        foreach (var (image, bounds) in tiles)
        {
            if (visible is { } crop && !bounds.IntersectsWith(crop)) continue;
            drawing.DrawImage(image, new Rect(destination.X + bounds.X * scaleX, destination.Y + bounds.Y * scaleY,
                bounds.Width * scaleX, bounds.Height * scaleY));
        }
    }
}

internal sealed class PixelImageView(BitmapSource source) : FrameworkElement
{
    private readonly PixelImage image = new(source);

    protected override void OnRender(DrawingContext drawing) =>
        image.Draw(drawing, new Rect(0, 0, ActualWidth, ActualHeight));
}
