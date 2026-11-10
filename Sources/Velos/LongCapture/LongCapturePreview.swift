import AppKit

// MARK: - 预览

/// 拼接结果的实时预览：竖向时按宽度缩放、显示最新的一段；横向时按高度缩放、显示最右边的一段
@MainActor
final class LongCapturePreview: NSPanel {
    private let panel = FrostedPanel(cornerRadius: 12, blending: .behindWindow, shadowRadius: 8)
    private let canvas = PreviewCanvas()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        let root = NSView()
        contentView = root
        root.addSubview(panel)
        panel.addSubview(canvas)
    }

    override var canBecomeKey: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        panel.frame = CGRect(origin: .zero, size: frameRect.size)
        canvas.frame = panel.bounds.insetBy(dx: 6, dy: 6)
    }

    func show(_ parts: [CGImage], axis: ScrollAxis) {
        canvas.parts = parts
        canvas.axis = axis
    }

    #if DEBUG
    var debugPartCount: Int { canvas.parts.count }
    #endif

    private final class PreviewCanvas: NSView {
        var parts: [CGImage] = [] { didSet { needsDisplay = true } }
        var axis: ScrollAxis = .vertical { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext, let first = parts.first else { return }
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.clip()
            ctx.interpolationQuality = .medium
            switch axis {
            case .vertical:
                // 宽度撑满，从上往下排；超出高度时只显示最下面（最新）的部分
                let k = bounds.width / CGFloat(first.width)
                let total = parts.reduce(0) { $0 + CGFloat($1.height) * k }
                var top = bounds.maxY + max(0, total - bounds.height)
                for part in parts {
                    let h = CGFloat(part.height) * k
                    let rect = CGRect(x: bounds.minX, y: top - h, width: bounds.width, height: h)
                    if rect.maxY >= bounds.minY - 1, rect.minY <= bounds.maxY + 1 { ctx.draw(part, in: rect) }
                    top -= h
                }
            case .horizontal:
                // 高度撑满，从左往右排；超出宽度时只显示最右边（最新）的部分
                let k = bounds.height / CGFloat(first.height)
                let total = parts.reduce(0) { $0 + CGFloat($1.width) * k }
                var left = bounds.minX - max(0, total - bounds.width)
                for part in parts {
                    let w = CGFloat(part.width) * k
                    let rect = CGRect(x: left, y: bounds.minY, width: w, height: bounds.height)
                    if rect.maxX >= bounds.minX - 1, rect.minX <= bounds.maxX + 1 { ctx.draw(part, in: rect) }
                    left += w
                }
            }
            ctx.restoreGState()
        }
    }
}
