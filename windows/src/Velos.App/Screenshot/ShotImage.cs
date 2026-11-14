using System.Buffers.Binary;
using System.Collections.ObjectModel;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velos.Core.Settings;
using Velos.Core.LongCapture;
using Velos.Core.Screenshot;
using Velos.Windows.Capture;
using WinEncoder = Windows.Graphics.Imaging.BitmapEncoder;
using WinImaging = Windows.Graphics.Imaging;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.Screenshot;

internal sealed record ShotImage(byte[] Png, int Width, int Height, double Scale, PixelRect Source, Display Display, ScrollAxis? LongAxis = null)
{
    private bool? transparency;
    public bool HasTransparency => transparency ??= ShotEncoding.HasTransparency(ShotEncoding.Decode(Png));
    public double ExportScale(bool downscale) => downscale && LongAxis is null && Scale > 1 ? 1 / Scale : 1;
    public DateTime CreatedAt { get; } = DateTime.Now;
    private string? savedPath;
    public string? SavedPath { get => savedPath; set { if (savedPath == value) return; savedPath = value; FileSaved?.Invoke(); } }
    public event Action? FileSaved;
    public bool Saving { get; set; }
    public string PngName => $"截图 {CreatedAt:yyyy-MM-dd HH.mm.ss}.png";
}

internal static class ShotEncoding
{
    public static bool HasTransparency(BitmapSource source)
    {
        if (source.Format != PixelFormats.Bgra32 && source.Format != PixelFormats.Pbgra32) return false;
        var row = new byte[source.PixelWidth * 4];
        for (var y = 0; y < source.PixelHeight; y++)
        {
            source.CopyPixels(new System.Windows.Int32Rect(0, y, source.PixelWidth, 1), row, row.Length, 0);
            for (var x = 3; x < row.Length; x += 4) if (row[x] != 255) return true;
        }
        return false;
    }
    public static BitmapSource Round(BitmapSource source, double radius)
    {
        if (radius <= 0) return source;
        var straight = source.Format == PixelFormats.Bgra32 ? source : new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        var pixels = new byte[checked(straight.PixelWidth * straight.PixelHeight * 4)]; straight.CopyPixels(pixels, straight.PixelWidth * 4, 0);
        RoundedCorners.Apply(pixels, straight.PixelWidth, straight.PixelHeight, radius);
        var output = BitmapSource.Create(straight.PixelWidth, straight.PixelHeight, source.DpiX, source.DpiY, PixelFormats.Bgra32, null, pixels, straight.PixelWidth * 4);
        output.Freeze(); return output;
    }
    private static BitmapSource WhiteBackground(BitmapSource source)
    {
        // JPEG / CF_DIB 的铺白也直接逐像素进行，不能把超长图交给整图渲染纹理。
        var straight = source.Format == PixelFormats.Bgra32 ? source : new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        var stride = checked(straight.PixelWidth * 4);
        var pixels = new byte[checked(stride * straight.PixelHeight)]; straight.CopyPixels(pixels, stride, 0);
        for (var offset = 0; offset < pixels.Length; offset += 4)
        {
            var alpha = pixels[offset + 3];
            for (var channel = 0; channel < 3; channel++) pixels[offset + channel] = (byte)((pixels[offset + channel] * alpha + 255 * (255 - alpha) + 127) / 255);
            pixels[offset + 3] = 255;
        }
        var output = BitmapSource.Create(straight.PixelWidth, straight.PixelHeight, source.DpiX, source.DpiY, PixelFormats.Bgra32, null, pixels, stride);
        output.Freeze(); return output;
    }
    private static readonly Lazy<bool> Heic = new(() =>
    {
        try { return WinEncoder.GetEncoderInformationEnumerator().Any(codec => codec.CodecId == WinEncoder.HeifEncoderId); }
        catch (System.Runtime.InteropServices.COMException) { return false; }
    });

    public static bool SupportsHeic => Heic.Value;

