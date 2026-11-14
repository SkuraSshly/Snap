using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using Velos.UI;
using Velos.Windows.Capture;

namespace Velos.Recording;

internal sealed class ClickHighlighter : Window
{
    private readonly Canvas canvas = new();
    private readonly Hook callback;
    private readonly Display display;
    private readonly double scale;
    private readonly Dictionary<bool, Ellipse> pressed = [];
    private nint hook;
    private bool paused;
    public bool Paused { get => paused; set { paused = value; canvas.Children.Clear(); pressed.Clear(); } }

    public ClickHighlighter(Display display, double scale)
    {
        this.display = display; this.scale = scale;
        Title = "Velos 鼠标点击高亮"; WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent; ShowInTaskbar = false; ShowActivated = false; Topmost = true;
        Content = canvas;
        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        Desktop.MakeClickThrough(hwnd); Desktop.Position(hwnd, display.Bounds); Show(); Desktop.Position(hwnd, display.Bounds);
        callback = OnMouse;
        hook = SetWindowsHookEx(14, callback, GetModuleHandle(null), 0);
        if (hook == 0) { Close(); throw new System.ComponentModel.Win32Exception(); }
        Closed += (_, _) => { if (hook != 0) UnhookWindowsHookEx(hook); hook = 0; pressed.Clear(); };
    }
    private nint OnMouse(int code, nint message, nint data)
    {
        if (code >= 0 && !paused)
        {
            var point = Marshal.PtrToStructure<MouseData>(data);
            var kind = (int)message;
            if (kind is 0x201 or 0x204)
            {
                if (display.Bounds.Contains(point.X, point.Y)) Down(kind == 0x204, point.X, point.Y);
            }
            else if (kind is 0x202 or 0x205) Up(kind == 0x205);
            else if (kind == 0x200)
                foreach (var ring in pressed.Values) Position(ring, point.X, point.Y);
        }
        return CallNextHookEx(hook, code, message, data);
    }
    private void Down(bool right, int x, int y)
    {
        Up(right);
        var ring = new Ellipse { Width = 34, Height = 34, StrokeThickness = 2,
            Stroke = right ? WarmTheme.Coral : WarmTheme.Apricot, Fill = right ? WarmTheme.Coral : WarmTheme.Apricot,
            Opacity = 0.45, RenderTransformOrigin = new Point(.5, .5), RenderTransform = new ScaleTransform(1, 1) };
        pressed[right] = ring; canvas.Children.Add(ring); Position(ring, x, y);
        var scaleTransform = (ScaleTransform)ring.RenderTransform;
        WarmMotion.Animate(scaleTransform, ScaleTransform.ScaleXProperty, 1, 120, .5);
        WarmMotion.Animate(scaleTransform, ScaleTransform.ScaleYProperty, 1, 120, .5);
    }
    private void Position(Ellipse ring, int x, int y)
    { Canvas.SetLeft(ring, (x - display.Bounds.X) / scale - 17); Canvas.SetTop(ring, (y - display.Bounds.Y) / scale - 17); }
    private void Up(bool right)
    {
        if (!pressed.Remove(right, out var ring)) return;
        if (!WarmMotion.Allowed) { canvas.Children.Remove(ring); return; }
        var fade = new DoubleAnimation(0, TimeSpan.FromMilliseconds(350)) { EasingFunction = new WarmMotion.EaseOutCurve() };
        fade.Completed += (_, _) => canvas.Children.Remove(ring);
        ring.BeginAnimation(OpacityProperty, fade);
        WarmMotion.Animate((ScaleTransform)ring.RenderTransform, ScaleTransform.ScaleXProperty, 1.8, 350, 1);
        WarmMotion.Animate((ScaleTransform)ring.RenderTransform, ScaleTransform.ScaleYProperty, 1.8, 350, 1);
    }
    [StructLayout(LayoutKind.Sequential)] private struct MouseData { public int X, Y; public uint Data, Flags, Time; public nuint Extra; }
    private delegate nint Hook(int code, nint message, nint data);
    [DllImport("user32.dll", EntryPoint = "SetWindowsHookExW", SetLastError = true)] private static extern nint SetWindowsHookEx(int id, Hook callback, nint module, uint thread);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")] private static extern nint CallNextHookEx(nint hook, int code, nint message, nint data);
    [DllImport("kernel32.dll", EntryPoint = "GetModuleHandleW", CharSet = CharSet.Unicode)] private static extern nint GetModuleHandle(string? name);
}
