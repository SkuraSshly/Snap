import AppKit
import Carbon.HIToolbox

/// 重新编辑窗口：单击缩略图打开，在已完成的截图上继续标注。
/// 和截图界面用同一套标注工具、工具栏和快捷键（Enter 完成、⌘S 保存、⌘Z 撤销、Esc 关闭）。
/// 图片太大时按比例缩小显示，但标注坐标始终是原图坐标，输出仍是原生分辨率。
/// 按住 ⌥ 滚动（或双指捏合）以鼠标为中心缩放，放大后普通滚动移动查看位置；⌘= 放大、⌘- 缩小、⌘0 回到原来大小。
@MainActor
final class AnnotationEditorWindowController: NSObject, NSWindowDelegate {
    private static var openEditors: [AnnotationEditorWindowController] = []

    private let capture: CapturedImage
    private let window: EditorWindow
    private let canvas: EditorCanvasView
    /// 画布放在这里面：可以缩放、放大后可以滚动
    private let zoomView: EditorZoomView
    /// 打开时的显示比例（屏幕上 1 点 = 原图 1/fitZoom 点）
    private let fitZoom: CGFloat
    /// 屏幕上 1 个像素对应原图多少像素的换算：原图像素 / 屏幕像素 = pixelRatio / (fitZoom × 放大倍数)
    private let pixelRatio: CGFloat
    /// 缩放时短暂显示的比例（100% = 原图 1 个像素对应屏幕 1 个像素）
    private let zoomLabel = NSTextField(labelWithString: "")
    private var zoomLabelTask: Task<Void, Never>?
    private let toolbar = AnnotationToolbar()
    private let annotator: AnnotationController

    private static let padding: CGFloat = 16
    /// 图片四周露出的暖色「桌面」宽度：一眼看清图片的边界
    static let margin: CGFloat = 30

    @discardableResult
    static func open(_ capture: CapturedImage) -> AnnotationEditorWindowController? {
        guard let image = capture.image else { return nil }
        let editor = AnnotationEditorWindowController(capture: capture, image: image)
        openEditors.append(editor)
        editor.present()
        return editor
    }

    private init(capture: CapturedImage, image: CGImage) {
        self.capture = capture
        let imageSize = capture.pointSize
        annotator = AnnotationController(base: BaseImage(image: image, scale: capture.scale, canvasHeight: imageSize.height))

        // 显示大小：不超过所在屏幕可见区域（扣掉工具栏和边距）
        let screen = NSScreen.screen(containing: CGPoint(x: capture.sourceRect.midX, y: capture.sourceRect.midY))
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let toolbarArea = AnnotationToolbar.mainBarHeight * 2 + 6 + Self.padding
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let maxSize = CGSize(width: visible.width * 0.9 - Self.margin * 2 - scrollerWidth,
                             height: visible.height * 0.9 - toolbarArea - Self.margin * 2 - scrollerWidth - 28)
        // 整张图放得下的比例
        let fitAll = min(1, maxSize.width / imageSize.width, maxSize.height / imageSize.height)
        // 长截图：整张缩进窗口会小得看不清。竖着长的按宽度、横着长的按高度显示（最大 100%），另一个方向滚动查看
        let fitWidth = min(1, maxSize.width / imageSize.width), fitHeight = min(1, maxSize.height / imageSize.height)
        let zoom: CGFloat
        var viewSize: CGSize
        // 长截图要留出滚动条的位置：竖着长的在右边、横着长的在下面（滚动条不盖住图片）
        var scrollerRoom = CGSize.zero
        if imageSize.height * fitWidth > maxSize.height * 1.3 {
            zoom = fitWidth
            viewSize = CGSize(width: imageSize.width * zoom, height: maxSize.height)
            scrollerRoom.width = scrollerWidth
        } else if imageSize.width * fitHeight > maxSize.width * 1.3 {
            zoom = fitHeight
            viewSize = CGSize(width: maxSize.width, height: imageSize.height * zoom)
            scrollerRoom.height = scrollerWidth
        } else {
            zoom = fitAll
            viewSize = CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)
        }
        viewSize = CGSize(width: (viewSize.width + Self.margin * 2 + scrollerRoom.width).rounded(),
                          height: (viewSize.height + Self.margin * 2 + scrollerRoom.height).rounded())
        let displaySize = CGSize(width: (imageSize.width * zoom).rounded(), height: (imageSize.height * zoom).rounded())
        annotator.canvasUnitsPerPoint = 1 / zoom   // 缩小显示时，控制点在屏幕上仍是同样大小
        fitZoom = zoom

