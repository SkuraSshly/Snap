import AppKit

/// 覆盖整块屏幕的选区遮罩窗口（每块屏幕一个）。
/// 用「不激活」的面板：它能成为焦点窗口、直接接收键盘，却不会把当前正在用的 App 切到后台，
/// 截图结束后也就不需要再把焦点还回去。
final class OverlayWindow: NSPanel {
    weak var handler: OverlayEventHandler?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        // 在所有桌面空间（包括全屏 App 的空间）都能出现
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        // 高于菜单栏、程序坞和普通弹出菜单。
        // 注意：不能再设置 isFloatingPanel —— 它会把层级悄悄改回普通浮动层级（低于程序坞和菜单栏）
        level = .screenSaver
        acceptsMouseMovedEvents = true
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // 录屏选区的遮罩大部分是透明的：显式声明接收鼠标事件，透明区域（选区内部）也能拖动和调整
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 少数按键（⌥1、⌘S）在任何情况下都由截图界面处理，即使焦点在文字输入框里
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let handler, handler.overlayShouldIntercept(event) {
            _ = handler.overlayKeyDown(event)
            return
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        // 未处理的按键直接吞掉：不传给系统，也不发出提示音
        _ = handler?.overlayKeyDown(event)
    }

    override func resignKey() {
        super.resignKey()
        handler?.overlayDidResignKey()
    }
}
