using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.VisualBasic.FileIO;
using Velos.Core.Settings;
using Velos.Core.LongCapture;
using Velos.LongCapture;
using Velos.Windows.Capture;
using Velos.UI;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.Screenshot;

internal sealed class ScreenshotController : IDisposable
{
    private readonly Func<ScreenshotPreferences> readOptions;
    private readonly Func<ScreenshotPreferences, string?> writeOptions;
    private readonly Func<byte[], Action?, Task> copy;
    private readonly Action<string> copyColor;
    private readonly Action<string> showError;
    private readonly List<CaptureWindow> overlays = [];
    private readonly SelectionGroup selectionGroup = new();
    private readonly List<ShotThumbnail> thumbnails = [];
    private CancellationTokenSource? pendingCapture;
    private LongCaptureSession? longCapture;
    private bool pendingFullScreen;
    private bool disposed;
    private long copyVersion;
    private SelectionFocus? focus;
    private readonly Dictionary<Tool, ToolStyle> toolMemory = [];

    public ScreenshotController(Func<ScreenshotPreferences> readOptions, Func<ScreenshotPreferences, string?> writeOptions,
        Func<byte[], Action?, Task> copy, Action<string> copyColor, Action<string> showError)
    {
        this.readOptions = readOptions;
        this.writeOptions = writeOptions;
        this.copy = copy;
        this.copyColor = copyColor;
        this.showError = showError;
    }

    public bool IsActive => pendingCapture is not null || overlays.Count > 0 || longCapture is not null;
    public bool IsLongCapturing => longCapture is not null;

    public async void Toggle(bool fromTray)
    {
        if (disposed || longCapture is not null)
            return;
        if (pendingCapture is not null)
        {
            pendingFullScreen = !pendingFullScreen;
            return;
        }
        if (overlays.Count > 0)
        {
            selectionGroup.Toggle();
            return;
        }

        using var operation = new CancellationTokenSource();
        pendingCapture = operation;
        focus = new SelectionFocus(session => Application.Current.Dispatcher.BeginInvoke(() => { if (!ReferenceEquals(focus, session)) return; pendingCapture?.Cancel(); CloseOverlays(); }));
        pendingFullScreen = false;
        try
        {
            if (fromTray)
                await Task.Delay(220, operation.Token);
            var displays = Desktop.Displays();
            if (displays.Count == 0)
                throw new InvalidOperationException("没有找到可用显示器。");
            var hidden = thumbnails.Where(t => t.IsVisible).ToArray();
            var excluded = hidden.Select(t => new WindowInteropHelper(t).Handle).ToHashSet();
            var windowBounds = Desktop.WindowBounds(excluded);
            var includeCursor = readOptions().IncludeCursor;
            (Display Display, BitmapSource Image)[] images;
            try
            {
                foreach (var thumb in hidden)
                    thumb.HideForCapture();
                if (hidden.Length > 0)
                    Desktop.FlushComposition();
                images = await Task.WhenAll(displays.Select(async display =>
                {
                    var pixels = await WindowsCapture.FreezeDisplay(display, includeCursor, operation.Token).ConfigureAwait(false);
                    if (pixels.Width != display.Bounds.Width || pixels.Height != display.Bounds.Height)
                        throw new InvalidOperationException("显示器布局已变化，请重新截图。");
                    return (display, ToBitmap(pixels));
                }));
            }
            finally
            {
                if (!disposed)
                    foreach (var thumb in hidden)
                        thumb.RestoreAfterCapture();
            }
            operation.Token.ThrowIfCancellationRequested();
            OpenOverlays(images, windowBounds);
        }
        catch (OperationCanceledException) when (operation.IsCancellationRequested) { }
        catch (Exception error)
        {
            CloseOverlays();
            Report("无法冻结屏幕", error);
        }
        finally
        {
            pendingCapture = null;
        }
    }