        canvas = EditorCanvasView(image: image, imageSize: imageSize, displaySize: displaySize, scale: capture.scale)
        // 最大放大到原图 1 个像素 = 屏幕 4 个像素（再大只是更大的马赛克，看不到更多细节）；最小能看到整张图
        pixelRatio = capture.scale / screen.backingScaleFactor
        zoomView = EditorZoomView(frame: CGRect(origin: .zero, size: viewSize), canvas: canvas,
                                  minMagnification: fitAll / zoom, maxMagnification: max(1, 4 * pixelRatio / zoom))
        let contentSize = CGSize(width: max(viewSize.width, 560), height: viewSize.height + toolbarArea)
        window = EditorWindow(contentRect: CGRect(origin: .zero, size: contentSize),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()

        window.title = "编辑截图"
        // 暖色风格：标题栏和窗口底色都是暖色的「桌面」，图片像一张纸放在上面
        window.titlebarAppearsTransparent = true
        window.backgroundColor = EditorZoomView.deskColor
        window.identifier = .velosCapturable
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.editor = self
        let content = NSView(frame: CGRect(origin: .zero, size: contentSize))
        zoomView.setFrameOrigin(CGPoint(x: ((contentSize.width - viewSize.width) / 2).rounded(),
                                        y: toolbarArea))
        content.addSubview(zoomView)
        zoomView.onZoom = { [weak self] in self?.zoomChanged() }
        zoomLabel.font = roundedFont(ofSize: 13, weight: .semibold, monospacedDigits: true)
        zoomLabel.textColor = .white
        zoomLabel.alignment = .center
        zoomLabel.wantsLayer = true
        zoomLabel.layer?.backgroundColor = NSColor(srgbRed: 0.18, green: 0.13, blue: 0.10, alpha: 0.8).cgColor
        zoomLabel.layer?.cornerRadius = 11
        zoomLabel.alphaValue = 0
        content.addSubview(zoomLabel)
        content.addSubview(toolbar)
        window.contentView = content

        canvas.editor = self
        annotator.hostView = canvas
        annotator.canvasBounds = CGRect(origin: .zero, size: imageSize)
        annotator.tool = .rectangle   // 打开编辑窗口就是为了标注：默认选中矩形
        annotator.onChange = { [weak self] in self?.updateToolbar() }
        canvas.installAnnotationLayer(annotator.layer)
        zoomView.scrollToStart()   // 长截图从开头看起

        toolbar.onSelectTool = { [weak self] tool in self?.annotator.tool = tool }
        toolbar.onSelectColor = { [weak self] color in self?.updateStyle { $0.color = color } }
        toolbar.onSelectSize = { [weak self] size in self?.updateStyle { $0.size = size } }
        toolbar.onSelectOpacity = { [weak self] opacity in self?.updateStyle { $0.opacity = opacity } }
        toolbar.onToggleFill = { [weak self] in self?.updateStyle { $0.filled.toggle() } }
        toolbar.onPickColor = { [weak self] color, opacity in
            self?.updateStyle {
                $0.color = color
                if let opacity { $0.opacity = min(max(opacity, 0.1), 1) }
            }
        }
        toolbar.onAction = { [weak self] action in self?.perform(action) }
        updateToolbar()

        // 窄的长截图：窗口至少和工具栏一样宽，工具栏不被截断
        var windowSize = contentSize
        windowSize.width = max(windowSize.width, (toolbar.frame.width + Self.padding * 2).rounded())
        if windowSize.width != contentSize.width {
            content.setFrameSize(windowSize)
            zoomView.setFrameOrigin(CGPoint(x: ((windowSize.width - viewSize.width) / 2).rounded(), y: toolbarArea))
        }
        window.setFrame(window.frameRect(forContentRect: CGRect(origin: .zero, size: windowSize)), display: false)
        updateToolbar()
        window.centerOnScreen()
    }

