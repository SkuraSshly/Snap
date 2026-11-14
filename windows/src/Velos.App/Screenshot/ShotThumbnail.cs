using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Velos.Core.Screenshot;
using Velos.Core.LongCapture;
using Velos.Windows.Capture;
using Velos.UI;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.Screenshot;

internal sealed class ShotThumbnail : Window
{
    private readonly DispatcherTimer lifetime = new() { Interval = TimeSpan.FromSeconds(6) };
    private readonly StackPanel tools = new() { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
    private readonly Button close;
    private readonly Button saveButton;
    private Point? dragStart;
    private bool captureHidden;

    public ShotThumbnail(ShotImage image, Action open, Action save, Action pin, Action reveal, Action<string>? error = null)
    {
        Image = image;
        Title = "Velos 截图缩略图";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.Manual;
        ShowActivated = false;
        ShowInTaskbar = false;
        Topmost = true;
        AllowsTransparency = true;
        Background = Brushes.Transparent;

        var size = ScreenshotLayout.ThumbnailSize(new(image.Width, image.Height), image.Scale); Width = size.Width; Height = size.Height;
        var previewWidth = Math.Min(image.Width, (int)Math.Ceiling(Width * image.Scale));
        var previewHeight = Math.Min(image.Height, (int)Math.Ceiling(Height * image.Scale));
        var preview = new Image
        {
            Source = image.LongAxis == ScrollAxis.Horizontal
                ? ShotEncoding.Decode(image.Png, previewHeight: previewHeight)
                : ShotEncoding.Decode(image.Png, previewWidth),
            Width = Width, Height = Height, Stretch = Stretch.UniformToFill, Cursor = Cursors.Hand
        };
        RenderOptions.SetBitmapScalingMode(preview, BitmapScalingMode.HighQuality);
        var rounded = new Border { CornerRadius = new CornerRadius(12), Background = CaptureChrome.Paper, Child = preview };
        rounded.SizeChanged += (_, _) =>
            rounded.Clip = new RectangleGeometry(new Rect(0, 0, rounded.ActualWidth, rounded.ActualHeight), 12, 12);
        close = CaptureChrome.IconButton("\ue711", "关闭缩略图", () => WarmMotion.CloseWindow(this));
        close.Background = CaptureChrome.Paper;
        close.Width = close.MinWidth = close.Height = 26; close.Padding = new Thickness(4, 0, 4, 0);
        close.Content = new ActionIconView(ActionIcon.Close, 12);
        close.HorizontalAlignment = HorizontalAlignment.Left;
        close.VerticalAlignment = VerticalAlignment.Top;
        var pinButton = CaptureChrome.PinButton(pin); pinButton.Content = new ActionIconView(ActionIcon.PinFilled, 12); tools.Children.Add(pinButton);
        saveButton = CaptureChrome.SaveButton(() => { if (image.SavedPath is null) save(); else { reveal(); Close(); } });
        tools.Children.Add(saveButton);
        foreach (Button button in tools.Children) { button.Width = button.MinWidth = 26; button.Height = 26; button.Padding = new Thickness(4, 0, 4, 0); button.Background = CaptureChrome.Paper; if (button.Content is ActionIconView icon) button.Content = new ActionIconView(icon.Kind, 12); }
        void RefreshSaved() { if (image.SavedPath is null) return; saveButton.Content = new ActionIconView(ActionIcon.Folder, 12); saveButton.ToolTip = "在文件资源管理器中显示"; System.Windows.Automation.AutomationProperties.SetName(saveButton, "在文件资源管理器中显示"); }
        image.FileSaved += RefreshSaved; Closed += (_, _) => image.FileSaved -= RefreshSaved; RefreshSaved();
        var actions = new Border { Child = tools, Background = Brushes.Transparent };
        actions.VerticalAlignment = VerticalAlignment.Bottom;
        actions.HorizontalAlignment = HorizontalAlignment.Right; actions.Margin = new Thickness(5);
        var rim = new Border { CornerRadius = new CornerRadius(12), BorderBrush = WarmTheme.Brush(255, 245, 235, 179), BorderThickness = new Thickness(1), IsHitTestVisible = false };
        var root = new Grid { Children = { rounded, rim, close, actions } };
        Content = root;
        close.Visibility = actions.Visibility = Visibility.Collapsed;
        root.MouseEnter += (_, _) =>
        {
            lifetime.Stop();
            close.Visibility = actions.Visibility = Visibility.Visible;
        };
        root.MouseLeave += (_, _) =>
        {
            close.Visibility = actions.Visibility = Visibility.Collapsed;
            if (!captureHidden) lifetime.Start();
        };
        rounded.MouseLeftButtonDown += (_, e) =>
        {
            dragStart = e.GetPosition(rounded);
            rounded.CaptureMouse();
            e.Handled = true;
        };
        rounded.MouseLeftButtonUp += (_, e) =>
        {
            if (dragStart is null)
                return;
            dragStart = null;
            rounded.ReleaseMouseCapture();
            open();
            Close();
            e.Handled = true;
        };
        rounded.MouseMove += (_, e) =>
        {
            if (dragStart is not { } start || e.LeftButton != MouseButtonState.Pressed)
                return;
            var current = e.GetPosition(rounded);
            if (Math.Abs(current.X - start.X) < SystemParameters.MinimumHorizontalDragDistance &&
                Math.Abs(current.Y - start.Y) < SystemParameters.MinimumVerticalDragDistance)
                return;
            dragStart = null;
            rounded.ReleaseMouseCapture();
            if (ScreenshotDrag.Start(Image, error))
                Close();
        };
        rounded.LostMouseCapture += (_, _) => dragStart = null;
        lifetime.Tick += (_, _) => { lifetime.Stop(); WarmMotion.CloseWindow(this); };
        Closed += (_, _) => { lifetime.Stop(); IsClosed = true; Desktop.ForgetScreenshotWindow(new WindowInteropHelper(this).Handle); };
    }

    public ShotImage Image { get; }
    public bool IsClosed { get; private set; }
#if DEBUG
    internal string DebugSaveAction => System.Windows.Automation.AutomationProperties.GetName(saveButton);
#endif

    public void Place(PixelRect bounds)
        => ThumbnailShelf.Place(this, Image.Display, Image.Scale, bounds.Width, bounds.Height, PlaceNative);

    private void PlaceNative(PixelRect bounds)
    {
        var window = new WindowInteropHelper(this).EnsureHandle();
        Desktop.ExcludeForScreenshots(window);
        Desktop.Position(window, bounds);
        if (!IsVisible && !captureHidden)
        {
            Show();
            Desktop.Position(window, bounds);
            WarmMotion.EnterWindow(this);
            lifetime.Start();
        }
    }

    public void HideForCapture()
    {
        captureHidden = true;
        lifetime.Stop();
        Hide();
    }

    public void RestoreAfterCapture()
    {
        if (IsClosed)
            return;
        captureHidden = false;
        Show();
        lifetime.Start();
    }

}
