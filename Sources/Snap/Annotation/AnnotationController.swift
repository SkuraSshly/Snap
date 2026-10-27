import AppKit

/// 画标注的图层：内容由 AnnotationController 绘制
final class AnnotationLayer: CALayer {
    weak var controller: AnnotationController?

    override func draw(in ctx: CGContext) {
        MainActor.assumeIsolated {
            controller?.render(in: ctx)
        }
    }

    /// 关闭所有隐式动画，重绘即时生效
    override func action(forKey event: String) -> CAAction? { nil }
}

/// 标注的交互：拖拽画形状、单击放序号、文字输入，以及撤销 / 重做。
/// 截图界面和重新编辑窗口共用。所有坐标都是画布坐标（见 Annotation）。
@MainActor
final class AnnotationController: NSObject, NSTextViewDelegate {
    let document = AnnotationDocument()
    let renderer: AnnotationRenderer
    let layer = AnnotationLayer()

    /// 文字输入框放在这个视图里（与画布坐标一致的视图）
    weak var hostView: NSView?

    /// 当前工具；nil 表示没有选工具（截图界面里此时鼠标用来调整选区）
    var tool: AnnotationTool? {
        didSet {
            if tool != oldValue { endTextEditing() }
            onChange?()
        }
    }
    var style = AnnotationStyle() {
        didSet {
            applyStyleToTextView()
            onChange?()
        }
    }
    /// 状态变化（撤销可用性、工具等）时通知界面刷新
    var onChange: (() -> Void)?

    /// 允许画标注的范围（截图界面里是选区，全屏模式是整块屏幕）
    var canvasBounds: CGRect = .zero

    private var inProgress: Annotation?
    private var dragStart: CGPoint?
    private var textView: NSTextView?
    private var textTopLeft: CGPoint = .zero

    var isEditingText: Bool { textView != nil }

    init(base: BaseImage) {
        renderer = AnnotationRenderer(base: base)
        super.init()
        layer.controller = self
        layer.contentsScale = base.scale
        layer.needsDisplayOnBoundsChange = true
    }

    // MARK: - 绘制

    func render(in ctx: CGContext) {
        renderer.draw(document.annotations, in: ctx)
        if let inProgress {
            renderer.draw(inProgress, in: ctx)
        }
    }

    private func redraw() {
        layer.setNeedsDisplay()
    }

    /// 合成输出：底图区域 + 所有标注
    func composite(cropping rect: CGRect) -> CGImage? {
        renderer.composite(document.annotations, cropping: rect)
    }

    // MARK: - 撤销 / 重做

    func undo() {
        endTextEditing()
        if document.undo() { redraw(); onChange?() }
    }

    func redo() {
        endTextEditing()
        if document.redo() { redraw(); onChange?() }
    }

    // MARK: - 鼠标

    /// 返回 true 表示这次按下由标注处理
    @discardableResult
    func mouseDown(at point: CGPoint, shift: Bool) -> Bool {
        guard let tool else { return false }
        // 正在输入文字时点别处：先确认这段文字
        if isEditingText {
            endTextEditing()
            if tool == .text { return true }
        }
        guard canvasBounds.contains(point) else { return false }

        switch tool {
        case .text:
            beginTextEditing(at: point)
        case .counter:
            let annotation = Annotation(shape: .counter(document.nextCounterNumber, center: point),
                                        color: style.color, size: style.size)
            document.add(annotation)
            redraw()
            onChange?()
        default:
            dragStart = point
            inProgress = makeAnnotation(tool: tool, from: point, to: point, shift: shift)
            redraw()
        }
        return true
    }

    func mouseDragged(to point: CGPoint, shift: Bool) {
        guard let tool, let start = dragStart, var current = inProgress else { return }
        let p = point.clamped(to: canvasBounds)
        switch (tool, current.shape) {
        case (.pen, .pen(let points)):
            current.shape = .pen(points + [p])
        case (.highlighter, .highlighter(let points)):
            current.shape = .highlighter(points + [p])
        default:
            current = makeAnnotation(tool: tool, from: start, to: p, shift: shift, keepingID: current)
            renderer.clearPatch(for: current.id)
        }
        inProgress = current
        redraw()
    }

    func mouseUp(at point: CGPoint, shift: Bool) {
        guard let annotation = inProgress else { return }
        inProgress = nil
        dragStart = nil
        if isMeaningful(annotation) {
            document.add(annotation)
            onChange?()
        }
        redraw()
    }