    private void OpenOverlays(IReadOnlyList<(Display Display, BitmapSource Image)> images, IReadOnlyList<PixelRect> windows)
    {
        foreach (var (display, image) in images)
        {
            CaptureWindow window = null!;
            window = new CaptureWindow(display, image, windows, Style, Remember, action => OnAction(window, action),
                text =>
                {
                    copyVersion++;
                    try { copyColor(text); return true; }
                    catch (Exception error) { Report("无法复制颜色", error); return false; }
                }, readOptions().ScreenshotCornerRadius, radius =>
                { if (writeOptions(readOptions() with { ScreenshotCornerRadius = radius }) is { } error) showError(error); });
            overlays.Add(window);
            selectionGroup.Add(window, display, window.Surface, window.SetSuppressed);
            window.Closed += (_, _) =>
            {
                if (overlays.Remove(window))
                    CloseOverlays();
            };
            window.ShowOnDisplay();
        }
        var active = PointerOverlay();
        active.Surface.SetFullScreen(pendingFullScreen);
        active.Activate();
        active.Focus();
    }

    private CaptureWindow PointerOverlay()
    {
        var pointer = Desktop.Pointer();
        return overlays.FirstOrDefault(o => o.Display.Bounds.Contains(pointer)) ?? overlays[0];
    }

    private void MoveFullScreen(CaptureWindow window)
        => selectionGroup.MoveFullScreen(window);

    private void OnAction(CaptureWindow window, ShotAction action)
    {
        if (action == ShotAction.Cancel)
        {
            CloseOverlays();
            return;
        }
        if (window.Surface.Target is not { Width: > 0, Height: > 0 } region)
            return;
        if (action == ShotAction.LongCapture)
        {
            if (window.Surface.HasMarks || window.Surface.Region is null)
                return;
            var display = window.Display;
            var location = new PixelRect(display.Bounds.X + region.X, display.Bounds.Y + region.Y, region.Width, region.Height);
            var scale = window.Surface.PixelScale;
            CloseOverlays();
            BeginLongCapture(display, location, scale);
            return;
        }
        try
        {
            var bitmap = window.Surface.RenderCrop(region);
            var location = new PixelRect(window.Display.Bounds.X + region.X, window.Display.Bounds.Y + region.Y, region.Width, region.Height);
            var display = window.Display;
            var scale = window.Surface.PixelScale;
            CloseOverlays(restoreFocus: action != ShotAction.Pin);
            _ = Deliver(bitmap, scale, location, display, action);
        }
        catch (Exception error) { Report("无法生成截图", error); }
    }

    private void BeginLongCapture(Display display, PixelRect source, double scale)
    {
        var hidden = thumbnails.Where(thumb => thumb.IsVisible).ToArray();
        foreach (var thumb in hidden) thumb.HideForCapture();
        try
        {
            longCapture = new LongCaptureSession(display, source, scale, readOptions(),
                (image, axis, action) => _ = Deliver(image, scale, source, display, action, axis),
                showError, () =>
                {
                    longCapture = null;
                    if (!disposed)
                        foreach (var thumb in hidden) thumb.RestoreAfterCapture();
                });
            longCapture.Start();
        }
        catch (Exception error)
        {
            if (longCapture is { } session)
                session.Dispose();
            else
                foreach (var thumb in hidden) thumb.RestoreAfterCapture();
            Report("无法开始长截图", error);
        }
    }