    private func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // 系统没同意切到前台时（macOS 的协作式激活），普通窗口会被压在其他 App 后面；强制放到最前
        window.orderFrontRegardless()
    }

    private func updateStyle(_ change: (inout AnnotationStyle) -> Void) {
        annotator.updateDisplayedStyle(change)
    }

    private func updateToolbar() {
        toolbar.update(tool: annotator.tool, style: annotator.displayedStyle,
                       canUndo: annotator.document.canUndo, canRedo: annotator.document.canRedo,
                       selectionTool: annotator.selectedAnnotation?.tool)
        guard let content = window.contentView else { return }
        let size = toolbar.frame.size
        // 主栏固定在画布下方居中；属性栏出现时向下展开
        toolbar.setFrameOrigin(CGPoint(x: ((content.bounds.width - size.width) / 2).rounded(),
                                       y: zoomView.frame.minY - 10 - size.height))
        canvas.window?.invalidateCursorRects(for: canvas)
    }

    // MARK: - 缩放

    /// 缩放后：控制点、点中范围按屏幕大小算，光标区域重新计算
    private func zoomChanged() {
        annotator.canvasUnitsPerPoint = 1 / (fitZoom * zoomView.magnification)
        annotator.layer.setNeedsDisplay()
        window.invalidateCursorRects(for: canvas)
        showZoomLabel()
    }

    /// 当前比例：100% = 原图 1 个像素对应屏幕 1 个像素（原像素）
    var zoomPercent: Int { Int((fitZoom * zoomView.magnification / pixelRatio * 100).rounded()) }

    /// 在图片上方中间显示比例，1.2 秒后淡出
    private func showZoomLabel() {
        zoomLabel.stringValue = "\(zoomPercent)%"
        let size = CGSize(width: max(64, zoomLabel.fittingSize.width + 22), height: 22)
        let frame = zoomView.frame
        zoomLabel.frame = CGRect(x: (frame.midX - size.width / 2).rounded(), y: frame.maxY - size.height - 10,
                                 width: size.width, height: size.height)
        zoomLabel.alphaValue = 1
        zoomLabelTask?.cancel()
        zoomLabelTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.zoomLabel.animator().alphaValue = 0 },
                                                completionHandler: nil)
        }
    }

    // MARK: - 操作

    func perform(_ action: AnnotationToolbar.Action) {
        switch action {
        case .undo: annotator.undo()
        case .redo: annotator.redo()
        case .cancel: window.close()
        case .done: finish(save: false)
        case .save: finish(save: true)
        case .longCapture: break   // 编辑窗口没有长截图按钮
        case .pin:
            guard let image = render() else { return }
            window.close()
            _ = PinManager.shared.pin(CapturedImage(image: image, scale: capture.scale, sourceRect: capture.sourceRect))
        }
    }

    /// 完成：按设置复制、显示缩略图（save 为 true 时同时保存）
    private func finish(save: Bool) {
        guard let image = render() else { return }
        window.close()
        ScreenshotOutput.deliver(image, scale: capture.scale, sourceRect: capture.sourceRect, forceSave: save)
    }

    /// 原图 + 标注，原生分辨率
    private func render() -> CGImage? {
        annotator.endTextEditing()
        if annotator.document.isEmpty { return capture.image }
        return annotator.composite(cropping: CGRect(origin: .zero, size: capture.pointSize))
    }

    // MARK: - 键盘

    func handleKey(_ event: NSEvent) -> Bool {
        // 方向键允许按住连续移动，其他键忽略自动重复
        if event.isARepeat && ArrowKey.direction(event.keyCode) == nil { return true }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // Esc：调色盘开着时先关调色盘；之后的「结束文字输入 → 取消选中」和其他标注按键交给标注控制器（和截图界面共用）
        if Int(event.keyCode) == kVK_Escape, toolbar.closeColorPicker() { return true }
        if let handled = annotator.handleEditingKey(event) { return handled }
        switch Int(event.keyCode) {
        case kVK_Escape:
            window.close()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            finish(save: false)
        case kVK_ANSI_S where modifiers == .command:
            finish(save: true)
        case kVK_ANSI_W where modifiers == .command:
            window.close()
        case kVK_ANSI_Equal where modifiers == .command || modifiers == [.command, .shift],
             kVK_ANSI_KeypadPlus where modifiers == .command:
            zoomView.zoom(by: 1.25)
        case kVK_ANSI_Minus where modifiers == .command, kVK_ANSI_KeypadMinus where modifiers == .command:
            zoomView.zoom(by: 0.8)
        case kVK_ANSI_0 where modifiers == .command:
            zoomView.zoomToFit()
        default:
            return false
        }
        return true
    }

    /// 输入文字时 ⌘S 也要生效
    func shouldIntercept(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return annotator.isEditingText && Int(event.keyCode) == kVK_ANSI_S && modifiers == .command
    }

    // MARK: - 鼠标（来自画布，已是原图坐标）

    func canvasMouseDown(at point: CGPoint) {
        _ = annotator.mouseDown(at: point, shift: NSEvent.modifierFlags.contains(.shift))
    }

    func canvasMouseDragged(to point: CGPoint) {
        annotator.mouseDragged(to: clampedToImage(point), shift: NSEvent.modifierFlags.contains(.shift))
    }

    func canvasMouseUp(at point: CGPoint) {
        annotator.mouseUp(at: clampedToImage(point), shift: NSEvent.modifierFlags.contains(.shift))
    }

    /// 拖到图片外面时按图片边缘算：标注只能画、只能拖在图片范围里
    private func clampedToImage(_ point: CGPoint) -> CGPoint {
        let size = capture.pointSize
        return CGPoint(x: min(max(point.x, 0), size.width), y: min(max(point.y, 0), size.height))
    }

    var canvasCursor: NSCursor {
        switch annotator.tool {
        case .none: .arrow
        case .text: .iBeam
        default: .crosshair
        }
    }

    /// 鼠标所在位置的光标：选中标注的控制点上是调整大小的箭头；正好在已有标注上（或正在拖动）时是四向移动光标
    func canvasCursor(at point: CGPoint) -> NSCursor {
        if toolbar.isShowingColorPicker { return .arrow }
        if let cursor = annotator.resizeCursor(at: point) { return cursor }
        if annotator.isMovingAnnotation || annotator.grabbableAnnotation(at: point) != nil { return .snapMove }
        return canvasCursor
    }

    func windowWillClose(_ notification: Notification) {
        annotator.endTextEditing()
        Self.openEditors.removeAll { $0 === self }
    }

    #if DEBUG
    var debugAnnotator: AnnotationController { annotator }
    var debugWindow: NSWindow { window }
    var debugCanvas: NSView { canvas }
    var debugZoomView: EditorZoomView { zoomView }
    #endif
}

