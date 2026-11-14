using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Velos.Core.Screenshot;
using Velos.Core.LongCapture;
using Velos.UI;
using Velos.Windows.Capture;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.Screenshot;

internal sealed class PinWindow : Window
{
    private readonly ShotImage image;
    private readonly Border border, indicator;
    private readonly TextBlock indicatorText;
    private readonly PixelImageView visual;
    private readonly ScrollViewer? viewport;
    private readonly ScrollAxis? axis;
    private readonly DispatcherTimer indicatorTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private bool closed, moving;
    private double zoom = 1;
    private double minimumZoom = .1;
    private sealed record EdgeDrag(PinEdge Edge, PixelRect Bounds, System.Drawing.Point Pointer, double Zoom, double OffsetPixels);
    private EdgeDrag? edgeDrag;

    public PinWindow(ShotImage image, Action copy, Action saveAs)
    {
        this.image = image; axis = PinLayout.LongAxis(new(image.Width, image.Height));
        Title = "Velos 钉图"; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.Manual; ShowInTaskbar = false; ShowActivated = true;
        Topmost = true; AllowsTransparency = true; Background = Brushes.Transparent;
        visual = new PixelImageView(ShotEncoding.Decode(image.Png));
        UIElement photo = visual;
        if (axis is { } direction)
        {
            viewport = new ScrollViewer { Content = visual, Style = CaptureChrome.OverlayScrollStyle, HorizontalScrollBarVisibility = direction == ScrollAxis.Horizontal ? ScrollBarVisibility.Auto : ScrollBarVisibility.Hidden,
                VerticalScrollBarVisibility = direction == ScrollAxis.Vertical ? ScrollBarVisibility.Auto : ScrollBarVisibility.Hidden };
            photo = viewport;
        }
        // 描边叠加在图片上，不能占用布局尺寸，否则 100% 显示会丢失边缘像素。
        border = new Border { BorderBrush = WarmTheme.Brush(255, 255, 255, 89), BorderThickness = new Thickness(1), IsHitTestVisible = false };
        indicatorText = new TextBlock { FontSize = 12, FontFamily = WarmTheme.Text, FontWeight = FontWeights.SemiBold, Foreground = CaptureChrome.Ink, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center };
        indicator = CaptureChrome.Pill(indicatorText); indicator.IsHitTestVisible = false; indicator.Visibility = Visibility.Collapsed;
        indicator.HorizontalAlignment = HorizontalAlignment.Center; indicator.VerticalAlignment = VerticalAlignment.Center;
        SizeChanged += (_, _) => indicator.MaxWidth = Math.Max(1, ActualWidth - 12);
        // Layered windows pass fully transparent PNG pixels through before WPF hit testing.
        // This visually transparent edge band keeps all eight grips usable without drawing handles.
        var edgeHit = new Border { BorderBrush = WarmTheme.Brush(255, 255, 255, 1), BorderThickness = new Thickness(6), IsHitTestVisible = false };
        Content = new Grid { ClipToBounds = true, Background = Brushes.Transparent, Children = { photo, edgeHit, border, indicator } };
        Activated += (_, _) => { border.BorderBrush = CaptureChrome.Apricot; border.BorderThickness = new Thickness(2); };
        Deactivated += (_, _) => { border.BorderBrush = WarmTheme.Brush(255, 255, 255, 89); border.BorderThickness = new Thickness(1); };
        PreviewMouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2 && !Interaction.IsControl(e.OriginalSource)) { Close(); e.Handled = true; return; }
            // Use the input event's point: GetCursorPos can already be at the end of a fast drag
            // while WPF is still dispatching its initial button-down message.
            var point = e.GetPosition(this); var edge = EdgeAt(point);
            if (edge != PinEdge.None) { var screen = PointToScreen(point); BeginEdgeDrag(edge, new((int)Math.Round(screen.X), (int)Math.Round(screen.Y))); e.Handled = true; return; }
            if (Interaction.IsControl(e.OriginalSource)) return;
            Activate(); Focus(); moving = true;
            try { DragMove(); } catch (InvalidOperationException) { } finally { moving = false; RefreshCursor(); }
            e.Handled = true;
        };
        PreviewMouseMove += (_, e) => { if (edgeDrag is not null) ResizeEdge(Desktop.Pointer()); else RefreshCursor(); };
        PreviewMouseLeftButtonUp += (_, e) => { if (edgeDrag is not null) { ResizeEdge(Desktop.Pointer()); EndEdgeDrag(); e.Handled = true; } };
        MouseLeave += (_, _) => { if (edgeDrag is null) ClearResizeCursor(); };
        LostMouseCapture += (_, _) => { if (edgeDrag is not null) { edgeDrag = null; RefreshCursor(); } };
        PreviewMouseWheel += (_, e) =>
        {
            if (e.Delta == 0) return;
#if DEBUG
            var before = zoom;
#endif
            Wheel(e.Delta, Keyboard.Modifiers, e.GetPosition(this)); e.Handled = true;
#if DEBUG
            DebugWheelInput?.Invoke(e.Delta, Keyboard.Modifiers, before, zoom, DebugScrollOffset);
#endif
        };
        void Copy() { copy(); ShowIndicator("已复制"); }
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape && Keyboard.Modifiers == ModifierKeys.None) { if (edgeDrag is not null) EndEdgeDrag(cancel: true); else Close(); }
            else if (e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.Control) Copy();
            else if (e.Key == Key.S && Keyboard.Modifiers == ModifierKeys.Control) saveAs();
            else return;
            e.Handled = true;
        };
        var menu = new ContextMenu();
        AddMenu(menu, "复制", Copy); AddMenu(menu, "存储为…", saveAs); menu.Items.Add(new Separator());
        var percentage = new MenuItem { IsEnabled = false }; menu.Items.Add(percentage);
        AddMenu(menu, "原始大小", () => Zoom(1, Center), id: "PinZoomReset");
        var opacity = new MenuItem { Header = "透明度" };
        foreach (var percent in new[] { 100, 80, 60, 40 }) { var item = new MenuItem { Header = percent + "%", IsCheckable = true }; item.Click += (_, _) => SetOpacity(percent / 100d); opacity.Items.Add(item); }
        menu.Opened += (_, _) => { percentage.Header = $"缩放 {zoom * 100:0}% · {(axis is null ? "滚轮／拖动边缘" : "Alt＋滚轮／拖动边缘")}"; foreach (MenuItem item in opacity.Items) item.IsChecked = Math.Abs(Opacity * 100 - int.Parse(((string)item.Header).TrimEnd('%'))) < 1; };
        menu.Items.Add(opacity); menu.Items.Add(new Separator()); AddMenu(menu, "关闭（双击 / Esc）", Close); ContextMenu = menu;
        indicatorTimer.Tick += (_, _) => HideIndicator();
        Closed += (_, _) => { closed = true; edgeDrag = null; if (IsMouseCaptured) ReleaseMouseCapture(); ClearResizeCursor(); indicatorTimer.Stop(); };
    }
    private Point Center => new(ActualWidth / 2, ActualHeight / 2);
    private void Wheel(int delta, ModifierKeys modifiers, Point anchor)
    {
        if (edgeDrag is not null || moving || delta == 0) return;
        if (modifiers.HasFlag(ModifierKeys.Control)) SetOpacity(PinLayout.WheelOpacity(Opacity, delta));
        else if (viewport is not null && !modifiers.HasFlag(ModifierKeys.Alt))
        {
            var offset = axis == ScrollAxis.Vertical ? viewport.VerticalOffset : viewport.HorizontalOffset;
            ScrollPixels((offset - delta / 120d * 12) * VisualTreeHelper.GetDpi(this).DpiScaleX);
        }
        else {
            var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
            var lower = Math.Max(minimumZoom, 20 * dpi / Math.Min(image.Width, image.Height));
            Zoom(PinLayout.WheelZoom(zoom, delta, lower), anchor, interactive: true);
        }
    }
    public void ShowPinned()
    {
        var handle = new WindowInteropHelper(this).EnsureHandle(); Desktop.Position(handle, new PixelRect(image.Source.X, image.Source.Y, 64, 64));
        var placement = PinLayout.Initial(new(image.Width, image.Height), image.Source, image.Display.Bounds, image.Display.WorkArea);
        zoom = placement.Zoom; minimumZoom = Math.Min(.1, zoom); Position(PixelRect.Round(placement.Bounds), true); SizePhoto();
        Activate(); Focus(); RefreshCursor();
    }
    private void Position(PixelRect bounds, bool show = false)
    {
        var hwnd = new WindowInteropHelper(this).EnsureHandle(); Desktop.Position(hwnd, bounds);
        if (show) Show(); Desktop.Position(hwnd, bounds);
    }
    private void SizePhoto()
    {
        var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        if (viewport is not null) { visual.Width = image.Width / dpi * zoom; visual.Height = image.Height / dpi * zoom; }
        RenderOptions.SetBitmapScalingMode(visual, zoom < 1 ? BitmapScalingMode.HighQuality : BitmapScalingMode.NearestNeighbor);
    }
    private void Zoom(double requested, Point anchor, bool interactive = false)
    {
        if (ActualWidth <= 0 || ActualHeight <= 0) return;
        if (interactive && Math.Abs(requested - zoom) < .0000001) { ShowIndicator($"{zoom * 100:0}%"); return; }
        var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX; var pointer = PointToScreen(anchor);
        var work = Desktop.Displays().FirstOrDefault(d => d.Bounds.Contains((int)pointer.X, (int)pointer.Y))?.WorkArea ?? image.Display.WorkArea;
        // 原生窗口尺寸是当前值，快速连续滚轮时不能依赖尚未布局的 ActualWidth。
        var current = Desktop.WindowRectangle(new WindowInteropHelper(this).Handle);
        var placement = PinLayout.Zoom(new(image.Width, image.Height), current, zoom, requested,
            new((float)(anchor.X * dpi), (float)(anchor.Y * dpi)), work, axis, interactive ? 20 * dpi : 0, minimumZoom);
        var ratio = placement.Zoom / zoom; var offset = axis == ScrollAxis.Vertical ? viewport?.VerticalOffset ?? 0 : viewport?.HorizontalOffset ?? 0;
        var anchorAlong = (axis == ScrollAxis.Vertical ? anchor.Y : anchor.X) * dpi;
        var oldLength = axis == ScrollAxis.Vertical ? current.Height : current.Width;
        var newLength = axis == ScrollAxis.Vertical ? placement.Bounds.Height : placement.Bounds.Width;
        var newAnchor = oldLength > 0 ? anchorAlong / oldLength * newLength : anchorAlong;
        var newOffsetPixels = (offset * dpi + anchorAlong) * ratio - newAnchor;
        zoom = placement.Zoom; Position(PixelRect.Round(placement.Bounds)); SizePhoto();
        ScrollPixels(newOffsetPixels);
        ShowIndicator($"{zoom * 100:0}%"); RefreshCursor();
    }
    private PinEdge EdgeUnderPointer()
    {
        var bounds = Desktop.WindowRectangle(new WindowInteropHelper(this).Handle); var pointer = Desktop.Pointer();
        var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        return EdgeAt(new((pointer.X - bounds.X) / dpi, (pointer.Y - bounds.Y) / dpi));
    }
    private PinEdge EdgeAt(Point point) {
        var bounds = Desktop.WindowRectangle(new WindowInteropHelper(this).Handle); var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        return PinLayout.EdgeAt(new((float)point.X, (float)point.Y), new((float)(bounds.Width / dpi), (float)(bounds.Height / dpi)));
    }
    private void BeginEdgeDrag(PinEdge edge, System.Drawing.Point pointer)
    {
        Activate(); Focus();
        var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        edgeDrag = new(edge, Desktop.WindowRectangle(new WindowInteropHelper(this).Handle), pointer, zoom,
            (axis == ScrollAxis.Vertical ? viewport?.VerticalOffset ?? 0 : viewport?.HorizontalOffset ?? 0) * dpi);
        if (!CaptureMouse()) edgeDrag = null;
        RefreshCursor();
    }
    private void ResizeEdge(System.Drawing.Point pointer)
    {
        if (edgeDrag is not { } drag) return;
        var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var work = Desktop.Displays().FirstOrDefault(d => d.Bounds.Contains(pointer))?.WorkArea ?? image.Display.WorkArea;
        var placement = PinLayout.ResizeFromEdge(new(image.Width, image.Height), drag.Bounds, drag.Zoom, drag.Edge,
            new(pointer.X - drag.Pointer.X, pointer.Y - drag.Pointer.Y), work, axis, 40 * dpi, minimumZoom);
        var offset = drag.OffsetPixels * placement.Zoom / drag.Zoom;
        zoom = placement.Zoom; Position(PixelRect.Round(placement.Bounds)); SizePhoto();
        ScrollPixels(offset); RefreshCursor();
    }
    private void ScrollPixels(double offset)
    {
        if (viewport is null) return;
        UpdateLayout(); var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
        if (axis == ScrollAxis.Vertical) viewport.ScrollToVerticalOffset(offset / dpi);
        else viewport.ScrollToHorizontalOffset(offset / dpi);
        // ScrollViewer queues offset commands. Commit layout before another wheel event reads it,
        // otherwise a burst reuses the previous offset and loses scroll/anchor displacement.
        UpdateLayout();
    }
    private void EndEdgeDrag(bool cancel = false)
    {
        var drag = edgeDrag; edgeDrag = null;
        if (cancel && drag is not null) { zoom = drag.Zoom; Position(drag.Bounds); SizePhoto(); ScrollPixels(drag.OffsetPixels); }
        if (IsMouseCaptured) ReleaseMouseCapture();
        RefreshCursor();
    }
    private void RefreshCursor()
    {
        if (closed) return;
        var edge = edgeDrag?.Edge ?? EdgeUnderPointer();
        if (edge == PinEdge.None) { ClearResizeCursor(); return; }
        Cursor = WarmCursors.Resize(this, new Vector(edge.HasFlag(PinEdge.Left) ? -1 : edge.HasFlag(PinEdge.Right) ? 1 : 0,
            edge.HasFlag(PinEdge.Top) ? -1 : edge.HasFlag(PinEdge.Bottom) ? 1 : 0));
        ForceCursor = true;
    }
    private void ClearResizeCursor() { ClearValue(CursorProperty); ForceCursor = false; }
    protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
    {
        base.OnDpiChanged(oldDpi, newDpi);
        // 保持物理像素缩放比，不能把源显示器的 Scale 当成当前显示器的 DPI。
        if (visual is null || !IsLoaded) return;
        Width = ActualWidth * oldDpi.DpiScaleX / newDpi.DpiScaleX;
        Height = ActualHeight * oldDpi.DpiScaleY / newDpi.DpiScaleY;
        SizePhoto();
        if (edgeDrag is { } drag) Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() => { if (ReferenceEquals(drag, edgeDrag)) ResizeEdge(Desktop.Pointer()); }));
    }
    private void SetOpacity(double value) { Opacity = value; ShowIndicator($"透明度 {value * 100:0}%"); }
    private void ShowIndicator(string text, int milliseconds = 1100)
    {
        indicatorText.Text = text; indicator.Visibility = Visibility.Visible;
        indicatorTimer.Stop(); indicatorTimer.Interval = TimeSpan.FromMilliseconds(milliseconds); indicatorTimer.Start();
    }
    private void HideIndicator()
    {
        indicatorTimer.Stop(); if (!closed) indicator.Visibility = Visibility.Collapsed;
    }
    private static void AddMenu(ItemsControl menu, string title, Action action, string gesture = "", string? id = null)
    { var item = new MenuItem { Header = title, InputGestureText = gesture }; if (id is not null) AutomationProperties.SetAutomationId(item, id); item.Click += (_, _) => action(); menu.Items.Add(item); }
