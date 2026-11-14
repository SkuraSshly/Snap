using System.Diagnostics;
using System.Windows;
using System.Windows.Threading;
using Velos.Windows.Capture;
using Velos.Core.Animation;
using PixelRect = System.Drawing.Rectangle;

namespace Velos.UI;

// Screenshot and recording thumbnails share the same shelf, including reflow.
internal static class ThumbnailShelf
{
    private static readonly List<Entry> entries = [];
    internal static void Place(Window window, Display display, double scale, int width, int height, Action<PixelRect> position)
    {
        if (WarmMotion.IsClosing(window)) return;
        var entry = entries.FirstOrDefault(e => ReferenceEquals(e.Window, window));
        if (entry is null)
        {
            entry = new Entry(window, display, scale, position); entries.Add(entry);
            var captured = entry;
            window.Closed += (_, _) => { captured.Stop(); entries.Remove(captured); Arrange(display.Handle); };
        }
        entry.Width = width; entry.Height = height;
        Arrange(display.Handle);
    }
    internal static void Dismiss(Window window)
    {
        var entry = entries.FirstOrDefault(e => ReferenceEquals(e.Window, window)); if (entry is null) return;
        entry.Stop(); entries.Remove(entry); Arrange(entry.Display.Handle);
    }
    private static void Arrange(nint display)
    {
        var group = entries.Where(e => e.Display.Handle == display).Reverse().ToArray();
        if (group.Length == 0) return;
        var work = group[0].Display.WorkArea; var bottom = work.Bottom - (int)Math.Round(16 * group[0].Scale);
        foreach (var entry in group)
        {
            var top = bottom - entry.Height;
            entry.Move(new PixelRect(work.Right - entry.Width - (int)Math.Round(16 * entry.Scale), top, entry.Width, entry.Height));
            bottom = top - (int)Math.Round(10 * entry.Scale);
        }
    }
    private sealed class Entry(Window window, Display display, double scale, Action<PixelRect> position)
    {
        internal Window Window { get; } = window;
        internal Display Display { get; } = display;
        internal double Scale { get; } = scale;
        internal int Width, Height;
        private PixelRect current, target, start;
        private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(16) };
        private readonly Stopwatch watch = new();
        private bool subscribed;
#if DEBUG
        internal bool IsMoving => timer.IsEnabled;
#endif
        internal void Move(PixelRect bounds)
        {
            if (bounds == target) return;
            Stop(); target = bounds;
            if (current.IsEmpty && WarmMotion.Allowed)
            { current = bounds; current.X += bounds.Width + (int)Math.Round(16 * Scale); position(current); }
            if (!WarmMotion.Allowed || !Window.IsVisible || current.Size != bounds.Size)
            { current = bounds; position(bounds); return; }
            start = current; watch.Restart();
            if (!subscribed) { timer.Tick += Tick; subscribed = true; }
            timer.Start();
        }
        private void Tick(object? sender, EventArgs e)
        {
            var fraction = Math.Clamp(watch.Elapsed.TotalMilliseconds / 200, 0, 1); var eased = SpringMotion.EaseOut(fraction);
            current = new PixelRect((int)Math.Round(start.X + (target.X - start.X) * eased), (int)Math.Round(start.Y + (target.Y - start.Y) * eased), target.Width, target.Height);
            position(current); if (fraction >= 1) Stop();
        }
        internal void Stop() { timer.Stop(); watch.Stop(); }
    }
#if DEBUG
    internal static int DebugCount => entries.Count;
    internal static bool DebugMoving => entries.Any(e => e.IsMoving);
#endif
}