/// 编辑窗口：把按键交给编辑器处理
final class EditorWindow: NSWindow {
    weak var editor: AnnotationEditorWindowController?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let editor, editor.shouldIntercept(event) {
            _ = editor.handleKey(event)
            return
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if editor?.handleKey(event) != true { super.keyDown(with: event) }
    }
}

/// 编辑窗口里放画布的滚动视图：按住 ⌥ 滚动以鼠标为中心缩放（双指捏合也可以），放大后普通滚动移动查看位置。
/// 最小是整张图都看得见（长截图打开时只显示一部分，可以缩小到看全）
final class EditorZoomView: NSScrollView {
    /// 缩放比例变了（包括双指捏合结束时）
    var onZoom: (() -> Void)?

    /// 图片下面的暖色「桌面」：浅色模式是奶咖色，深色模式是深可可色，和图片明显区分开
    static let deskColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.16, green: 0.13, blue: 0.11, alpha: 1)
            : NSColor(srgbRed: 0.91, green: 0.86, blue: 0.80, alpha: 1)
    }

    /// - Parameter canvas: 图片画布；外面包一层四周留边距的「桌面」，缩小到比窗口还小时居中
    init(frame: CGRect, canvas: NSView, minMagnification: CGFloat, maxMagnification: CGFloat) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        documentView = EditorDesk(canvas: canvas, margin: AnnotationEditorWindowController.margin)
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
        setMagnification(min(max(magnification * factor, minMagnification), maxMagnification), centeredAt: anchor)
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
        setMagnification(min(max(magnification * factor, minMagnification), maxMagnification), centeredAt: center)
        onZoom?()
    }

    /// 回到打开时的大小（⌘0）
    func zoomToFit() {
        magnification = 1
        scrollToStart()
        onZoom?()
    }

    /// 回到图的开头（左上角）：画布的坐标原点在左下角，要滚到最上面
    func scrollToStart() {
        guard let canvas = documentView else { return }
        let visible = contentView.documentVisibleRect
        contentView.scroll(to: CGPoint(x: canvas.bounds.minX, y: max(canvas.bounds.minY, canvas.bounds.maxY - visible.height)))
        reflectScrolledClipView(contentView)
    }

    @objc private func liveMagnifyEnded() { onZoom?() }
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
        layer?.backgroundColor = NSColor.black.cgColor
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

    override func resetCursorRects() {
        if let editor { addCursorRect(bounds, cursor: editor.canvasCursor) }
    }

    /// 跟踪鼠标移动，悬停在标注上时换成四向移动光标
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
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

