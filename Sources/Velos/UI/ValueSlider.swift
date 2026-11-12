import AppKit

/// 数值拉条（温暖风格）：[名称] ——●—— 数值。拖动、点按或在上面滚动都能改；按 step 取整
class ValueSlider: WarmControl {
    var onChange: ((CGFloat) -> Void)?
    var value: CGFloat = 1 { didSet { needsDisplay = true } }
    var minimum: CGFloat = 0 { didSet { needsDisplay = true } }
    var maximum: CGFloat = 1 { didSet { needsDisplay = true } }
    /// 取整的单位（例如 1 点、1%）
    var step: CGFloat = 1
    /// 左边的名称（可以没有）
    var title: String? { didSet { needsDisplay = true } }
    /// 右边显示的数值文字
    var format: (CGFloat) -> String = { "\(Int($0.rounded()))" }

    private var moveArea: NSTrackingArea?

    private var titleWidth: CGFloat { title.map { ceil(attributed($0).size().width) + 8 } ?? 0 }

    /// 白点的位置
    private var knobRect: CGRect {
        let track = self.track
        let fraction = maximum > minimum ? (min(max(value, minimum), maximum) - minimum) / (maximum - minimum) : 0
        let x = track.minX + fraction * track.width
        return CGRect(x: x - 7, y: bounds.midY - 7, width: 14, height: 14)
    }

    /// 白点上（和拖着时）是一对左右小三角（暖色，和选区、标注的控制点同一种），其他地方是箭头
    func cursor(at point: CGPoint) -> NSCursor {
        isPressed || knobRect.insetBy(dx: -4, dy: -4).contains(point) ? Self.dragCursor : .arrow
    }

    static let dragCursor = NSCursor.warmResize(angle: 0, outward: false)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let moveArea { removeTrackingArea(moveArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        moveArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }


    private var track: CGRect {
        CGRect(x: 8 + titleWidth, y: bounds.midY - 2, width: max(10, bounds.width - 58 - titleWidth), height: 4)
    }

    override func updateAppearance() { needsDisplay = true }

    private func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: roundedFont(ofSize: 12, weight: .semibold, monospacedDigits: true),
            .foregroundColor: palette.ink,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = self.palette
        let track = self.track
        if let title {
            let label = attributed(title)
            label.draw(at: CGPoint(x: 8, y: bounds.midY - label.size().height / 2))
        }
        palette.ink.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = maximum > minimum ? (min(max(value, minimum), maximum) - minimum) / (maximum - minimum) : 0
        let knobX = track.minX + fraction * track.width
        WarmPalette.apricot.setFill()
        NSBezierPath(roundedRect: CGRect(x: track.minX, y: track.minY, width: knobX - track.minX, height: track.height),
                     xRadius: 2, yRadius: 2).fill()
        // 白点不做动效：鼠标放上去只换指针（左右小三角）
        let knob = CGRect(x: knobX - 7, y: bounds.midY - 7, width: 14, height: 14)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.3, green: 0.18, blue: 0.1, alpha: 0.3)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
        let label = attributed(format(value))
        let size = label.size()
        label.draw(at: CGPoint(x: bounds.maxX - 6 - size.width, y: bounds.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        pick(event)
        Self.dragCursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        pick(event)
        Self.dragCursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    /// 在拉条上滚动：每次一格，精确微调
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY == 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        guard delta != 0 else { return }
        set(value + (delta > 0 ? scrollStep : -scrollStep))
    }

    var scrollStep: CGFloat { step }

    private func pick(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        set(minimum + (p.x - track.minX) / track.width * (maximum - minimum))
    }

    /// 按 step 取整，限制在范围内；变了才回调
    func set(_ newValue: CGFloat) {
        let stepped = step > 0 ? (newValue / step).rounded() * step : newValue
        let clamped = min(max(stepped, minimum), maximum)
        guard clamped != value else { return }
        value = clamped
        onChange?(clamped)
    }
}

/// 不透明度：10% ~ 100%，取整到 1%，滚动一次 5%
final class OpacitySlider: ValueSlider {
    static let width: CGFloat = 118

    override init(frame: NSRect) {
        super.init(frame: frame)
        minimum = 0.1
        maximum = 1
        step = 0.01
        value = 1
        format = { "\(Int(($0 * 100).rounded()))%" }
        toolTip = "不透明度"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var scrollStep: CGFloat { 0.05 }
}

/// 大小：粗细 / 宽度 / 字号 / 大小 / 强度（按工具），取整到 1 点，滚动一次 1 点
final class SizeSlider: ValueSlider {
    static let width: CGFloat = 168

    override init(frame: NSRect) {
        super.init(frame: frame)
        step = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, range: ClosedRange<CGFloat>) {
        self.title = title
        minimum = range.lowerBound
        maximum = range.upperBound
        toolTip = "\(title)（\(Int(range.lowerBound))–\(Int(range.upperBound))，可以在上面滚动微调）"
    }
}
