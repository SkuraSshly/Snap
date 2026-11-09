import AppKit
import VelosOCRKit

// MARK: - 加载动画 / 提示

/// 小提示浮层（例如「已复制译文」）：显示一句话，1.6 秒后淡出。
/// 不接收鼠标、不抢焦点。
@MainActor
final class RecognitionHUD {
    private let window: NSPanel
    private let anchor: CGRect
    private var closeTask: Task<Void, Never>?

    var isVisible: Bool { window.isVisible }
    var hidesOnDeactivate: Bool { window.hidesOnDeactivate }
    var frame: CGRect { window.frame }
    #if DEBUG
    var debugWindow: NSWindow { window }
    #endif

    /// - Parameter rect: 选区（全局坐标）
    init(around rect: CGRect) {
        anchor = rect
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        // NSPanel 默认在 App 失去前台时自动隐藏；截屏翻译结束时焦点已经还给原来的 App，必须关掉，否则一出现就消失
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    func showMessage(_ text: String, symbol: String = "text.viewfinder") {
        closeTask?.cancel()
        let label = NSTextField(labelWithString: text)
        label.font = roundedFont(ofSize: 13, weight: .semibold)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 58, height: 36)
        let panel = FrostedPanel(blending: .behindWindow, shadowRadius: 8)
        panel.frame = CGRect(origin: CGPoint(x: 8, y: 8), size: size)
        icon.frame = CGRect(x: 14, y: 9, width: 18, height: 18)
        label.setFrameOrigin(CGPoint(x: 38, y: ((size.height - label.frame.height) / 2).rounded()))
        panel.addSubview(icon)
        panel.addSubview(label)
        let palette = WarmPalette(for: panel)
        label.textColor = palette.ink
        icon.contentTintColor = palette.ink
        present(panel, size: size)
        // 这里要强引用 self：提示的主人（例如结果窗口）可能先关闭、先释放，
        // 弱引用的话计时就此作废，提示会一直留在屏幕上
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                self.window.animator().alphaValue = 0
            }
            self.close()
        }
    }

    func close() {
        closeTask?.cancel()
        window.orderOut(nil)
        window.contentView = nil
    }

    /// 放在选区中央（选区太靠边时移回屏幕内）
    private func present(_ content: NSView, size: CGSize) {
        // 注意：设为 contentView 后，视图会被缩放成窗口当前的大小（新窗口是 0×0），所以尺寸要先算好
        let windowSize = CGSize(width: size.width + 16, height: size.height + 16)
        let container = NSView(frame: CGRect(origin: .zero, size: windowSize))
        container.addSubview(content)
        window.contentView = container
        var frame = CGRect(x: anchor.midX - windowSize.width / 2, y: anchor.midY - windowSize.height / 2,
                           width: windowSize.width, height: windowSize.height)
        if let screen = NSScreen.screen(containing: CGPoint(x: anchor.midX, y: anchor.midY)) {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame.integral, display: true)
        window.alphaValue = 1
        window.orderFrontRegardless()
    }
}

/// 不激活 App 也能成为焦点窗口的面板（能接收 Esc、编辑文字）
final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
