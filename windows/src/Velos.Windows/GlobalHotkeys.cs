using System.Runtime.InteropServices;
using Velos.Core.Hotkeys;
using Velos.Core.Settings;

namespace Velos.Windows;

public sealed class GlobalHotkeys(nint window) : IDisposable
{
    public const int Message = 0x0312;
    private const uint NoRepeat = 0x4000;
    private readonly Dictionary<HotkeyAction, (int Id, Hotkey Key)> bindings = [];
    private int nextId = 1;

    public void RegisterSaved(AppSettings settings)
    {
        foreach (var action in Enum.GetValues<HotkeyAction>())
        {
            var key = settings.GetHotkey(action);
            if (TryRegister(key, out var id))
                bindings.Add(action, (id, key));
        }
    }

    public bool IsRegistered(HotkeyAction action) => bindings.ContainsKey(action);

    public bool TryReplace(HotkeyAction action, Hotkey candidate, Func<bool> save)
    {
        var hasOldBinding = bindings.TryGetValue(action, out var old);
        if (hasOldBinding && old.Key == candidate)
            return true;

        if (!TryRegister(candidate, out var id))
            return false;

        var saved = false;
        try
        {
            saved = save();
            if (!saved)
                return false;

            if (hasOldBinding)
                UnregisterHotKey(window, old.Id);
            bindings[action] = (id, candidate);
            return true;
        }
        finally
        {
            if (!saved)
                UnregisterHotKey(window, id);
        }
    }

    public bool TryGetAction(nint messageId, out HotkeyAction action, out Hotkey key)
    {
        foreach (var entry in bindings)
        {
            if (entry.Value.Id != messageId)
                continue;
            action = entry.Key;
            key = entry.Value.Key;
            return true;
        }

        action = default;
        key = default;
        return false;
    }

    private bool TryRegister(Hotkey key, out int id)
    {
        // Win32 为应用程序保留 1 至 0xBFFF。避免复用当前仍绑定的 ID。
        int candidate;
        do
        {
            candidate = nextId;
            nextId = nextId == 0xbfff ? 1 : nextId + 1;
        }
        while (bindings.Values.Any(binding => binding.Id == candidate));

        id = candidate;
        return RegisterHotKey(window, id, (uint)key.Modifiers | NoRepeat, key.KeyCode);
    }

    public void Dispose()
    {
        foreach (var binding in bindings.Values)
            UnregisterHotKey(window, binding.Id);
        bindings.Clear();
    }

#if DEBUG
    public int DebugMessageId(HotkeyAction action) => bindings[action].Id;
#endif

    [DllImport("user32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint keyCode);

    [DllImport("user32.dll", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(nint window, int id);
}
