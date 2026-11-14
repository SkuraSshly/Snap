using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velos.Core.Hotkeys;
using Velos.Core.Screenshot;
using Velos.Core.Settings;
using Velos.UI;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.Screenshot;

internal class MarkCanvas : Grid
{
    private static readonly Brush Accent = new SolidColorBrush(Color.FromRgb(245, 148, 92));
    private readonly Func<Tool, ToolStyle> defaultStyle;
    private readonly Action<Tool, ToolStyle> rememberStyle;
    private readonly MarkRenderer renderer;
    private readonly PixelImage photoDrawing;
    private readonly Stack<Mark[]> undo = new();
    private readonly Stack<Mark[]> redo = new();
    private Mark[] marks = [];
    private Tool? activeTool;
    private int selected = -1;
    private Mark? draft;
    private Mark? initial;
    private Point anchor;
    private RegionHandle? resizing;
    private readonly List<Point> stroke = [];
    private TextBox? textBox;
    private Mark? textMark;
    private int textIndex = -1;
    private double viewScale = 1;
    private bool editingStyle, styleUndoRecorded;
    private Guid? lastStyleId;
    private long lastStyleTime;

    public MarkCanvas(BitmapSource photo, double pixelsPerDip, Func<Tool, ToolStyle> style, Action<Tool, ToolStyle> remember)
    {
        Photo = photo.Format == PixelFormats.Bgr32 || photo.Format == PixelFormats.Bgra32 || photo.Format == PixelFormats.Pbgra32
            ? photo : new FormatConvertedBitmap(photo, PixelFormats.Bgra32, null, 0);
        PixelScale = pixelsPerDip;
        renderer = new MarkRenderer(Photo);
        photoDrawing = new PixelImage(Photo);
        defaultStyle = style;
        rememberStyle = remember;
        ClipToBounds = true;
        RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.NearestNeighbor);
    }

    public BitmapSource Photo { get; }
    public double PixelScale { get; set; }
    public double ViewScale
    {
        get => viewScale;
        set
        {
            viewScale = value;
            InvalidateVisual();
        }
    }
    public Rect PhotoBounds => new(0, 0, Photo.PixelWidth, Photo.PixelHeight);
    protected virtual Rect DrawingBounds => PhotoBounds;
    public Tool? ActiveTool => activeTool;
    public Tool? DisplayedTool => activeTool ?? (selected >= 0 ? marks[selected].Tool : null);
    public ToolStyle? DisplayedStyle => selected >= 0 ? marks[selected].Style
        : activeTool is { } tool ? defaultStyle(tool) : null;
    public bool CanUndo => undo.Count > 0;
    public bool CanRedo => redo.Count > 0;
    public bool HasMarks => marks.Length > 0 || EditingText;
    public event Action? Changed;

    public void SelectTool(Tool tool)
    {
        FinishText();
        var toggleOff = activeTool == tool;
        activeTool = toggleOff ? null : tool;
        Refresh();
    }
    public bool CancelTool()
    {
        if (activeTool is null) return false;
        FinishText(); activeTool = null; Refresh(); return true;
    }

    public void SetStyle(ToolStyle style)
    {
        if ((selected >= 0 ? marks[selected].Tool : activeTool) is not { } tool)
            return;
        style = ToolInfo.Normalize(tool, style, allowTransparent: true);
        if (DisplayedStyle == style) return;
        rememberStyle(tool, style);
        if (textMark is not null && tool == Tool.Text) { textMark = textMark with { Style = style }; UpdateTextStyle(); }
        if (selected >= 0)
        {
            var replacement = (Mark[])marks.Clone();
            replacement[selected] = replacement[selected] with { Style = style };
            var now = Environment.TickCount64;
            if (!(editingStyle && styleUndoRecorded) && (lastStyleId != marks[selected].Id || now - lastStyleTime > 1000))
            { undo.Push(marks); redo.Clear(); }
            styleUndoRecorded = editingStyle;
            lastStyleId = marks[selected].Id; lastStyleTime = now;
            marks = replacement; Refresh();
        }
        else
        {
            Refresh();
        }
    }

    public void BeginStyleEdit() { if (!editingStyle) { editingStyle = true; styleUndoRecorded = false; } }
    public void EndStyleEdit() { editingStyle = styleUndoRecorded = false; }

    public void Undo()
    {
        FinishText();
        if (!undo.TryPop(out var previous))
            return;
        redo.Push(marks);
        Restore(previous);
        Refresh();
    }

    public void Redo()
    {
        FinishText();
        if (!redo.TryPop(out var next))
            return;
        undo.Push(marks);
        Restore(next);
        Refresh();
    }

    private void Commit(Mark[] next)
    {
        lastStyleId = null;
        undo.Push(marks);
        redo.Clear();
        marks = next;
        Refresh();
    }
    private void Restore(Mark[] next)
    {
        var identity = selected >= 0 ? marks[selected].Id : (Guid?)null;
        marks = next;
        selected = identity is { } id ? Array.FindIndex(marks, mark => mark.Id == id) : -1;
        lastStyleId = null;
        styleUndoRecorded = false;
    }

    protected void Refresh()
    {
        InvalidateVisual();
        Changed?.Invoke();
    }

    protected Point AtPixel(Point point) => new(point.X / ViewScale, point.Y / ViewScale);
    protected Point AtView(Point point) => new(point.X * ViewScale, point.Y * ViewScale);
    protected Rect AtView(Rect rect) => new(AtView(rect.TopLeft), AtView(rect.BottomRight));

    protected override void OnRender(DrawingContext drawing)
    {
        base.OnRender(drawing);
        RenderContents(drawing);
    }

    protected virtual void RenderContents(DrawingContext drawing)
    {
        DrawPhoto(drawing);
        DrawMarkup(drawing, DrawingBounds);
    }

    protected void DrawPhoto(DrawingContext drawing) => photoDrawing.Draw(drawing, AtView(PhotoBounds));

    protected void DrawMarkup(DrawingContext drawing, Rect bounds)
    {
        if (bounds.IsEmpty || bounds.Width < 1 || bounds.Height < 1)
            return;
        drawing.PushTransform(new ScaleTransform(ViewScale, ViewScale));
        drawing.PushClip(new RectangleGeometry(bounds));
        renderer.Draw(drawing, marks, draft, textBox is not null ? textIndex : initial is not null ? selected : -1);
        if (selected >= 0 && draft is null && textBox is null)
        {
            var mark = marks[selected];
            var thickness = 1 / ViewScale;
            var pen = new Pen(Accent, thickness) { DashStyle = DashStyles.Dash };
            if (!mark.IsLine)
                drawing.DrawRectangle(null, pen, mark.Bounds);
            foreach (var (_, point) in mark.Handles())
                drawing.DrawEllipse(Brushes.White, new Pen(Accent, thickness), point, 3 * thickness, 3 * thickness);
        }
        drawing.Pop();
        drawing.Pop();
    }

    protected bool StartMark(Point at, int clickCount, bool captureInput = true)
    {
        if (EditingText) { FinishText(); if (activeTool == Tool.Text) return true; }
        anchor = at;
        resizing = null;
        if (ResizeHandleAt(at) is { } nearest)
        {
            resizing = nearest;
            initial = draft = marks[selected];
            if (captureInput) CaptureMouse();
            return true;
        }
        if (DrawingBounds.IsEmpty || !DrawingBounds.Contains(at)) return false;
        for (var i = marks.Length - 1; i >= 0; i--)
        {
            if (!marks[i].Hit(at, marks[i].Scale))
                continue;
            selected = i;
            lastStyleId = null;
            initial = draft = marks[i];
            if (captureInput)
                CaptureMouse();
            Refresh();
            return true;
        }
        selected = -1;
        if (activeTool is not { } tool)
        {
            Refresh();
            return false;
        }
        var newMark = new Mark(tool, defaultStyle(tool), PixelScale, tool is Tool.Pen or Tool.Highlighter ? [at] : [at, at]);
        if (tool == Tool.Text)
        {
            StartText(newMark, -1);
            return true;
        }
        if (tool == Tool.Counter)
        {
            var number = marks.Where(m => m.Tool == Tool.Counter).Select(m => m.Number).DefaultIfEmpty().Max() + 1;
            Commit([.. marks, newMark with { Number = number }]);
            return true;
        }
        stroke.Clear();
        stroke.Add(at);
        draft = newMark;
        if (captureInput)
            CaptureMouse();
        Refresh();
        return true;
    }

    protected bool MoveMark(Point at, bool constrain)
    {
        if (draft is null)
            return false;
        if (initial is { } old)
        {
            if (resizing is { } handle)
            {
                var resized = old.Resize(handle, Clamp(at, DrawingBounds), constrain);
                if (Meaningful(resized))
                    draft = resized;
            }
            else
            {
                var offset = ConstrainMove(old, at - anchor);
                if (offset.Length >= old.Scale || !draft.Points.SequenceEqual(old.Points)) draft = old.Move(offset);
            }
        }
        else if (draft.Tool is Tool.Pen or Tool.Highlighter)
        {
            at = Clamp(at, DrawingBounds);
            stroke.Add(at);
            draft = draft with { Points = stroke.ToArray() };
        }
        else
        {
            at = Mark.Constrain(anchor, Clamp(at, DrawingBounds), draft.IsBox, constrain);
            // Swift 先约束形状，再与画布相交；触边时允许被截短。
            at = Clamp(at, DrawingBounds);
            draft = draft with { Points = [anchor, at] };
        }
        InvalidateVisual();
        return true;
    }

    protected bool EndMark(Point at, bool constrain)
    {
        if (draft is null)
            return false;
        // Swift 在 mouseDragged 中更新形状，松开不新增笔画点或重新应用 Shift。
        var finished = draft;
        draft = null;
        resizing = null;
        stroke.Clear();
        if (initial is { } previous)
        {
            initial = null;
            if (!previous.Points.SequenceEqual(finished.Points))
            {
                var replacement = (Mark[])marks.Clone();
                replacement[selected] = finished;
                Commit(replacement);
            }
        }
        else if (Meaningful(finished))
            Commit([.. marks, finished]);
        if (IsMouseCaptured)
            ReleaseMouseCapture();
        Refresh();
        return true;
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if (textBox is not null && e.OriginalSource is DependencyObject origin && (origin == textBox || textBox.IsAncestorOf(origin)))
        { base.OnMouseLeftButtonDown(e); return; }
        if (StartMark(AtPixel(e.GetPosition(this)), e.ClickCount))
            e.Handled = true;
        base.OnMouseLeftButtonDown(e);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (MoveMark(AtPixel(e.GetPosition(this)), Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)))
            e.Handled = true;
        if (this is not CaptureSurface) Cursor = ResizeCursorAt(AtPixel(e.GetPosition(this))) ??
            (MarkAt(AtPixel(e.GetPosition(this))) ? WarmCursors.Move(this) : activeTool == Tool.Text ? Cursors.IBeam : activeTool is not null ? Cursors.Cross : Cursors.Arrow);
        base.OnMouseMove(e);
    }
    protected RegionHandle? ResizeHandleAt(Point at)
    {
        if (selected < 0 || DrawingBounds.IsEmpty) return null;
        var area = DrawingBounds; area.Inflate(PixelScale, PixelScale);
        var visible = marks[selected].Handles().Where(item => area.Contains(item.Point)).OrderBy(item => (item.Point - at).LengthSquared).ToArray();
        return visible.Length > 0 && (at - visible[0].Point).Length <= 7 / ViewScale ? visible[0].Handle : null;
    }
    protected bool MarkAt(Point at) => DrawingBounds.Contains(at) && marks.Any(mark => mark.Hit(at, mark.Scale));
    protected Cursor? ResizeCursorAt(Point at)
    {
        if ((resizing ?? ResizeHandleAt(at)) is not { } grip || selected < 0) return null;
        if (marks[selected].IsLine)
        {
            var d = marks[selected].Last - marks[selected].First;
            return WarmCursors.Resize(this, grip == RegionHandle.TopLeft ? -d : d);
        }
        var frame = marks[selected].Frame;
        return WarmCursors.Resize(this, Mark.HandlePoint(frame, grip) - new Point(frame.X + frame.Width / 2, frame.Y + frame.Height / 2));
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (EndMark(AtPixel(e.GetPosition(this)), Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)))
            e.Handled = true;
        base.OnMouseLeftButtonUp(e);
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        resizing = null;
        if (draft is not null)
        {
            draft = initial = null;
            stroke.Clear();
            Refresh();
        }
        base.OnLostMouseCapture(e);
    }

    private static Point Clamp(Point point, Rect bounds) => new(
        Math.Clamp(point.X, bounds.Left, bounds.Right), Math.Clamp(point.Y, bounds.Top, bounds.Bottom));

    private Vector ConstrainMove(Mark mark, Vector delta)
    {
        var box = mark.Bounds;
        var area = DrawingBounds;
        static double Limit(double value, double lower, double upper) => lower <= upper ? Math.Clamp(value, lower, upper) : value;
        return new Vector(Limit(delta.X, area.Left - box.Left, area.Right - box.Right), Limit(delta.Y, area.Top - box.Top, area.Bottom - box.Bottom));
    }

    private static bool Meaningful(Mark mark) => mark.IsBox
        ? mark.Frame.Width >= 3 * mark.Scale && mark.Frame.Height >= 3 * mark.Scale
        : mark.IsLine ? (mark.Last - mark.First).Length >= 4 * mark.Scale
        : mark.Tool is not (Tool.Pen or Tool.Highlighter) || mark.Points.Length >= 2;

    private void StartText(Mark mark, int index)
    {
        textIndex = index;
        textMark = mark;
        var position = AtView(mark.First);
        textBox = new TextBox
        {
            Text = mark.Text, FontFamily = MarkRenderer.TextFont, FontWeight = FontWeights.SemiBold,
            FontSize = Math.Max(1, mark.Size * ViewScale), AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap,
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(position.X, position.Y, 0, 0), Padding = new Thickness(0), BorderBrush = new SolidColorBrush(Color.FromArgb(179, 255, 255, 255)),
            BorderThickness = new Thickness(.5), HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden
        };
        textBox.TextChanged += (_, _) => FitTextBox();
        Children.Add(textBox);
        UpdateTextStyle();
        textBox.Focus();
        textBox.SelectAll();
        Refresh();
    }
    private void UpdateTextStyle()
    {
        if (textBox is not { } box || textMark is not { } mark) return;
        var rgb = mark.Style.Rgb;
        var color = Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
        var ink = new SolidColorBrush(color);
        box.Foreground = mark.Style.Filled ? MarkRenderer.TextContrast(color) : ink;
        box.CaretBrush = box.Foreground;
        box.Background = mark.Style.Filled ? ink : Brushes.Transparent;
        box.Opacity = mark.Style.Opacity;
        box.FontSize = Math.Max(1, mark.Size * ViewScale);
        FitTextBox();
    }
    private void FitTextBox()
    {
        if (textBox is not { } box) return;
        var layout = MarkRenderer.Text(box.Text.Length == 0 ? " " : box.Text, box.FontSize, box.Foreground);
        box.Width = Math.Max(20 * PixelScale * ViewScale, Math.Ceiling(layout.WidthIncludingTrailingWhitespace) + 4);
        box.Height = Math.Ceiling(layout.Height) + 1;
    }

    public void FinishText()
    {
        if (textBox is not { } box || textMark is not { } mark)
            return;
        var index = textIndex;
        textBox = null;
        textMark = null;
        textIndex = -1;
        Children.Remove(box);
        var value = box.Text;
        if (!string.IsNullOrWhiteSpace(value) && index < 0)
            Commit([.. marks, mark with { Text = value }]);
        else if (index >= 0 && value != mark.Text)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                selected = -1;
                Commit(marks.Where((_, i) => i != index).ToArray());
            }
            else
            {
                var replacement = (Mark[])marks.Clone();
                replacement[index] = mark with { Text = value };
                Commit(replacement);
            }
        }
        Refresh();
    }

    public bool EditingText => textBox is not null;
    internal void FocusTextEditor() => textBox?.Focus();

    public bool HandleEditingKey(Key key, ModifierKeys modifiers)
    {
        if (EditingText)
        {
            if (key == Key.Escape || key == Key.Enter && !modifiers.HasFlag(ModifierKeys.Shift))
            {
                FinishText();
                return true;
            }
            return false;
        }
        if (key == Key.Z && modifiers == ModifierKeys.Control)
        {
            Undo();
            return true;
        }
        if (key == Key.Z && modifiers == (ModifierKeys.Control | ModifierKeys.Shift) ||
            key == Key.Y && modifiers == ModifierKeys.Control)
        {
            Redo();
            return true;
        }
        if (selected < 0)
            return false;
        if (key == Key.Escape)
        {
            selected = -1;
            Refresh();
            return true;
        }
        if (key is Key.Delete or Key.Back && modifiers == ModifierKeys.None)
        {
            var index = selected;
            selected = -1;
            Commit(marks.Where((_, i) => i != index).ToArray());
            return true;
        }
        var delta = Direction(key);
        if (delta != default && ScreenshotLayout.ArrowStep((HotkeyModifiers)modifiers) is { } step)
        {
            var replacement = (Mark[])marks.Clone();
            var original = replacement[selected];
            var offset = ConstrainMove(original, delta * step);
            if (offset != default)
            {
                replacement[selected] = original.Move(offset);
                Commit(replacement);
            }
            return true;
        }
        return false;
    }

    protected static Vector Direction(Key key) => key switch
    {
        Key.Left => new Vector(-1, 0), Key.Right => new Vector(1, 0),
        Key.Up => new Vector(0, -1), Key.Down => new Vector(0, 1), _ => default
    };

    public virtual BitmapSource RenderCrop(PixelRect crop)
    {
        FinishText();
        if (crop.Width <= 0 || crop.Height <= 0)
            throw new InvalidOperationException("请先选择截图区域。");
        if (marks.Length == 0)
        {
            var stride = checked(crop.Width * 4);
            var pixels = new byte[checked(stride * crop.Height)];
            Photo.CopyPixels(new Int32Rect(crop.X, crop.Y, crop.Width, crop.Height), pixels, stride, 0);
            var image = BitmapSource.Create(crop.Width, crop.Height, 96, 96, Photo.Format, null, pixels, stride);
            image.Freeze();
            return image;
        }
        const int tileSize = 4096;
        if (crop.Width <= tileSize && crop.Height <= tileSize)
            return RenderTile(crop);
        var outputStride = checked(crop.Width * 4);
        var output = new byte[checked(outputStride * crop.Height)];
        for (var y = 0; y < crop.Height; y += tileSize)
        for (var x = 0; x < crop.Width; x += tileSize)
        {
            var tile = new PixelRect(crop.X + x, crop.Y + y, Math.Min(tileSize, crop.Width - x), Math.Min(tileSize, crop.Height - y));
            RenderTile(tile).CopyPixels(output, outputStride, checked(y * outputStride + x * 4));
        }
        var full = BitmapSource.Create(crop.Width, crop.Height, 96, 96, PixelFormats.Pbgra32, null, output, outputStride);
        full.Freeze();
        return full;
    }

    private BitmapSource RenderTile(PixelRect crop)
    {
        var visual = new DrawingVisual();
        using (var drawing = visual.RenderOpen())
        {
            drawing.PushTransform(new TranslateTransform(-crop.X, -crop.Y));
            photoDrawing.Draw(drawing, PhotoBounds, new Rect(crop.X, crop.Y, crop.Width, crop.Height));
            renderer.Draw(drawing, marks);
            drawing.Pop();
        }
        var result = new RenderTargetBitmap(crop.Width, crop.Height, 96, 96, PixelFormats.Pbgra32);
        result.Render(visual);
        result.Freeze();
        return result;
    }

#if DEBUG
    internal IReadOnlyList<Mark> DebugMarks => marks;
    internal int DebugSelected => selected;
    internal Mark? DebugDraft => draft;
    internal TextBox? DebugTextEditor => textBox;
    internal Cursor? DebugResizeCursorAt(Point point) => ResizeCursorAt(point);
    internal void DebugLoseMouseCapture() => OnLostMouseCapture(new MouseEventArgs(Mouse.PrimaryDevice, Environment.TickCount));
    internal bool DebugPress(Point point) => StartMark(point, 1, false);
    internal void DebugMove(Point point, bool shift = false) => MoveMark(point, shift);
    internal void DebugRelease(Point point, bool shift = false) => EndMark(point, shift);

    internal bool DebugStroke(Point first, Point last, bool shift = false)
    {
        if (!StartMark(first, 1, captureInput: false))
            return false;
        MoveMark(last, shift);
        EndMark(last, shift);
        return true;
    }

    internal void DebugText(string text)
    {
        textBox!.Text = text;
        FinishText();
    }
#endif
}
