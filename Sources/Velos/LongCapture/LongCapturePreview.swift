import AppKit

// MARK: - 预览

/// 拼接结果的实时预览：一张已经缩小好的小图（采集那边每秒最多画 30 次），宽度撑满，
/// 显示当前滚到的位置往上的那一段——往下滚时是最新拼上的，往回滚时跟着回去
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

    /// 图片区域的大小（像素）：采集那边按这个大小画小图，显示时不用再缩放
    var imagePixelSize: (width: Int, height: Int) {
        let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return (Int((canvas.bounds.width * scale).rounded()), Int((canvas.bounds.height * scale).rounded()))
    }

    func show(_ image: CGImage?) {
        canvas.image = image
    }

    #if DEBUG
    var debugHasImage: Bool { canvas.image != nil }
    #endif

    private final class PreviewCanvas: NSView {
        var image: CGImage? { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext, let image else { return }
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.clip()
            ctx.interpolationQuality = .high
            // 宽度撑满、按原比例；图比区域矮时贴着上边（长图的开头在上面）
            let height = bounds.width * CGFloat(image.height) / CGFloat(image.width)
            ctx.draw(image, in: CGRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height))
            ctx.restoreGState()
        }
    }
}
