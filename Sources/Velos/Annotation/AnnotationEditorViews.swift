import AppKit

/// 编辑窗口里放画布的滚动视图：按住 ⌥ 滚动以鼠标为中心缩放（双指捏合也可以），放大后普通滚动移动查看位置。
/// 最小是整张图都看得见（长截图打开时只显示一部分，可以缩小到看全）
final class EditorZoomView: NSScrollView {
    /// 用户手动缩放了（⌥ + 滚动、双指捏合、⌘= / ⌘- / ⌘0）：显示比例提示
    var onZoom: (() -> Void)?
    /// 显示比例变了（包括跟着窗口大小自动缩放）：控制点大小、光标区域要重新算
    var onScaleChange: (() -> Void)?

    /// 跟着窗口大小自动缩放时按什么适配：整张放得下、按宽度（竖着长的长截图）、按高度（横着长的长截图）
    enum FitAxis { case all, width, height }
    var fitAxis = FitAxis.all
    /// 自动缩放最多放大到多少（原图 100%）
    var maxFitMagnification: CGFloat = 1
    /// 还没手动缩放过：窗口变大变小时图片跟着缩放（和「预览」一样）；手动缩放后保持用户的比例，⌘0 恢复
    private(set) var followsWindowSize = true

    /// 适配比例：「桌面」（图片 + 四周边距，放大倍数 1 时的大小）放进 clip 需要的放大倍数
    static func fitMagnification(desk: CGSize, clip: CGSize, axis: FitAxis) -> CGFloat {
        guard desk.width > 0, desk.height > 0 else { return 1 }
        switch axis {
        case .all: return min(clip.width / desk.width, clip.height / desk.height)
        case .width: return clip.width / desk.width
        case .height: return clip.height / desk.height
        }
    }

