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

/// 标注的交互：拖拽画形状、单击放序号、文字输入、选中已有标注后拖动 / 删除，以及撤销 / 重做。
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
            if tool != oldValue {
                endTextEditing()
                // 换工具：换成这个工具上次用的颜色、粗细和不透明度
                if let tool { style = ToolStyleMemory.style(for: tool) }
            }
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

    /// 允许画标注的范围（截图界面里是选区，全屏模式是整块屏幕）。标注只显示、只能点中这里面的部分，
    /// 和输出的图片一致；选区缩小后露在外面的部分看不见，再放大选区就又出现了（标注本身不会被删改）
    var canvasBounds: CGRect = .zero { didSet { if canvasBounds != oldValue { redraw() } } }
    /// 屏幕上 1 点对应多少画布单位（重新编辑窗口把大图缩小显示时大于 1）：控制点的大小和点中范围按屏幕计算
    var canvasUnitsPerPoint: CGFloat = 1

    private var inProgress: Annotation?
    private var dragStart: CGPoint?
    /// 选中的标注（有控制点的显示控制点；可拖动、按 Delete 删除、方向键微移）
    private(set) var selectedID: UUID?
    /// 正在拖动的标注：起点、拖动前的样子、是否已记撤销点
    private var moving: (start: CGPoint, original: Annotation, recordedUndo: Bool)?
    /// 正在拖选中标注的控制点调整大小：哪个控制点、拖动前的样子、是否已记撤销点
    private var resizing: (handle: Annotation.ResizeHandle, original: Annotation, recordedUndo: Bool)?
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
        ctx.saveGState()
        if !canvasBounds.isEmpty { ctx.clip(to: canvasBounds) }
        renderer.draw(document.annotations, in: ctx)
        if let inProgress {
            renderer.draw(inProgress, in: ctx)
        }
        ctx.restoreGState()
        // 控制点：只画在屏幕上，不进入输出的图片
        if let selectedID, let selected = document.annotation(withID: selectedID) {
            drawSelection(of: selected, in: ctx)
        }
    }

    /// 选中的标注：
    /// - 矩形、椭圆：控制点直接画在形状的框上
    /// - 马赛克、模糊：本身没有边线，画一圈细线再加控制点
    /// - 直线、箭头：两个端点上各一个控制点
    /// - 画笔、荧光笔、文字、序号：不画任何框（只能移动）
    private func drawSelection(of selected: Annotation, in ctx: CGContext) {
        let u = canvasUnitsPerPoint
        guard !selected.resizeHandles.isEmpty else { return }
        let handles = visibleResizeHandles(of: selected)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        switch selected.shape {
        case .mosaic(let rect), .blur(let rect):
            ctx.setLineWidth(1 * u)
            ctx.setStrokeColor(OverlayAccent.screenshot.cgColor)
            ctx.stroke(canvasBounds.isEmpty ? rect : rect.intersection(canvasBounds))
        default:
            break
        }
        // 控制点：白色圆点 + 杏色描边，和截图选区的控制点一样
        let d = 8 * u
        ctx.setLineWidth(1.5 * u)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setStrokeColor(OverlayAccent.screenshot.cgColor)
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * u), blur: 2 * u, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        for (_, point) in handles {
            ctx.fillEllipse(in: CGRect(x: point.x - d / 2, y: point.y - d / 2, width: d, height: d))
        }
        ctx.setShadow(offset: .zero, blur: 0)
        for (_, point) in handles {
            ctx.strokeEllipse(in: CGRect(x: point.x - d / 2, y: point.y - d / 2, width: d, height: d))
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
        if document.undo() { dropStaleSelection(); redraw(); onChange?() }
    }

    func redo() {
        endTextEditing()
        if document.redo() { dropStaleSelection(); redraw(); onChange?() }
    }

    /// 撤销后选中的标注可能已经不存在了
    private func dropStaleSelection() {
        lastStyleEdit = nil
        if let selectedID, document.annotation(withID: selectedID) == nil { self.selectedID = nil }
    }

    // MARK: - 选中、移动、删除

    /// 鼠标正好在其上的标注（有重叠时取最上面的）。范围外看不见的部分点不中
    func annotation(at point: CGPoint) -> Annotation? {
        guard canvasBounds.isEmpty || canvasBounds.contains(point) else { return nil }
        return document.annotations.last { $0.contains(point) }
    }

    /// 在范围内（含边上）的控制点：范围外的看不见，不画也点不中
    private func visibleResizeHandles(of annotation: Annotation) -> [(handle: Annotation.ResizeHandle, point: CGPoint)] {
        guard !canvasBounds.isEmpty else { return annotation.resizeHandles }
        let area = canvasBounds.insetBy(dx: -1, dy: -1)
        return annotation.resizeHandles.filter { area.contains($0.point) }
    }

    /// 按下去能拖动的标注：要正好按在画出来的地方（选中的也一样；空心方框里面不算）
    func grabbableAnnotation(at point: CGPoint) -> Annotation? {
        annotation(at: point)
    }

    /// 鼠标下面的、选中标注的控制点（按屏幕上 7 点的范围判断）
    func resizeHandle(at point: CGPoint) -> Annotation.ResizeHandle? {
        guard let selected = selectedAnnotation else { return nil }
        let radius = 7 * canvasUnitsPerPoint
        return visibleResizeHandles(of: selected)
            .map { ($0.handle, hypot(point.x - $0.point.x, point.y - $0.point.y)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }

    /// 控制点上（或正在拖控制点）时的光标：调整大小的双向箭头；不在控制点上时为 nil
    func resizeCursor(at point: CGPoint) -> NSCursor? {
        let current = resizing.map { ($0.handle, $0.original) } ?? resizeHandle(at: point).flatMap { handle in
            selectedAnnotation.map { (handle, $0) }
        }
        guard let (handle, annotation) = current else { return nil }
        switch (handle, annotation.shape) {
        case (.frame(let h), _):
            return h.cursor
        case (.start, .arrow(let a, let b)), (.start, .line(let a, let b)):
            return Self.cursor(pointing: a, from: b)
        case (.end, .arrow(let a, let b)), (.end, .line(let a, let b)):
            return Self.cursor(pointing: b, from: a)
        default:
            return nil
        }
    }

    /// 端点的光标：按端点相对另一端的方向，取最接近的那种调整大小箭头
    private static func cursor(pointing p: CGPoint, from other: CGPoint) -> NSCursor {
        let angle = atan2(p.y - other.y, p.x - other.x)
        let octant = Int(((angle / (.pi / 4)).rounded() + 8)) % 8
        let positions: [NSCursor.FrameResizePosition] = [.right, .topRight, .top, .topLeft, .left, .bottomLeft, .bottom, .bottomRight]
        return NSCursor.frameResize(position: positions[octant], directions: .all)
    }

    var hasSelection: Bool { selectedID != nil }
    var selectedAnnotation: Annotation? { selectedID.flatMap { document.annotation(withID: $0) } }

    /// 属性栏显示的样式：有选中标注时显示它的颜色 / 粗细 / 不透明度
    var displayedStyle: AnnotationStyle {
        guard let selected = selectedAnnotation else { return style }
        var shown = style
        if selected.tool.usesColor { shown.color = selected.color }
        shown.size = selected.size
        if selected.allowsOpacity { shown.opacity = selected.opacity }
        shown.filled = selected.filled
        return shown
    }

    /// 上次改样式的标注和时间：连续拖滑块 / 调色盘时合并成一次撤销
    private var lastStyleEdit: (id: UUID, time: Date)?

    /// 在属性栏改了样式。有选中标注时改它（可撤销），并记作它那种工具上次用的样式；
    /// 没有选中时改当前工具的样式，作为之后新画标注的样式
    func applyStyle(_ newStyle: AnnotationStyle) {
        guard var selected = selectedAnnotation else {
            style = newStyle
            if let tool { ToolStyleMemory.remember(newStyle, for: tool) }
            return
        }
        ToolStyleMemory.remember(newStyle, for: selected.tool)
        if tool == selected.tool { style = newStyle }
        var changed = selected
        if selected.tool.usesColor { changed.color = newStyle.color }
        changed.size = newStyle.size
        if selected.allowsOpacity { changed.opacity = newStyle.opacity }
        if selected.tool.supportsFill { changed.filled = newStyle.filled }
        guard changed.color != selected.color || changed.size != selected.size || changed.opacity != selected.opacity
            || changed.filled != selected.filled else { return }
        let now = Date()
        if lastStyleEdit?.id != selected.id || now.timeIntervalSince(lastStyleEdit!.time) > 1 {
            document.recordUndo()
        }
        lastStyleEdit = (selected.id, now)
        selected = changed
        document.replace(selected)
        renderer.clearPatch(for: selected.id)
        redraw()
        onChange?()
    }
    var isMovingAnnotation: Bool { moving != nil || resizing != nil }

    /// 取消选中；原来有选中的返回 true
    @discardableResult
    func deselect() -> Bool {
        guard selectedID != nil else { return false }
        selectedID = nil
        redraw()
        onChange?()
        return true
    }

    /// 删除选中的标注（可撤销）
    @discardableResult
    func deleteSelection() -> Bool {
        guard let selectedID, document.remove(id: selectedID) else { return false }
        self.selectedID = nil
        renderer.clearPatch(for: selectedID)
        redraw()
        onChange?()
        return true
    }

    /// 方向键微移选中的标注（每按一次可单独撤销）
    @discardableResult
    func moveSelection(dx: CGFloat, dy: CGFloat) -> Bool {
        guard let selectedID, let selected = document.annotation(withID: selectedID) else { return false }
        let offset = clampedOffset(CGVector(dx: dx, dy: dy), for: selected)
        guard offset.dx != 0 || offset.dy != 0 else { return true }
        document.recordUndo()
        lastStyleEdit = nil
        document.replace(selected.moved(by: offset))
        redraw()
        onChange?()
        return true
    }

    /// 移动后仍留在可画范围内（标注比范围还大时不限制）
    private func clampedOffset(_ offset: CGVector, for annotation: Annotation) -> CGVector {
        guard !canvasBounds.isEmpty else { return offset }
        let b = annotation.bounds
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            low <= high ? min(max(value, low), high) : value
        }
        return CGVector(dx: clamp(offset.dx, canvasBounds.minX - b.minX, canvasBounds.maxX - b.maxX),
                        dy: clamp(offset.dy, canvasBounds.minY - b.minY, canvasBounds.maxY - b.maxY))
    }

    // MARK: - 鼠标

    /// 返回 true 表示这次按下由标注处理
    @discardableResult
    func mouseDown(at point: CGPoint, shift: Bool) -> Bool {
        // 正在输入文字时点别处：先确认这段文字
        if isEditingText {
            endTextEditing()
            if tool == .text { return true }
        }
        // 选中标注的控制点：调整大小（控制点可能在形状外面一点，先判断它）
        if let handle = resizeHandle(at: point), let selected = selectedAnnotation {
            resizing = (handle, selected, false)
            return true
        }
        // 按在任何标注上（正好在画出来的地方，鼠标是四向移动光标）：不管选没选绘图工具，
        // 按下就选中它，直接拖就是移动，不用先单击选中；只单击一下就是选中
        if let hit = annotation(at: point) {
            selectedID = hit.id
            lastStyleEdit = nil
            moving = (point, hit, false)
            redraw()
            onChange?()
            return true
        }
        deselect()
        guard let tool, canvasBounds.contains(point) else { return false }

        switch tool {
        case .text:
            beginTextEditing(at: point)
        case .counter:
            let annotation = Annotation(shape: .counter(document.nextCounterNumber, center: point),
                                        color: style.color, size: style.size, opacity: style.opacity)
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
        if var resizing {
            let changed = resizing.original.resized(resizing.handle, to: point.clamped(to: canvasBounds), keepRatio: shift)
            // 拖得太小（看不见、点不中）时停在上一个大小
            guard isMeaningful(changed) else { return }
            if !resizing.recordedUndo {
                document.recordUndo()
                lastStyleEdit = nil
                resizing.recordedUndo = true
                self.resizing = resizing
            }
            document.replace(changed)
            renderer.clearPatch(for: changed.id)
            redraw()
            return
        }
        if var moving {
            let offset = clampedOffset(CGVector(dx: point.x - moving.start.x, dy: point.y - moving.start.y), for: moving.original)
            // 真的动了才记撤销点（单击选中不算一次修改）
            if !moving.recordedUndo {
                guard hypot(offset.dx, offset.dy) >= 1 else { return }
                document.recordUndo()
                lastStyleEdit = nil
                moving.recordedUndo = true
                self.moving = moving
            }
            document.replace(moving.original.moved(by: offset))
            redraw()
            return
        }
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
        if resizing != nil {
            resizing = nil
            onChange?()
            return
        }
        if moving != nil {
            moving = nil
            onChange?()
            return
        }
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
        return Annotation(shape: shape, color: style.color, size: style.size, opacity: style.opacity,
                          filled: tool.supportsFill && style.filled)
    }

    // MARK: - 文字输入

    private func beginTextEditing(at point: CGPoint) {
        guard let hostView else { return }
        let fontSize = style.size
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
        // 有底色时：输入框也显示底色，文字自动用白 / 黑字，看到的就是完成后的样子
        let foreground = style.filled ? Annotation.textColor(onBackground: style.color) : style.color
        let attributes = Annotation.textAttributes(color: foreground, fontSize: style.size)
        textView.typingAttributes = attributes
        textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textView.string.utf16.count))
        textView.insertionPointColor = foreground
        textView.drawsBackground = style.filled
        textView.backgroundColor = style.filled ? style.color.withAlphaComponent(style.opacity) : .clear
        fitTextView()
    }

    /// 随输入内容调整输入框大小，左上角保持不动
    private func fitTextView() {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).size
        let lineHeight = Annotation.textFont(size: style.size).boundingRectForFont.height
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
            document.add(Annotation(shape: .text(string, topLeft: textTopLeft), color: style.color, size: style.size, opacity: style.opacity,
                                    filled: style.filled))
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