/// 编辑窗口的「桌面」：图片画布放在中间，四周留一圈暖色边距，图片带柔和投影和细边，边界一目了然。
/// 边距里点不到画布，所以标注只能从图片里开始画。
final class EditorDesk: NSView {
    /// 两层投影：大而柔和的环境投影 + 贴近图片的接触投影，图片看起来浮在编辑界面上面
    private let ambientShadow = CALayer()
    private let contactShadow = CALayer()

    init(canvas: NSView, margin: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: canvas.frame.width + margin * 2, height: canvas.frame.height + margin * 2))
        wantsLayer = true
        layer?.masksToBounds = false
        canvas.setFrameOrigin(CGPoint(x: margin, y: margin))
        // 投影单独放在图片下面（图片自己要裁剪掉超出边界的标注，不能带投影）
        let shadowColor = NSColor(srgbRed: 0.22, green: 0.13, blue: 0.07, alpha: 1).cgColor
        for (shadow, radius, opacity, offset) in [(ambientShadow, CGFloat(22), Float(0.30), CGFloat(-9)),
                                                  (contactShadow, CGFloat(3), Float(0.22), CGFloat(-1))] {
            shadow.frame = canvas.frame
            shadow.backgroundColor = NSColor.white.cgColor
            shadow.shadowColor = shadowColor
            shadow.shadowOpacity = opacity
            shadow.shadowRadius = radius
            shadow.shadowOffset = CGSize(width: 0, height: offset)
            shadow.shadowPath = CGPath(rect: CGRect(origin: .zero, size: canvas.frame.size), transform: nil)
            layer?.addSublayer(shadow)
        }
        addSubview(canvas)
        canvas.layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }
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