    private async Task Deliver(BitmapSource bitmap, double scale, PixelRect source, Display display, ShotAction action,
        ScrollAxis? longAxis = null)
    {
        try
        {
            var options = readOptions();
            if (action == ShotAction.Done && !options.Copy && !options.AutoSave && !options.Thumbnail)
                return;
            var shouldCopy = action is not (ShotAction.Pin or ShotAction.Edit) && (action == ShotAction.Copy || options.Copy);
            var version = shouldCopy ? ++copyVersion : 0;
            var png = await Task.Run(() => ShotEncoding.Encode(bitmap, pixelScale: scale));
            if (disposed)
                return;
            var asset = new ShotImage(png, bitmap.PixelWidth, bitmap.PixelHeight, scale, source, display, longAxis);
            if (action == ShotAction.Pin)
            {
                OpenPin(asset);
                return;
            }
            if (action == ShotAction.Edit)
            {
                OpenEditor(asset);
                return;
            }

            ShotThumbnail? thumb = options.Thumbnail ? ShowThumbnail(asset) : null;
            if (action == ShotAction.Save || action == ShotAction.Done && options.AutoSave)
                _ = Save(asset);
            if (shouldCopy)
            {
                Action? dismiss = null;
                if (thumb is not null && options.DismissOnPaste)
                {
                    var reference = new WeakReference<ShotThumbnail>(thumb);
                    dismiss = () =>
                    {
                        if (reference.TryGetTarget(out var current) && !current.IsClosed)
                            current.Dispatcher.BeginInvoke(() => { if (!current.IsClosed) WarmMotion.CloseWindow(current); });
                    };
                }
                await Copy(asset, dismiss, version);
            }
        }
        catch (Exception error) { Report("无法输出截图", error); }
    }