    /// 图片下面的暖色「桌面」：浅色模式是奶咖色，深色模式是深可可色，和图片明显区分开
    static let deskColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.16, green: 0.13, blue: 0.11, alpha: 1)
            : NSColor(srgbRed: 0.91, green: 0.86, blue: 0.80, alpha: 1)
    }

    /// - Parameters:
    ///   - canvas: 图片画布；外面包一层四周留边距的「桌面」，缩小到比窗口还小时居中
    ///   - image: 原图：投影按它的形状算（透明的圆角处没有投影）
    init(frame: CGRect, canvas: NSView, image: CGImage, minMagnification: CGFloat, maxMagnification: CGFloat) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        documentView = EditorDesk(canvas: canvas, image: image, margin: AnnotationEditorWindowController.margin)
        drawsBackground = true
        backgroundColor = Self.deskColor
        contentView.drawsBackground = true
        contentView.backgroundColor = Self.deskColor
        // 长截图一直显示滚动条（竖着长的在右边、横着长的在下面），暖色圆角滑块，不需要时自动隐藏
        verticalScroller = WarmScroller()
        horizontalScroller = WarmScroller()
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .legacy
        allowsMagnification = true
        self.minMagnification = min(1, minMagnification)
        self.maxMagnification = maxMagnification
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 窗口大小变了：没手动缩放过就跟着缩放；图片比窗口小时保持居中
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitToWindowIfFollowing()
        recenter()
    }

    private func fitToWindowIfFollowing() {
        guard followsWindowSize, let desk = documentView else { return }
        let fit = Self.fitMagnification(desk: desk.frame.size, clip: contentView.frame.size, axis: fitAxis)
        let target = min(max(fit, minMagnification), min(maxFitMagnification, maxMagnification))
        guard abs(target - magnification) > 0.001 else { return }
        let visible = contentView.documentVisibleRect
        setMagnification(target, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
        onScaleChange?()
    }

    /// 让 clip 重新约束一次位置（CenteringClipView 会把比窗口小的图片放到中间）
    private func recenter() {
        contentView.scroll(to: contentView.bounds.origin)
        reflectScrolledClipView(contentView)
    }

    /// 系统「显示滚动条」的设置变了也保持常显的暖色滚动条
    override var scrollerStyle: NSScroller.Style {
        get { .legacy }
        set { super.scrollerStyle = .legacy }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else {
            super.scrollWheel(with: event)
            return
        }
        guard let canvas = documentView, event.scrollingDeltaY != 0 else { return }
        // 手指离开后的惯性滚动不缩放：手停下就停
        guard event.momentumPhase.isEmpty else { return }
        let factor = Self.zoomFactor(deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        let anchor = canvas.convert(event.locationInWindow, from: nil)
        followsWindowSize = false
        setMagnification(min(max(magnification * factor, minMagnification), maxMagnification), centeredAt: anchor)
        onScaleChange?()
        onZoom?()
    }

    /// ⌥ + 滚动一次的缩放倍数：往上滚放大、往下滚缩小。
    /// - 鼠标滚轮：每格固定 15%（系统的滚轮加速会让一格报好几行，不按行数算）
    /// - 触控板：按滑动的距离，每 100 点约 35%；一次滑动会来几十个事件，每个最多改变 10%
    static func zoomFactor(deltaY: CGFloat, precise: Bool) -> CGFloat {
        guard precise else { return deltaY > 0 ? 1.15 : 1 / 1.15 }
        return min(max(exp(deltaY * 0.003), 1 / 1.1), 1.1)
    }

    /// 以可见区域中心缩放（⌘= / ⌘-）
    func zoom(by factor: CGFloat) {
        let visible = contentView.documentVisibleRect
        let center = CGPoint(x: visible.midX, y: visible.midY)
        followsWindowSize = false
        setMagnification(min(max(magnification * factor, minMagnification), maxMagnification), centeredAt: center)
        onScaleChange?()
        onZoom?()
    }

    /// 回到适配窗口的大小，之后重新跟着窗口缩放（⌘0）
    func zoomToFit() {
        followsWindowSize = true
        magnification = 1
        fitToWindowIfFollowing()
        recenter()
        scrollToStart()
        onScaleChange?()
        onZoom?()
    }

    /// 回到图的开头（左上角）：画布的坐标原点在左下角，要滚到最上面
    func scrollToStart() {
        guard let canvas = documentView else { return }
        let visible = contentView.documentVisibleRect
        contentView.scroll(to: CGPoint(x: canvas.bounds.minX, y: max(canvas.bounds.minY, canvas.bounds.maxY - visible.height)))
        reflectScrolledClipView(contentView)
    }

    /// 双指捏合结束
    @objc private func liveMagnifyEnded() {
        followsWindowSize = false
        onScaleChange?()
        onZoom?()
    }
}

/// 编辑窗口里的画布：边界（bounds）是原图的点尺寸，外框（frame）是显示尺寸，
/// 由 AppKit 负责缩放显示和换算鼠标坐标，标注和文字输入框都直接使用原图坐标。
final class EditorCanvasView: NSView {
    weak var editor: AnnotationEditorWindowController?
    private let imageLayer = CALayer()

    init(image: CGImage, imageSize: CGSize, displaySize: CGSize, scale: CGFloat) {
        super.init(frame: CGRect(origin: .zero, size: displaySize))
        setBoundsSize(imageSize)
        wantsLayer = true
        // 不铺底色：切了圆角的截图四角透明，透出下面编辑界面的暖色背景（铺黑色的话四角是黑的）
        layer?.backgroundColor = nil
        imageLayer.frame = CGRect(origin: .zero, size: imageSize)
        imageLayer.contents = image
        imageLayer.contentsScale = scale
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func installAnnotationLayer(_ annotationLayer: CALayer) {
        annotationLayer.frame = bounds
        layer?.addSublayer(annotationLayer)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 窗口边缘这一圈系统要显示调整窗口大小的箭头：画布的光标不能盖住它
    private static let windowEdgeMargin: CGFloat = 6

    private func isNearWindowEdge(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        let p = event.locationInWindow, size = window.frame.size, m = Self.windowEdgeMargin
        return p.x < m || p.y < m || p.x > size.width - m || p.y > size.height - m
    }

    override func resetCursorRects() {
        guard let editor, let window else { return }
        // 只在可见部分、并让出窗口边缘那一圈
        let inner = CGRect(origin: .zero, size: window.frame.size).insetBy(dx: Self.windowEdgeMargin, dy: Self.windowEdgeMargin)
        let rect = visibleRect.intersection(convert(inner, from: nil))
        if !rect.isEmpty { addCursorRect(rect, cursor: editor.canvasCursor) }
    }

    /// 跟踪鼠标移动，悬停在标注上时换成四向移动光标
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isNearWindowEdge(event) else { return }
        editor?.canvasCursor(at: point(event)).set()
    }

    private func point(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)   // 已经换算成原图坐标（bounds）
    }

    override func mouseDown(with event: NSEvent) { editor?.canvasMouseDown(at: point(event)) }
    override func mouseDragged(with event: NSEvent) {
        editor?.canvasMouseDragged(to: point(event))
        editor?.canvasCursor(at: point(event)).set()
    }
    override func mouseUp(with event: NSEvent) {
        editor?.canvasMouseUp(at: point(event))
        editor?.canvasCursor(at: point(event)).set()
    }
}

/// 编辑窗口的「桌面」：图片画布放在中间，四周留一圈暖色边距，图片带柔和投影、像浮在上面，边界一目了然。
/// 边距里点不到画布，所以标注只能从图片里开始画。
final class EditorDesk: NSView {
    /// 两层投影：大而柔和的环境投影 + 贴近图片的接触投影，图片看起来浮在编辑界面上面
    private let ambientShadow = CALayer()
    private let contactShadow = CALayer()

    init(canvas: NSView, image: CGImage, margin: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: canvas.frame.width + margin * 2, height: canvas.frame.height + margin * 2))
        wantsLayer = true
        layer?.masksToBounds = false
        canvas.setFrameOrigin(CGPoint(x: margin, y: margin))
        // 投影单独放在图片下面（图片自己要裁剪掉超出边界的标注，不能带投影）。
        // 投影按图片本身的形状算：截的窗口四角是透明的圆角，投影也是同样的圆角；不垫方形的底板——
        // 垫了的话，透明的圆角处会露出方块的直角和它的投影，四个角看着很别扭
        let shadowColor = NSColor(srgbRed: 0.22, green: 0.13, blue: 0.07, alpha: 1).cgColor
        let corner = Self.transparentCornerRadius(of: image) * canvas.frame.width / CGFloat(max(1, image.width))
        let shape = CGPath(roundedRect: CGRect(origin: .zero, size: canvas.frame.size), cornerWidth: corner, cornerHeight: corner,
                           transform: nil)
        for (shadow, radius, opacity, offset) in [(ambientShadow, CGFloat(22), Float(0.30), CGFloat(-9)),
                                                  (contactShadow, CGFloat(3), Float(0.22), CGFloat(-1))] {
            shadow.frame = canvas.frame
            shadow.shadowPath = shape
            shadow.shadowColor = shadowColor
            shadow.shadowOpacity = opacity
            shadow.shadowRadius = radius
            shadow.shadowOffset = CGSize(width: 0, height: offset)
            layer?.addSublayer(shadow)
        }
        addSubview(canvas)
        canvas.layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    /// 图片四角透明的圆角有多大（像素）：沿左上角的对角线往里找第一个不透明的像素，
    /// 圆弧到对角线的距离是半径的 (1 - 1/√2) 倍。四角不透明（普通截图、长截图）时是 0
    static func transparentCornerRadius(of image: CGImage) -> CGFloat {
        let size = min(64, image.width, image.height)
        guard size > 0, image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst,
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        // 只画左上角那一小块（CGContext 原点在左下角：把图片的顶部对齐到这块的顶部）
        ctx.draw(image, in: CGRect(x: 0, y: size - image.height, width: image.width, height: image.height))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        for k in 0..<size where data[k * size * 4 + k * 4 + 3] > 200 {   // 位图的第 0 行是最上面一行
            return k == 0 ? 0 : CGFloat(k) / (1 - 1 / 2.0.squareRoot())
        }
        return 0
    }
}

/// 缩小到比窗口还小时，把图片放在中间（系统默认贴在左下角）
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if frame.width < rect.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if frame.height < rect.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}

/// 暖色滚动条：透明的轨道，杏色圆角滑块（鼠标放上去更明显）
final class WarmScroller: NSScroller {
    private var hovering = false { didSet { needsDisplay = true } }

    override class var isCompatibleWithOverlayScrollers: Bool { false }
    /// 轨道透明，露出下面的暖色桌面
    override var isOpaque: Bool { false }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func draw(_ dirtyRect: NSRect) {
        // 轨道涂成桌面色（系统的轨道是白色），只留杏色滑块
        EditorZoomView.deskColor.setFill()
        dirtyRect.fill()
        drawKnob()
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let vertical = bounds.height > bounds.width
        let thickness: CGFloat = hovering ? 9 : 7
        let rect = vertical
            ? CGRect(x: knob.midX - thickness / 2, y: knob.minY + 3, width: thickness, height: knob.height - 6)
            : CGRect(x: knob.minX + 3, y: knob.midY - thickness / 2, width: knob.width - 6, height: thickness)
        WarmPalette.apricot.withAlphaComponent(hovering ? 0.95 : 0.7).setFill()
        NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}