#if DEBUG
    internal event Action<int, ModifierKeys, double, double, double>? DebugWheelInput;
    internal double DebugZoom => zoom;
    internal FrameworkElement DebugPhoto => visual;
    internal bool DebugCanScroll => viewport is not null && (axis == ScrollAxis.Vertical ? viewport.ScrollableHeight > 0 : viewport.ScrollableWidth > 0);
    internal void DebugZoomTo(double target) => Zoom(target, new Point(ActualWidth / 2, ActualHeight / 2));
    internal void DebugWheel(int delta, ModifierKeys modifiers, Point anchor) => Wheel(delta, modifiers, anchor);
    internal void DebugBeginEdge(PinEdge edge, System.Drawing.Point pointer) => BeginEdgeDrag(edge, pointer);
    internal void DebugResizeEdge(System.Drawing.Point pointer) => ResizeEdge(pointer);
    internal void DebugEndEdge(bool cancel = false) => EndEdgeDrag(cancel);
    internal bool DebugResizing => edgeDrag is not null;
    internal double DebugScrollOffset => axis == ScrollAxis.Vertical ? viewport?.VerticalOffset ?? 0 : viewport?.HorizontalOffset ?? 0;
    internal void DebugScrollTo(double offset) { if (axis == ScrollAxis.Vertical) viewport?.ScrollToVerticalOffset(offset); else viewport?.ScrollToHorizontalOffset(offset); }
#endif
}
