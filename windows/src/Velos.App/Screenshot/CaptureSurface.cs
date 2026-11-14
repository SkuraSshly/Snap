using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velos.Core.Hotkeys;
using Velos.Core.Screenshot;
using Velos.Core.Settings;
using Velos.Windows.Capture;
using Velos.UI;
using PixelPoint = System.Drawing.Point;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.Screenshot;

internal sealed class CaptureSurface : MarkCanvas
{
    private static readonly Brush Shade = new SolidColorBrush(Color.FromArgb(89, 0, 0, 0));
    private Brush Accent => selectionAccent ?? (live ? WarmTheme.Coral : WarmTheme.Apricot);
    private readonly Brush? selectionAccent;
    private readonly bool live;
    internal bool ShowMagnifier { get; set; } = true;
    private static Brush Paper => CaptureChrome.Paper;
    private static Brush Ink => CaptureChrome.Ink;
    private readonly PixelRect bounds;
    private readonly PixelRect[] windowBounds;
    private PixelRect? hovered;
    private PixelRect? selection;
    private PixelRect initial;
    private PixelPoint anchor;
    private PixelPoint? pointer;
    private RegionHandle? handle;
    private DragMode drag;
    private bool fullScreen;
    internal bool Suppressed { get; private set; }
    internal void Suppress(bool value) { Suppressed = value; IsHitTestVisible = !value; InvalidateVisual(); }
    private double cornerRadius;
    public double CornerRadius
    {
        get => cornerRadius;
        set { var next = double.IsFinite(value) ? Math.Clamp(value, 0, 40) : 0; if (next == cornerRadius) return; cornerRadius = next; SelectionChanged?.Invoke(); InvalidateVisual(); }
    }
    public override BitmapSource RenderCrop(PixelRect crop) => ShotEncoding.Round(base.RenderCrop(crop),
        fullScreen ? 0 : RoundedCorners.PhysicalRadius(cornerRadius, PixelScale, crop.Width, crop.Height));

    private enum DragMode { Idle, Pressed, Creating, Moving, Resizing }

    public CaptureSurface(Display display, BitmapSource photo, IReadOnlyList<PixelRect> windows,
        Func<Tool, ToolStyle> style, Action<Tool, ToolStyle> remember, bool live = false, Brush? selectionAccent = null) : base(photo, 1, style, remember)
    {
        this.live = live;
        this.selectionAccent = selectionAccent;
        bounds = new PixelRect(0, 0, photo.PixelWidth, photo.PixelHeight);
        windowBounds = windows.Select(rect => PixelRect.Intersect(rect, display.Bounds))
            .Where(rect => rect.Width > 0 && rect.Height > 0)
            .Select(rect => new PixelRect(rect.X - display.Bounds.X, rect.Y - display.Bounds.Y, rect.Width, rect.Height)).ToArray();
    }

    public event Action? SelectionChanged;
    public event Action? SelectionCommitted;
    public bool FullScreen => fullScreen;
    public bool IsSelecting => drag != DragMode.Idle;
    public PixelRect? Region => fullScreen ? bounds : selection;
    public PixelRect? Target => IsSelecting ? null : Region ?? hovered;
    protected override Rect DrawingBounds => Region is { } region ? ToRect(region) : Rect.Empty;

    public void SetFullScreen(bool value)
    {
        FinishText();
        fullScreen = value;
        hovered = null;
        drag = DragMode.Idle;
        if (IsMouseCaptured)
            ReleaseMouseCapture();
        SelectionChanged?.Invoke();
        InvalidateVisual();
    }

    public void ClearRegion()
    {
        selection = hovered = null;
        fullScreen = false;
        SelectionChanged?.Invoke();
        InvalidateVisual();
    }

