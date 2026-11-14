using Velos.Core.Hotkeys;

namespace Velos.Core.Screenshot;

/// <summary>Sources/Velos/Capture/CaptureCoordinator.swift 的会话互斥规则。</summary>
public static class CaptureSessionRules
{
    public static bool Accept(HotkeyAction requested, HotkeyAction? selecting, bool longCapture) =>
        !longCapture && (selecting is null || selecting == requested);
}
