import AppKit

// MARK: - 选区外变暗 + 边框 + 提示（不拦截鼠标）

@MainActor
final class LongCaptureOverlay: NSPanel {
    var message: String? { didSet { (contentView as? OverlayContent)?.message = message } }

    init(screen: NSScreen, region: CGRect) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true   // 鼠标、滚轮都穿过去，交给下面的 App
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        let local = region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        contentView = OverlayContent(frame: CGRect(origin: .zero, size: screen.frame.size), region: local)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class OverlayContent: NSView {
        let region: CGRect
        var message: String? { didSet { needsDisplay = true } }

        init(frame: CGRect, region: CGRect) {
            self.region = region
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func draw(_ dirtyRect: NSRect) {
            // 选区外变暗
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: region))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.32).setFill()
            dim.fill()
            // 选区边框画在外侧，不挡住内容
            OverlayAccent.screenshot.setStroke()
            let border = NSBezierPath(rect: region.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.stroke()
            guard let message else { return }
            // 提示：选区中间偏上的深色胶囊
            let text = NSAttributedString(string: message, attributes: [
                .font: roundedFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
            let maxWidth = max(160, min(region.width - 24, 520))
            let textSize = text.boundingRect(with: CGSize(width: maxWidth, height: 200), options: [.usesLineFragmentOrigin]).size
            let pill = CGRect(x: region.midX - textSize.width / 2 - 18, y: region.midY - textSize.height / 2 - 11,
                              width: ceil(textSize.width) + 36, height: ceil(textSize.height) + 22)
            NSColor(srgbRed: 0.18, green: 0.13, blue: 0.10, alpha: 0.82).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
            text.draw(with: CGRect(x: pill.minX + 18, y: pill.minY + 11, width: maxWidth, height: textSize.height),
                      options: [.usesLineFragmentOrigin])
        }
    }
}