    public void SetPointer(PixelPoint location)
    {
        if (!bounds.Contains(location))
            return;
        if (pointer != location) copiedColorAt = null;
        pointer = location;
        if (selection is null && !fullScreen && !IsSelecting)
        {
            var hit = Array.Find(windowBounds, rect => rect.Contains(location));
            hovered = hit.Width > 0 ? hit : null;
        }
        InvalidateVisual();
    }

    protected override void RenderContents(DrawingContext drawing)
    {
        if (!live) DrawPhoto(drawing);
        else drawing.DrawRectangle(new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)), null, AtView(PhotoBounds));
        if (Suppressed) { drawing.DrawRectangle(Shade, null, AtView(PhotoBounds)); return; }
        DrawMarkup(drawing, DrawingBounds);
        var visible = Region ?? hovered;
        if (!fullScreen)
        {
            var screen = AtView(PhotoBounds);
            if (visible is { Width: > 0, Height: > 0 } rect)
            {
                var selectionView = AtView(ToRect(rect));
                var outside = new CombinedGeometry(GeometryCombineMode.Exclude,
                    new RectangleGeometry(screen), new RectangleGeometry(selectionView,
                        selection is null ? 0 : Math.Min(cornerRadius, Math.Min(rect.Width, rect.Height) / PixelScale / 2),
                        selection is null ? 0 : Math.Min(cornerRadius, Math.Min(rect.Width, rect.Height) / PixelScale / 2)));
                drawing.DrawGeometry(Shade, null, outside);
            }
            else
            {
                drawing.DrawRectangle(Shade, null, screen);
            }
        }
        if (fullScreen)
        {
            var edge = AtView(PhotoBounds); edge.Inflate(-2, -2); drawing.DrawRectangle(null, new Pen(Accent, 4), edge);
        }
        if (visible is { Width: > 0, Height: > 0 } area && !fullScreen)
            DrawSelection(drawing, area);
        if (ShowMagnifier && !live && pointer is { } pixel && !fullScreen && (selection is null || drag is DragMode.Creating or DragMode.Resizing or DragMode.Moving))
            DrawMagnifier(drawing, pixel);
    }

    private void DrawSelection(DrawingContext drawing, PixelRect area)
    {
        var rect = AtView(ToRect(area));
        var hoveredWindow = selection is null;
        var outline = rect; outline.Inflate(hoveredWindow ? -1 : .5, hoveredWindow ? -1 : .5);
        var radius = hoveredWindow ? 0 : Math.Min(cornerRadius, Math.Min(rect.Width, rect.Height) / 2);
        drawing.DrawRoundedRectangle(null, new Pen(Accent, hoveredWindow ? 2 : 1), outline, radius + (hoveredWindow ? 0 : .5), radius + (hoveredWindow ? 0 : .5));
        if (selection is not null && !IsSelecting)
        {
            foreach (var handle in Enum.GetValues<RegionHandle>())
            {
                var pixel = RegionGeometry.HandlePoint(area, handle);
                drawing.DrawEllipse(Brushes.White, new Pen(Accent, 1.5), AtView(new Point(pixel.X, pixel.Y)), 4, 4);
            }
        }
        var label = MarkRenderer.Text($"{area.Width} × {area.Height}", 12, Ink);
        var bounds = SizeLabelBounds(area);
        drawing.DrawRoundedRectangle(Paper, null, bounds, 11, 11);
        drawing.DrawText(label, new Point(bounds.Left + 10, bounds.Top + 2));
    }
    internal Rect SizeLabelBounds(PixelRect area)
    {
        var rect = AtView(ToRect(area)); var label = MarkRenderer.Text($"{area.Width} × {area.Height}", 12, Ink);
        var width = label.Width + 20; var outside = rect.Top >= 31;
        return new Rect(Math.Clamp(rect.Left + (outside ? 0 : 8), 2, Math.Max(2, ActualWidth - width - 2)), outside ? rect.Top - 29 : rect.Top + 8, width, 21);
    }

    internal Rect PointerAvoid => pointer is { } p ? new Rect(AtView(new Point(p.X, p.Y)) - new Vector(16, 16), new Size(32, 32)) : Rect.Empty;
    internal Rect MagnifierAvoid => ShowMagnifier && !live && pointer is { } p && !fullScreen && (selection is null || drag is DragMode.Creating or DragMode.Resizing or DragMode.Moving) ? MagnifierRect(p) : Rect.Empty;
    private Rect MagnifierRect(PixelPoint pixel)
    {
        const int width = 134, height = 172;
        var cursor = AtView(new Point(pixel.X, pixel.Y));
        var left = cursor.X + 22 + width <= ActualWidth - 4 ? cursor.X + 22 : cursor.X - 22 - width;
        var top = cursor.Y + 22 + height <= ActualHeight - 4 ? cursor.Y + 22 : cursor.Y - 22 - height;
        return new Rect(Math.Clamp(left, 4, Math.Max(4, ActualWidth - width - 4)), Math.Clamp(top, 4, Math.Max(4, ActualHeight - height - 4)), width, height);
    }
    private void DrawMagnifier(DrawingContext drawing, PixelPoint pixel)
    {
        const int side = 15, cell = 8, padding = 7;
        const int imageSize = side * cell, boxWidth = imageSize + padding * 2, boxHeight = boxWidth + 38;
        var box = MagnifierRect(pixel); var left = box.Left; var top = box.Top;
        drawing.DrawRoundedRectangle(Paper, new Pen(Brushes.White, 1),
            new Rect(left, top, boxWidth, boxHeight), 16, 16);

        var x = left + padding;
        var y = top + padding;
        var sample = new PixelRect(pixel.X - 7, pixel.Y - 7, side, side);
        var clipped = PixelRect.Intersect(sample, bounds);
        var pixels = new byte[clipped.Width * clipped.Height * 4];
        Photo.CopyPixels(new Int32Rect(clipped.X, clipped.Y, clipped.Width, clipped.Height), pixels, clipped.Width * 4, 0);
        var grid = new Rect(x, y, imageSize, imageSize);
        drawing.PushClip(new RectangleGeometry(grid, 10, 10));
        drawing.DrawRectangle(Brushes.Black, null, grid);
        for (var row = 0; row < clipped.Height; row++) for (var col = 0; col < clipped.Width; col++)
        {
            var offset = (row * clipped.Width + col) * 4;
            drawing.DrawRectangle(WarmTheme.Brush(pixels[offset + 2], pixels[offset + 1], pixels[offset]), null,
                new Rect(x + (clipped.X - sample.X + col) * cell, y + (clipped.Y - sample.Y + row) * cell, cell, cell));
        }
        var cross = WarmTheme.Brush(245, 148, 92, 77);
        drawing.DrawRectangle(cross, null, new Rect(x + 56, y, cell, imageSize));
        drawing.DrawRectangle(cross, null, new Rect(x, y + 56, imageSize, cell));
        var center = new Rect(x + 56, y + 56, cell, cell);
        drawing.DrawRoundedRectangle(null, new Pen(WarmTheme.Brush(51, 31, 15), 3), center, 1.5, 1.5);
        drawing.DrawRoundedRectangle(null, new Pen(Brushes.White, 1.5), center, 1.5, 1.5);
        drawing.Pop();
        drawing.DrawRoundedRectangle(null, new Pen(WarmTheme.Brush(255, 255, 255, 179), 1), grid, 10, 10);
        var rgb = ReadColor(pixel);
        drawing.DrawRoundedRectangle(new SolidColorBrush(rgb), new Pen(Brushes.White, 1),
            new Rect(x, y + imageSize + 24, 11, 11), 5.5, 5.5);
        drawing.DrawText(MarkRenderer.Text($"{pixel.X}, {pixel.Y}", 11, Ink), new Point(x, y + imageSize + 5));
        drawing.DrawText(MarkRenderer.Text(copiedColorAt == pixel ? $"已复制 {Hex(rgb)}" : $"{Hex(rgb)}   C 复制", 10, Ink), new Point(x + 16, y + imageSize + 22));
    }

    private PixelPoint? copiedColorAt;
    internal void NotifyColorCopied(bool succeeded = true) { copiedColorAt = succeeded ? pointer : null; InvalidateVisual(); }

    public string? PointerColor() => pointer is { } at ? Hex(ReadColor(at)) : null;

    private Color ReadColor(PixelPoint at)
    {
        var pixels = new byte[4];
        Photo.CopyPixels(new Int32Rect(at.X, at.Y, 1, 1), pixels, 4, 0);
        return Color.FromRgb(pixels[2], pixels[1], pixels[0]);
    }

    private static string Hex(Color color) => $"#{color.R:X2}{color.G:X2}{color.B:X2}";

    private PixelPoint PixelAt(Point position)
    {
        var point = AtPixel(position);
        return new PixelPoint(Math.Clamp((int)Math.Round(point.X), 0, bounds.Right),
            Math.Clamp((int)Math.Round(point.Y), 0, bounds.Bottom));
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if (EditingText && e.OriginalSource is DependencyObject child && child != this)
        {
            base.OnMouseLeftButtonDown(e);
            return;
        }
        var position = PixelAt(e.GetPosition(this));
        handle = !fullScreen && selection is { } rect ? FindHandle(rect, position) : null;
        if (ResizeHandleAt(new Point(position.X, position.Y)) is not null) handle = null;
        if (handle is null)
        {
            base.OnMouseLeftButtonDown(e);
            if (e.Handled || fullScreen)
                return;
        }
        FinishText();
        BeginRegion(position);
        e.Handled = true;
    }

    private void BeginRegion(PixelPoint position, bool captureInput = true)
    {
        anchor = position;
        initial = selection ?? PixelRect.Empty;
        drag = handle is not null ? DragMode.Resizing
            : selection is { } area && area.Contains(position) ? DragMode.Moving : DragMode.Pressed;
        if (captureInput)
            CaptureMouse();
        SelectionChanged?.Invoke();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        var position = PixelAt(e.GetPosition(this));
        if (drag != DragMode.Idle)
            UpdateRegion(position);
        else
            base.OnMouseMove(e);

        SetPointer(new PixelPoint(Math.Min(position.X, bounds.Right - 1), Math.Min(position.Y, bounds.Bottom - 1)));
        UpdateCursor(position);
    }

    private void UpdateRegion(PixelPoint position)
    {
        var dx = position.X - anchor.X;
        var dy = position.Y - anchor.Y;
        if (drag == DragMode.Pressed && Math.Max(Math.Abs(dx), Math.Abs(dy)) * ViewScale >= 3)
            drag = DragMode.Creating;
        if (drag == DragMode.Creating)
            selection = RegionGeometry.Between(anchor, position);
        else if (drag == DragMode.Moving)
            selection = RegionGeometry.Move(initial, dx, dy, bounds);
        else if (drag == DragMode.Resizing && handle is { } grip)
            selection = RegionGeometry.Resize(initial, grip, position, bounds);
        InvalidateVisual();
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (!IsSelecting)
        {
            base.OnMouseLeftButtonUp(e);
            return;
        }
        EndRegion(PixelAt(e.GetPosition(this)));
        e.Handled = true;
    }

    private void EndRegion(PixelPoint position)
    {
        UpdateRegion(position);
        if (drag == DragMode.Pressed)
        {
            var hit = Array.Find(windowBounds, rect => rect.Contains(position));
            selection = hit.Width > 0 ? hit : null;
        }
        if (selection is { } area && (area.Width < 2 || area.Height < 2))
            selection = null;
        drag = DragMode.Idle;
        if (IsMouseCaptured)
            ReleaseMouseCapture();
        SelectionChanged?.Invoke();
        InvalidateVisual();
        SelectionCommitted?.Invoke();
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        if (!IsSelecting)
            return;
        selection = initial.Width > 0 ? initial : null;
        drag = DragMode.Idle;
        SelectionChanged?.Invoke();
        InvalidateVisual();
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        if (!IsSelecting)
        {
            pointer = null;
            hovered = null;
            InvalidateVisual();
        }
        base.OnMouseLeave(e);
    }

    private RegionHandle? FindHandle(PixelRect area, PixelPoint at)
    {
        foreach (var grip in new[] { RegionHandle.TopLeft, RegionHandle.TopRight, RegionHandle.BottomRight, RegionHandle.BottomLeft })
        {
            var point = RegionGeometry.HandlePoint(area, grip);
            if (Math.Abs(point.X - at.X) * ViewScale <= 7 && Math.Abs(point.Y - at.Y) * ViewScale <= 7)
                return grip;
        }
        if (at.X >= area.Left && at.X <= area.Right)
        {
            if (Math.Abs(area.Top - at.Y) * ViewScale <= 4) return RegionHandle.Top;
            if (Math.Abs(area.Bottom - at.Y) * ViewScale <= 4) return RegionHandle.Bottom;
        }
        if (at.Y >= area.Top && at.Y <= area.Bottom)
        {
            if (Math.Abs(area.Left - at.X) * ViewScale <= 4) return RegionHandle.Left;
            if (Math.Abs(area.Right - at.X) * ViewScale <= 4) return RegionHandle.Right;
        }
        return null;
    }

    private void UpdateCursor(PixelPoint at)
    {
        var point = new Point(at.X, at.Y);
        if (ResizeCursorAt(point) is { } annotationCursor) { Cursor = annotationCursor; return; }
        var grip = !fullScreen && selection is { } area ? FindHandle(area, at) : null;
        if (grip is { } selectedGrip && selection is { } selectedArea)
        {
            var handlePoint = RegionGeometry.HandlePoint(selectedArea, selectedGrip);
            Cursor = WarmCursors.Resize(this, new Vector(handlePoint.X - selectedArea.X - selectedArea.Width / 2d, handlePoint.Y - selectedArea.Y - selectedArea.Height / 2d));
            return;
        }
        Cursor = grip switch
        {
            _ when MarkAt(point) => WarmCursors.Move(this),
            _ when ActiveTool == Tool.Text && DrawingBounds.Contains(point) => Cursors.IBeam,
            _ when ActiveTool is not null => DrawingBounds.Contains(point) ? Cursors.Cross : Cursors.Arrow,
            _ when !fullScreen && selection?.Contains(at) == true => WarmCursors.Move(this),
            _ => fullScreen ? Cursors.Arrow : Cursors.Cross
        };
    }

    public bool Nudge(Key key, ModifierKeys modifiers)
    {
        if (fullScreen || IsSelecting || (selection ?? hovered) is not { } area ||
            Direction(key) is not { LengthSquared: > 0 } direction ||
            ScreenshotLayout.ArrowStep((HotkeyModifiers)modifiers) is not { } step)
            return false;
        selection = RegionGeometry.Move(area, (int)direction.X * step, (int)direction.Y * step, bounds);
        SelectionChanged?.Invoke();
        InvalidateVisual();
        return true;
    }

    internal static Rect ToRect(PixelRect rect) => new(rect.X, rect.Y, rect.Width, rect.Height);

#if DEBUG
    internal bool DebugColorCopied => copiedColorAt is not null;
    internal PixelPoint DebugPixelAt(Point local) => PixelAt(local);

    internal void DebugDrag(PixelPoint first, PixelPoint last)
    {
        handle = selection is { } rect ? FindHandle(rect, first) : null;
        BeginRegion(first, captureInput: false);
        EndRegion(last);
    }
#endif
}