    public static string DefaultDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures, Environment.SpecialFolderOption.DoNotVerify), "ScreenShots");

    public static BitmapSource Decode(byte[] png, int previewWidth = 0, int previewHeight = 0)
    {
        using var stream = new MemoryStream(png, writable: false);
        var bitmap = new BitmapImage();
        bitmap.BeginInit();
        bitmap.CacheOption = BitmapCacheOption.OnLoad;
        bitmap.StreamSource = stream;
        if (previewWidth > 0) bitmap.DecodePixelWidth = previewWidth;
        if (previewHeight > 0) bitmap.DecodePixelHeight = previewHeight;
        bitmap.EndInit();
        bitmap.Freeze();
        return bitmap;
    }

    public static BitmapSource Resize(BitmapSource source, double scale)
    {
        if (scale >= 1)
            return source;
        var resized = new TransformedBitmap(source, new ScaleTransform(
            Math.Max(1, (int)Math.Round(source.PixelWidth * scale)) / (double)source.PixelWidth,
            Math.Max(1, (int)Math.Round(source.PixelHeight * scale)) / (double)source.PixelHeight));
        resized.Freeze();
        return resized;
    }

    public static byte[] Encode(BitmapSource source, ScreenshotFormat format = ScreenshotFormat.Png, int quality = 90, double pixelScale = 1)
    {
        if (format == ScreenshotFormat.Jpeg && HasTransparency(source)) source = WhiteBackground(source);
        var dpi = 96 * pixelScale;
        if (Math.Abs(source.DpiX - dpi) > 0.01 || Math.Abs(source.DpiY - dpi) > 0.01)
        {
            var stride = checked((source.PixelWidth * source.Format.BitsPerPixel + 7) / 8);
            var pixels = new byte[checked(stride * source.PixelHeight)];
            source.CopyPixels(pixels, stride, 0);
            source = BitmapSource.Create(source.PixelWidth, source.PixelHeight, dpi, dpi, source.Format, source.Palette, pixels, stride);
        }
        var srgb = new ReadOnlyCollection<ColorContext>([new ColorContext(PixelFormats.Bgr32)]);
        BitmapEncoder encoder = format == ScreenshotFormat.Jpeg
            ? new JpegBitmapEncoder { QualityLevel = Math.Clamp(quality, 60, 100) }
            : new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(source, null, null, srgb));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    public static async Task<byte[]> EncodeHeic(BitmapSource source, int quality, double pixelScale = 1)
    {
        var image = source.Format == PixelFormats.Bgr32 ? source : new FormatConvertedBitmap(source, PixelFormats.Bgr32, null, 0);
        var stride = checked(image.PixelWidth * 4);
        var pixels = new byte[checked(stride * image.PixelHeight)];
        image.CopyPixels(pixels, stride, 0);
        using var stream = new global::Windows.Storage.Streams.InMemoryRandomAccessStream();
        var options = new WinImaging.BitmapPropertySet
        {
            ["ImageQuality"] = new WinImaging.BitmapTypedValue(Math.Clamp(quality, 60, 100) / 100f, global::Windows.Foundation.PropertyType.Single)
        };
        var encoder = await WinEncoder.CreateAsync(WinEncoder.HeifEncoderId, stream, options);
        encoder.SetPixelData(WinImaging.BitmapPixelFormat.Bgra8, WinImaging.BitmapAlphaMode.Ignore,
            (uint)image.PixelWidth, (uint)image.PixelHeight, 96 * pixelScale, 96 * pixelScale, pixels);
        await encoder.FlushAsync();
        stream.Seek(0);
        var result = new byte[checked((int)stream.Size)];
        using var reader = new global::Windows.Storage.Streams.DataReader(stream);
        await reader.LoadAsync((uint)result.Length);
        reader.ReadBytes(result);
        return result;
    }

    public static byte[] Dib(byte[] png)
    {
        var bitmap = Decode(png);
        // 旧式 CF_DIB 无可靠 alpha；兼容图铺白，完整透明图仍由 PNG 剪贴板格式提供。
        if (HasTransparency(bitmap)) bitmap = WhiteBackground(bitmap);
        var bgr = new FormatConvertedBitmap(bitmap, PixelFormats.Bgr32, null, 0);
        var stride = checked(bgr.PixelWidth * 4);
        const int headerSize = 40;
        var data = new byte[checked(headerSize + stride * bgr.PixelHeight)];
        BinaryPrimitives.WriteInt32LittleEndian(data, headerSize);
        BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(4), bgr.PixelWidth);
        BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(8), -bgr.PixelHeight);
        BinaryPrimitives.WriteUInt16LittleEndian(data.AsSpan(12), 1);
        BinaryPrimitives.WriteUInt16LittleEndian(data.AsSpan(14), 32);
        BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(20), stride * bgr.PixelHeight);
        BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(24), (int)Math.Round(bgr.DpiX / 0.0254));
        BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(28), (int)Math.Round(bgr.DpiY / 0.0254));
        bgr.CopyPixels(data, stride, headerSize);
        return data;
    }
}
