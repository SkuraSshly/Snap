using System.Windows;
using System.Windows.Input;
using Velos.Windows.Capture;

namespace Velos.Screenshot;

/// <summary>三种选区共用同一套跨屏状态，模式切换不清掉暂存的区域选区。</summary>
internal sealed class SelectionGroup
{
    private sealed record Entry(Window Window, Display Display, CaptureSurface Surface, Action<bool> Suppress,
        Action Changed, MouseEventHandler Moved);
    private readonly List<Entry> entries = [];
    private bool switching;

    public void Add(Window window, Display display, CaptureSurface surface, Action<bool> suppress)
    {
        void Changed() { if (!switching) Refresh(window); }
        void Moved(object? _, MouseEventArgs args) { if (display.Bounds.Contains(Desktop.Pointer())) MoveFullScreen(window); }
        entries.Add(new(window, display, surface, suppress, Changed, Moved));
        surface.SelectionChanged += Changed; window.PreviewMouseMove += Moved;
    }
    private void Refresh(Window changed)
    {
        var current = entries.FirstOrDefault(entry => entry.Window == changed);
        if (current is null) return;
        switching = true;
        try
        {
            if (!current.Surface.FullScreen && !current.Surface.IsSelecting && current.Surface.Region is not null)
                foreach (var other in entries)
                    if (other != current && other.Surface.Region is not null) other.Surface.ClearRegion();
            var full = entries.FirstOrDefault(entry => entry.Surface.FullScreen);
            foreach (var entry in entries) entry.Suppress(full is not null && entry != full);
        }
        finally { switching = false; }
    }
    public void Toggle()
    {
        if (entries.Count == 0) return;
        var pointer = Desktop.Pointer();
        var active = entries.FirstOrDefault(entry => entry.Surface.FullScreen) ?? entries.FirstOrDefault(entry => entry.Display.Bounds.Contains(pointer)) ?? entries[0];
        active.Surface.SetFullScreen(!active.Surface.FullScreen); active.Window.Activate();
    }
    public void MoveFullScreen(Window window)
    {
        var active = entries.FirstOrDefault(entry => entry.Surface.FullScreen);
        var target = entries.FirstOrDefault(entry => entry.Window == window);
        if (active is null || target is null || active == target) return;
        switching = true;
        try { active.Surface.SetFullScreen(false); target.Surface.SetFullScreen(true); }
        finally { switching = false; }
        Refresh(window); window.Activate();
    }
    public void Clear()
    {
        foreach (var entry in entries)
        { entry.Surface.SelectionChanged -= entry.Changed; entry.Window.PreviewMouseMove -= entry.Moved; }
        entries.Clear();
    }
}
