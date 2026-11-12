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

    #if DEBUG
    /// 自测：提示条的位置（这块屏幕内的坐标）
    var debugMessageFrame: CGRect? {
        guard let message, let content = contentView as? OverlayContent else { return nil }
        return content.pillFrame(for: message)
    }
    #endif

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

        static func attributed(_ message: String) -> NSAttributedString {
            NSAttributedString(string: message, attributes: [
                .font: roundedFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
        }

        /// 提示条的位置：选区上方居中；上方放不下就放在左边或右边（竖向居中）；都放不下就不显示
        func pillFrame(for message: String) -> CGRect? {
            let text = Self.attributed(message)
            let maxWidth: CGFloat = 520
            let textSize = text.boundingRect(with: CGSize(width: maxWidth, height: 200), options: [.usesLineFragmentOrigin]).size
            let size = CGSize(width: ceil(textSize.width) + 36, height: ceil(textSize.height) + 22)
            let gap: CGFloat = 12, margin: CGFloat = 8
            let usable = bounds.insetBy(dx: margin, dy: margin)
            let x = min(max(region.midX - size.width / 2, usable.minX), usable.maxX - size.width)
            let above = CGRect(x: x, y: region.maxY + gap, width: size.width, height: size.height)
            if usable.contains(above) { return above }
            let y = min(max(region.midY - size.height / 2, usable.minY), usable.maxY - size.height)
            let left = CGRect(x: region.minX - gap - size.width, y: y, width: size.width, height: size.height)
            if usable.contains(left) { return left }
            let right = CGRect(x: region.maxX + gap, y: y, width: size.width, height: size.height)
            if usable.contains(right) { return right }
            return nil
        }

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
            guard let message, let pill = pillFrame(for: message) else { return }
            // 提示：选区外面的深色胶囊。不能画在选区里：万一被截进画面，就会盖在正文上、不跟着滚动，
            // 拼接会因此认不出哪几列在滚动（左右边栏被一段段重复拼上），提示条本身也会留在长图里
            let text = Self.attributed(message)
            let maxWidth = pill.width - 36
            let textSize = text.boundingRect(with: CGSize(width: maxWidth, height: 200), options: [.usesLineFragmentOrigin]).size
            NSColor(srgbRed: 0.18, green: 0.13, blue: 0.10, alpha: 0.82).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
            text.draw(with: CGRect(x: pill.minX + 18, y: pill.minY + 11, width: maxWidth, height: textSize.height),
                      options: [.usesLineFragmentOrigin])
        }
    }
}