    private ShotThumbnail ShowThumbnail(ShotImage image)
    {
        ShotThumbnail thumb = null!;
        thumb = new ShotThumbnail(image, () => OpenEditor(image),
            () => _ = Save(image),
            () =>
            {
                OpenPin(image);
                if (!thumb.IsClosed) thumb.Close();
            },
            () => { try { if (image.SavedPath is { } saved) System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"/select,\"{saved}\"") { UseShellExecute = true }); } catch (Exception error) { Report("无法显示截图文件", error); } }, showError);
        thumb.Closed += (_, _) =>
        {
            thumbnails.Remove(thumb);
            if (!disposed)
                LayoutThumbnails(image.Display);
        };
        thumbnails.Add(thumb);
        LayoutThumbnails(image.Display);
        return thumb;
    }

    private void LayoutThumbnails(Display display)
    {
        var work = display.WorkArea;
        var group = thumbnails.Where(t => t.Image.Display.Handle == display.Handle).Reverse().ToArray();
        if (group.Length == 0)
            return;
        var margin = (int)Math.Round(16 * group[0].Image.Scale);
        var bottom = work.Bottom - margin;
        foreach (var thumb in group)
        {
            if (thumb.IsClosed)
                continue;
            var scale = thumb.Image.Scale;
            var width = (int)Math.Round(thumb.Width * scale);
            var height = (int)Math.Round(thumb.Height * scale);
            var top = bottom - height;
            thumb.Place(new PixelRect(work.Right - width - margin, top, width, height));
            bottom = top - (int)Math.Round(10 * scale);
        }
    }

    private void OpenPin(ShotImage image)
    {
        try { new PinWindow(image, () => _ = Copy(image, null, native: true), () => _ = SaveAs(image)).ShowPinned(); }
        catch (Exception error) { Report("无法打开钉图", error); }
    }

    private EditorWindow? OpenEditor(ShotImage image)
    {
        try
        {
            var editor = new EditorWindow(image, Style, Remember, DeliverEdit);
            editor.Show();
            return editor;
        }
        catch (Exception error)
        {
            Report("无法打开截图编辑器", error);
            return null;
        }
    }

    private void DeliverEdit(ShotImage old, BitmapSource image, ShotAction action)
        => _ = Deliver(image, old.Scale, old.Source, old.Display, action, old.LongAxis);

    private async Task<bool> Copy(ShotImage asset, Action? firstRead, long? requestedVersion = null, bool native = false)
    {
        try
        {
            var version = requestedVersion ?? ++copyVersion;
            if (version != copyVersion)
                return false;
            var png = asset.Png;
            var exportScale = native ? 1 : asset.ExportScale(readOptions().Downscale);
            if (exportScale < 1)
                png = await Task.Run(() => ShotEncoding.Encode(ShotEncoding.Resize(ShotEncoding.Decode(asset.Png), exportScale)));
            if (!disposed && version == copyVersion)
            {
                await copy(png, firstRead);
                return true;
            }
        }
        catch (Exception error) { Report("无法复制截图", error); }
        return false;
    }

    // Windows HEIC 编码器不保证 alpha；圆角图使用 PNG，扩展名与真实编码保持一致。
    private static ScreenshotFormat TransparentFormat(ShotImage image, ScreenshotFormat requested) =>
        requested == ScreenshotFormat.Heic && image.HasTransparency ? ScreenshotFormat.Png : requested;
    private async Task SaveAs(ShotImage image)
    {
        var options = readOptions(); var format = TransparentFormat(image, options.Format);
        var extension = format switch { ScreenshotFormat.Jpeg => ".jpg", ScreenshotFormat.Heic => ".heic", _ => ".png" };
        var dialog = new Microsoft.Win32.SaveFileDialog { Title = "存储为", FileName = $"截图 {image.CreatedAt:yyyy-MM-dd HH.mm.ss}{extension}",
            DefaultExt = extension, Filter = $"{format.ToString().ToUpperInvariant()} 文件|*{extension}",
            InitialDirectory = string.IsNullOrWhiteSpace(options.Directory) ? ShotEncoding.DefaultDirectory : options.Directory, OverwritePrompt = true };
        if (dialog.ShowDialog() != true) return;
        try { await WriteNative(image, dialog.FileName, format, options.Quality); }
        catch (Exception error) { Report("无法保存钉图", error); }
    }
    private static async Task WriteNative(ShotImage image, string path, ScreenshotFormat format, int quality)
    {
        var bytes = await Task.Run(async () => format == ScreenshotFormat.Png ? image.Png : format == ScreenshotFormat.Heic
            ? await ShotEncoding.EncodeHeic(ShotEncoding.Decode(image.Png), quality, image.Scale)
            : ShotEncoding.Encode(ShotEncoding.Decode(image.Png), format, quality, image.Scale));
        await File.WriteAllBytesAsync(path, bytes);
    }
    private async Task Save(ShotImage image)
    {
        if (image.Saving)
            return;
        if (image.SavedPath is { } existing && File.Exists(existing))
            return;
        image.Saving = true;
        try
        {
            var options = readOptions();
            image.SavedPath = await Task.Run(async () =>
            {
                var format = TransparentFormat(image, Enum.IsDefined(options.Format) ? options.Format : ScreenshotFormat.Png);
                var quality = Math.Clamp(options.Quality, 60, 100);
                var directory = string.IsNullOrWhiteSpace(options.Directory) ? ShotEncoding.DefaultDirectory : options.Directory;
                var ext = format switch { ScreenshotFormat.Heic => ".heic", ScreenshotFormat.Jpeg => ".jpg", _ => ".png" };
                var scale = image.ExportScale(options.Downscale);
                var pixelScale = scale < 1 ? 1 : image.Scale;
                byte[] bytes;
                if (format == ScreenshotFormat.Png && scale >= 1)
                    bytes = image.Png;
                else
                {
                    var bitmap = ShotEncoding.Resize(ShotEncoding.Decode(image.Png), scale);
                    bytes = format == ScreenshotFormat.Heic
                        ? await ShotEncoding.EncodeHeic(bitmap, quality, pixelScale)
                        : ShotEncoding.Encode(bitmap, format, quality, pixelScale);
                }
                return WriteScreenshot(directory, $"截图 {image.CreatedAt:yyyy-MM-dd HH.mm.ss}", ext, bytes);
            });
        }
        catch (Exception error) { Report("无法保存截图", error); }
        finally { image.Saving = false; }
    }

    private static string WriteScreenshot(string directory, string name, string extension, byte[] bytes)
    {
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, ".Velos-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            File.WriteAllBytes(temporary, bytes);
            for (var index = 1; ; index++)
            {
                var destination = Path.Combine(directory, name + (index == 1 ? "" : $" {index}") + extension);
                try
                {
                    File.Move(temporary, destination);
                    return destination;
                }
                catch (IOException) when (File.Exists(destination)) { }
            }
        }
        finally
        {
            if (File.Exists(temporary))
            {
                try { FileSystem.DeleteFile(temporary, UIOption.OnlyErrorDialogs, RecycleOption.SendToRecycleBin); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or OperationCanceledException) { }
            }
        }
    }

    private ToolStyle Style(Tool tool)
    {
        if (toolMemory.TryGetValue(tool, out var remembered)) return remembered;
        var styles = readOptions().ToolStyles;
        var loaded = styles is not null && styles.TryGetValue(tool.ToString(), out var style) && style is not null
            ? ToolInfo.Normalize(tool, style) : ToolInfo.Default(tool);
        toolMemory[tool] = loaded;
        return loaded;
    }

    private void Remember(Tool tool, ToolStyle style)
    {
        toolMemory[tool] = style;
        var current = readOptions();
        var styles = current.ToolStyles is null ? new Dictionary<string, ToolStyle>() : new(current.ToolStyles);
        styles[tool.ToString()] = style;
        if (writeOptions(current with { ToolStyles = styles }) is { } error)
            showError(error);
    }

    private static BitmapSource ToBitmap(CapturedPixels pixels)
    {
        var image = BitmapSource.Create(pixels.Width, pixels.Height, 96, 96, PixelFormats.Bgr32, null, pixels.Bgra, pixels.Width * 4);
        image.Freeze();
        return image;
    }

    private void Report(string title, Exception error)
    {
        if (!disposed)
            showError($"{title}。{(error is InvalidOperationException or NotSupportedException ? error.Message : $"（0x{error.HResult:X8}）")}");
    }

    private void CloseOverlays(bool restoreFocus = true)
    {
        var previousFocus = focus; focus = null; previousFocus?.Finish(restoreFocus);
        selectionGroup.Clear();
        var open = overlays.ToArray();
        overlays.Clear();
        foreach (var window in open)
            window.Close();
    }

    public void CancelSelection()
    {
        pendingCapture?.Cancel(); longCapture?.Dispose(); CloseOverlays();
    }

    public void Dispose()
    {
        disposed = true;
        pendingCapture?.Cancel();
        longCapture?.Dispose();
        CloseOverlays();
        foreach (var thumb in thumbnails.ToArray())
            thumb.Close();
    }