    /// 太小的形状视为误触（单击一下不留下东西）
    private func isMeaningful(_ annotation: Annotation) -> Bool {
        switch annotation.shape {
        case .rectangle(let r), .ellipse(let r), .mosaic(let r), .blur(let r):
            return r.width >= 3 && r.height >= 3
        case .arrow(let a, let b), .line(let a, let b):
            return hypot(b.x - a.x, b.y - a.y) >= 4
        case .pen(let points), .highlighter(let points):
            return points.count >= 2
        default:
            return true
        }
    }

    /// 根据拖拽的起点和终点生成形状；按住 Shift：矩形 → 正方形、椭圆 → 圆、直线 / 箭头 → 45° 角
    private func makeAnnotation(tool: AnnotationTool, from start: CGPoint, to end: CGPoint, shift: Bool,
                                keepingID existing: Annotation? = nil) -> Annotation {
        var end = end
        func rect() -> CGRect {
            var w = end.x - start.x, h = end.y - start.y
            if shift {
                let side = max(abs(w), abs(h))
                w = w < 0 ? -side : side
                h = h < 0 ? -side : side
            }
            return CGRect(x: min(start.x, start.x + w), y: min(start.y, start.y + h), width: abs(w), height: abs(h))
                .intersection(canvasBounds)
        }
        if shift, tool == .line || tool == .arrow {
            let dx = end.x - start.x, dy = end.y - start.y
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length).clamped(to: canvasBounds)
        }
        let shape: Annotation.Shape = switch tool {
        case .rectangle: .rectangle(rect())
        case .ellipse: .ellipse(rect())
        case .mosaic: .mosaic(rect())
        case .blur: .blur(rect())
        case .arrow: .arrow(from: start, to: end)
        case .line: .line(from: start, to: end)
        case .pen: .pen([start])
        case .highlighter: .highlighter([start])
        case .text, .counter: .rectangle(.zero)   // 不经过这里
        }
        if var existing {
            existing.shape = shape
            return existing
        }
        return Annotation(shape: shape, color: style.color, size: style.size)
    }

    // MARK: - 文字输入

    private func beginTextEditing(at point: CGPoint) {
        guard let hostView else { return }
        let fontSize = Annotation.fontSize(for: style.size)
        let textView = NSTextView(frame: CGRect(x: point.x, y: point.y - fontSize * 1.3, width: 40, height: fontSize * 1.3))
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        // 与输出时的文字排版完全一致：不留内边距
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = CGSize(width: 10_000, height: 10_000)
        textView.wantsLayer = true
        textView.layer?.borderWidth = 1
        textView.layer?.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        textView.layer?.cornerRadius = 2
        hostView.addSubview(textView)
        self.textView = textView
        textTopLeft = point
        applyStyleToTextView()
        hostView.window?.makeFirstResponder(textView)
        onChange?()
    }

    private func applyStyleToTextView() {
        guard let textView else { return }
        let attributes = Annotation.textAttributes(color: style.color, fontSize: Annotation.fontSize(for: style.size))
        textView.typingAttributes = attributes
        textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textView.string.utf16.count))
        textView.insertionPointColor = style.color
        fitTextView()
    }

    /// 随输入内容调整输入框大小，左上角保持不动
    private func fitTextView() {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).size
        let lineHeight = Annotation.textFont(size: Annotation.fontSize(for: style.size)).boundingRectForFont.height
        let size = CGSize(width: max(ceil(used.width) + 4, 20), height: max(ceil(used.height), ceil(lineHeight)))
        textView.frame = CGRect(x: textTopLeft.x, y: textTopLeft.y - size.height, width: size.width, height: size.height)
    }

    func textDidChange(_ notification: Notification) {
        fitTextView()
    }

    /// Enter：确认这段文字（不是完成截图）；Shift+Enter：换行；Esc：结束输入（保留已输入的文字）。
    /// 中文输入法候选词阶段按 Enter 由输入法自己处理，不会走到这里。
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                endTextEditing()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endTextEditing()
            return true
        default:
            return false
        }
    }

    /// 结束文字输入：有内容就作为标注保存，空的直接丢弃
    func endTextEditing() {
        guard let textView else { return }
        self.textView = nil
        let string = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : textView.string
        let window = textView.window
        textView.delegate = nil
        textView.removeFromSuperview()
        window?.makeFirstResponder(nil)
        if !string.isEmpty {
            document.add(Annotation(shape: .text(string, topLeft: textTopLeft), color: style.color, size: style.size))
            redraw()
        }
        onChange?()
    }

    #if DEBUG
    /// 自测用：模拟在输入框里打字
    func debugType(_ text: String) {
        textView?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    var debugTextView: NSTextView? { textView }
    #endif
}
