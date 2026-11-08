import AppKit
import Carbon.HIToolbox

/// 重新编辑窗口：单击缩略图打开，在已完成的截图上继续标注。
/// 和截图界面用同一套标注工具、工具栏和快捷键（Enter 完成、⌘S 保存、⌘Z 撤销、Esc 关闭）。
/// 图片太大时按比例缩小显示，但标注坐标始终是原图坐标，输出仍是原生分辨率。
@MainActor
final class AnnotationEditorWindowController: NSObject, NSWindowDelegate {
    private static var openEditors: [AnnotationEditorWindowController] = []

    private let capture: CapturedImage
    private let window: EditorWindow
    private let canvas: EditorCanvasView
    private let toolbar = AnnotationToolbar()
    private let annotator: AnnotationController

    private static let padding: CGFloat = 16

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
        let maxSize = CGSize(width: visible.width * 0.9 - Self.padding * 2,
                             height: visible.height * 0.9 - toolbarArea - Self.padding * 2 - 28)
        let zoom = min(1, maxSize.width / imageSize.width, maxSize.height / imageSize.height)
        let displaySize = CGSize(width: (imageSize.width * zoom).rounded(), height: (imageSize.height * zoom).rounded())
        annotator.canvasUnitsPerPoint = 1 / zoom   // 缩小显示时，控制点在屏幕上仍是同样大小

        canvas = EditorCanvasView(image: image, imageSize: imageSize, displaySize: displaySize, scale: capture.scale)
        let contentSize = CGSize(width: max(displaySize.width + Self.padding * 2, 560),
                                 height: displaySize.height + Self.padding * 2 + toolbarArea)
        window = EditorWindow(contentRect: CGRect(origin: .zero, size: contentSize),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()

        window.title = "编辑截图"
        window.identifier = ScreenFreezer.capturableIdentifier
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.editor = self
        let content = NSView(frame: CGRect(origin: .zero, size: contentSize))
        canvas.setFrameOrigin(CGPoint(x: ((contentSize.width - displaySize.width) / 2).rounded(),
                                      y: toolbarArea + Self.padding))
        content.addSubview(canvas)
        content.addSubview(toolbar)
        window.contentView = content

        canvas.editor = self
        annotator.hostView = canvas
        annotator.canvasBounds = CGRect(origin: .zero, size: imageSize)
        annotator.tool = .rectangle   // 打开编辑窗口就是为了标注：默认选中矩形
        annotator.onChange = { [weak self] in self?.updateToolbar() }
        canvas.installAnnotationLayer(annotator.layer)

        toolbar.onSelectTool = { [weak self] tool in self?.annotator.tool = tool }
        toolbar.onSelectColor = { [weak self] color in self?.updateStyle { $0.color = color } }
        toolbar.onSelectSize = { [weak self] size in self?.updateStyle { $0.size = size } }
        toolbar.onSelectOpacity = { [weak self] opacity in self?.updateStyle { $0.opacity = opacity } }
        toolbar.onPickColor = { [weak self] color, opacity in
            self?.updateStyle {
                $0.color = color
                if let opacity { $0.opacity = min(max(opacity, 0.1), 1) }
            }
        }
        toolbar.onAction = { [weak self] action in self?.perform(action) }
        updateToolbar()

        window.setFrame(window.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)), display: false)
        window.centerOnScreen()
    }

    private func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // 系统没同意切到前台时（macOS 的协作式激活），普通窗口会被压在其他 App 后面；强制放到最前
        window.orderFrontRegardless()
    }

    private func updateStyle(_ change: (inout AnnotationStyle) -> Void) {
        // 从属性栏当前显示的样式改起（选中标注时显示的是它的样式）
        var style = annotator.displayedStyle
        change(&style)
        annotator.applyStyle(style)
    }

    private func updateToolbar() {
        toolbar.update(tool: annotator.tool, style: annotator.displayedStyle,
                       canUndo: annotator.document.canUndo, canRedo: annotator.document.canRedo,
                       selectionTool: annotator.selectedAnnotation?.tool)
        guard let content = window.contentView else { return }
        let size = toolbar.frame.size
        // 主栏固定在画布下方居中；属性栏出现时向下展开
        toolbar.setFrameOrigin(CGPoint(x: ((content.bounds.width - size.width) / 2).rounded(),
                                       y: canvas.frame.minY - 10 - size.height))
        canvas.window?.invalidateCursorRects(for: canvas)
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
        let isArrow = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(Int(event.keyCode))
        if event.isARepeat && !isArrow { return true }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape:
            if toolbar.closeColorPicker() {
                break
            } else if annotator.isEditingText {
                annotator.endTextEditing()
            } else if !annotator.deselect() {
                window.close()
            }
        case kVK_Delete, kVK_ForwardDelete:
            return annotator.deleteSelection()
        case _ where isArrow && annotator.hasSelection:
            let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
            switch Int(event.keyCode) {
            case kVK_LeftArrow: annotator.moveSelection(dx: -step, dy: 0)
            case kVK_RightArrow: annotator.moveSelection(dx: step, dy: 0)
            case kVK_UpArrow: annotator.moveSelection(dx: 0, dy: step)
            default: annotator.moveSelection(dx: 0, dy: -step)
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            finish(save: false)
        case kVK_ANSI_S where modifiers == .command:
            finish(save: true)
        case kVK_ANSI_W where modifiers == .command:
            window.close()
        case kVK_ANSI_Z where modifiers == .command:
            annotator.undo()
        case kVK_ANSI_Z where modifiers == [.command, .shift]:
            annotator.redo()
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
        annotator.mouseDragged(to: point, shift: NSEvent.modifierFlags.contains(.shift))
    }

    func canvasMouseUp(at point: CGPoint) {
        annotator.mouseUp(at: point, shift: NSEvent.modifierFlags.contains(.shift))
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
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
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