#if DEBUG
    internal async Task<string?> DebugSaveAsset(ShotImage image) { await Save(image); return image.SavedPath; }
    internal Task<bool> DebugCopyNative(ShotImage image) => Copy(image, null, native: true);
    internal Task DebugSaveNative(ShotImage image, string path) => WriteNative(image, path, ScreenshotFormat.Png, 100);
    internal Task DebugDeliver(BitmapSource bitmap, double scale, PixelRect source, Display display, ShotAction action, ScrollAxis? axis = null)
        => Deliver(bitmap, scale, source, display, action, axis);
    internal CaptureWindow DebugStart(Display display, BitmapSource image, IReadOnlyList<PixelRect> windows, bool trackFocus = false)
    {
        if (trackFocus) focus = new SelectionFocus(session => Application.Current.Dispatcher.BeginInvoke(() => { if (ReferenceEquals(focus, session)) CloseOverlays(); }));
        OpenOverlays([(display, image)], windows);
        return overlays[0];
    }
    internal IReadOnlyList<ShotThumbnail> DebugThumbnails => thumbnails;
    internal IReadOnlyList<CaptureWindow> DebugStartDisplays((Display Display, BitmapSource Image)[] displays)
    { OpenOverlays(displays, []); return overlays; }
    internal void DebugMoveFullScreen(CaptureWindow window) => MoveFullScreen(window);
    internal void DebugAction(CaptureWindow window, ShotAction action) => OnAction(window, action);
    internal Task DebugSave(ShotImage image) => Save(image);
    internal EditorWindow? DebugEdit(ShotImage image) => OpenEditor(image);
#endif
}
