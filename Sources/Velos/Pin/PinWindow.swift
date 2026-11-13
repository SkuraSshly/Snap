import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// 很长（或很宽）的图的方向：钉图时按它滚动查看
enum ScrollAxis: Sendable {
    case vertical, horizontal
}

/// 钉在屏幕上的截图：置顶的浮动小窗。
/// - 单击选中（杏色边框），选中后按 Esc 关闭、⌘C 复制；双击直接关闭
/// - 拖动移动；滚轮 / 触控板双指捏合缩放（以鼠标位置为中心）
/// - 拖边缘、四个角调整大小：保持长宽比，对面的边 / 角不动（边缘上是暖色的调整大小光标）。
///   窗口比图大一圈（四周各 gripMargin 点，几乎全透明）：钉图常常正好盖在同样大小的 App 窗口上，
///   那个窗口的边缘向外还有几点能拖动调整大小，没有这一圈的话，抓边缘时稍微偏外就抓到了下面的窗口
/// - 钉上以后自动选中（显示杏色边框，按 Esc 就能关）
/// - 长截图：窗口只露出一段，滚轮在窗口里翻看；⌥ + 滚轮、双指捏合缩放
/// - ⌘ + 滚轮调整透明度；右键菜单里也有透明度、原始大小、复制、存储
/// 窗口是「不激活」的面板：选中它不会把正在用的 App 切到后台。
final class PinWindow: NSPanel {
    init(capture: CapturedImage, image: CGImage, frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // 比程序坞高一级（不会被程序坞挡住），又低于菜单栏（不挡菜单）；普通的浮动层级会被程序坞盖住
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        contentView = PinView(capture: capture, image: image)
    }

    /// 图四周看不见的抓取边（点）
    static let gripMargin: CGFloat = 6

    /// 图本身在屏幕上的位置和大小（窗口去掉四周的抓取边）
    var contentFrame: CGRect { frame.insetBy(dx: Self.gripMargin, dy: Self.gripMargin) }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var pinView: PinView? { contentView as? PinView }

    override func becomeKey() {
        super.becomeKey()
        pinView?.isSelected = true
    }

    override func resignKey() {
        super.resignKey()
        pinView?.isSelected = false
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape where modifiers.isEmpty:
            close()
        case kVK_ANSI_C where modifiers == .command:
            pinView?.copyToClipboard()
        default:
            super.keyDown(with: event)
        }
    }

    /// 系统的「取消」操作（Esc 也会走到这里）
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

final class PinView: NSView {
    private let capture: CapturedImage
    private let image: CGImage
    /// 图所在的那一层（裁掉超出的部分：长截图只露出一段）；四周留出抓取边
    private let contentLayer = CALayer()
    private let imageLayer = CALayer()
    private let borderLayer = CAShapeLayer()

    /// 图在视图里的位置：去掉四周的抓取边
    private var content: CGRect { bounds.insetBy(dx: PinWindow.gripMargin, dy: PinWindow.gripMargin) }
    private let indicator = PillLabel(padding: NSSize(width: 10, height: 4))
    private var indicatorTimer: Timer?

    /// 相对原始大小的缩放比例（从窗口第一次的大小算出来：钉图可能被缩小显示）
    private var zoom: CGFloat = 1
    private var zoomKnown = false
    /// 长截图：沿哪个方向长（窗口只露出一段，可以滚动）；普通截图为 nil
    private let longAxis: ScrollAxis?
    /// 长截图已经滚过的距离（点，从开头算）
    private var scrollOffset: CGFloat = 0
    private static let zoomRange: ClosedRange<CGFloat> = 0.1...8
    private static let opacityRange: ClosedRange<CGFloat> = 0.2...1

    /// 拖边缘调整大小：边缘往里多宽、角落多大的范围能抓住（钉图很小时按比例缩小，中间总留一块用来移动）
    private static let edgeGrip: CGFloat = 6
    private static let cornerGrip: CGFloat = 14
    /// 钉图最小多大（点）
    private static let minimumSide: CGFloat = 40

    /// 正在拖边缘：哪个边 / 角、按下时鼠标的位置（屏幕坐标）、窗口的位置和大小、缩放比例
    private struct Resize {
        let handle: RegionSelector.Handle
        let start: CGPoint
        let frame: CGRect
        let zoom: CGFloat
    }
    private var resizing: Resize?
    private var trackingArea: NSTrackingArea?

    init(capture: CapturedImage, image: CGImage) {
        self.capture = capture
        self.image = image
        longAxis = Self.longAxis(for: capture.pointSize)
        super.init(frame: CGRect(origin: .zero, size: capture.pointSize))
        wantsLayer = true
        // 四周的抓取边：几乎全透明（完全透明的地方鼠标会穿透到下面的窗口，就抓不住了）
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.004).cgColor
        contentLayer.masksToBounds = true   // 长截图只显示窗口里的那一段
        layer?.addSublayer(contentLayer)

        // 原始大小时，图层的点尺寸 × contentsScale 正好等于图像像素，一个像素对一个像素显示
        imageLayer.contents = image
        imageLayer.contentsScale = capture.scale
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear   // 缩小时用三线性过滤，文字不出现锯齿
        imageLayer.magnificationFilter = .linear
        contentLayer.addSublayer(imageLayer)

        // 边框画在图像上层：未选中时是淡淡的白边，选中时是醒目的蓝边
        borderLayer.fillColor = nil
        borderLayer.contentsScale = capture.scale
        layer?.addSublayer(borderLayer)
        updateBorder()

        indicator.isHidden = true
        addSubview(indicator)
    }

    /// 选中状态（窗口成为焦点）：选中后 Esc 可关闭
    var isSelected = false {
        didSet { updateBorder() }
    }

    private func updateBorder() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width: CGFloat = isSelected ? 2 : 1
        borderLayer.lineWidth = width
        borderLayer.strokeColor = (isSelected ? OverlayAccent.screenshot : NSColor.white.withAlphaComponent(0.35)).cgColor
        // 沿内侧描边，不超出窗口
        borderLayer.path = CGPath(rect: content.insetBy(dx: width / 2, dy: width / 2), transform: nil)
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 长宽比超过 2.5 算长截图
    static func longAxis(for size: CGSize) -> ScrollAxis? {
        guard size.width > 0, size.height > 0 else { return nil }
        if size.height / size.width > 2.5 { return .vertical }
        if size.width / size.height > 2.5 { return .horizontal }
        return nil
    }

    /// 缩放后整张图的大小
    private var imageSize: CGSize {
        CGSize(width: capture.pointSize.width * zoom, height: capture.pointSize.height * zoom)
    }

    /// 长截图能滚多远
    private var maxScroll: CGFloat {
        switch longAxis {
        case .vertical: max(0, imageSize.height - content.height)
        case .horizontal: max(0, imageSize.width - content.width)
        case nil: 0
        }
    }

    /// 图层位置（在 contentLayer 里）：普通截图铺满；长截图按滚动的距离露出对应的一段（竖向从上往下、横向从左往右）
    private var imageFrame: CGRect {
        let area = content.size
        let size = longAxis == nil ? area : imageSize
        switch longAxis {
        case .vertical: return CGRect(x: 0, y: area.height - size.height + scrollOffset, width: area.width, height: size.height)
        case .horizontal: return CGRect(x: -scrollOffset, y: 0, width: size.width, height: area.height)
        case nil: return CGRect(origin: .zero, size: area)
        }
    }

    override func layout() {
        super.layout()
        if !zoomKnown, content.width > 0 {
            // 第一次布局：图的大小 / 原始大小 = 当前比例（钉图可能被缩小显示，之后的缩放从这里算起）
            zoom = longAxis == .horizontal ? content.height / capture.pointSize.height : content.width / capture.pointSize.width
            zoomKnown = true
            if longAxis != nil { showIndicator("滚轮翻看，⌥ + 滚轮缩放") }
        }
        scrollOffset = min(max(scrollOffset, 0), maxScroll)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = content
        imageLayer.frame = imageFrame
        borderLayer.frame = bounds
        CATransaction.commit()
        updateBorder()
        placeIndicator()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.close()
            return
        }
        window?.makeKey()
        // 按在边缘、角上：调整大小（之后的拖动在 mouseDragged 里）
        if let handle = handle(at: convert(event.locationInWindow, from: nil)), let window {
            resizing = Resize(handle: handle, start: NSEvent.mouseLocation, frame: window.frame, zoom: zoom)
            handle.cursor.set()
            return
        }
        // 单击：选中这张钉图（之后按 Esc 关闭）；按住拖动：移动窗口（系统负责跟随鼠标，松开时返回）
        window?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let resizing else { return super.mouseDragged(with: event) }
        let point = NSEvent.mouseLocation
        resize(resizing, by: CGSize(width: point.x - resizing.start.x, height: point.y - resizing.start.y))
        resizing.handle.cursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard resizing != nil else { return super.mouseUp(with: event) }
        resizing = nil
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: - 拖边缘调整大小

    /// 鼠标下面是哪个边 / 角：图的边缘往里一小条，加上图外面那一圈抓取边；中间返回 nil（拖动是移动）
    func handle(at p: CGPoint) -> RegionSelector.Handle? {
        let c = content, w = c.width, h = c.height
        let grip = min(Self.edgeGrip, w / 4, h / 4), corner = min(Self.cornerGrip, w / 3, h / 3)
        let left = p.x <= c.minX + grip, right = p.x >= c.maxX - grip
        let bottom = p.y <= c.minY + grip, top = p.y >= c.maxY - grip
        guard left || right || bottom || top else { return nil }
        let nearLeft = p.x <= c.minX + corner, nearRight = p.x >= c.maxX - corner
        let nearBottom = p.y <= c.minY + corner, nearTop = p.y >= c.maxY - corner
        if nearTop && nearLeft { return .topLeft }
        if nearTop && nearRight { return .topRight }
        if nearBottom && nearLeft { return .bottomLeft }
        if nearBottom && nearRight { return .bottomRight }
        if left { return .left }
        if right { return .right }
        return top ? .top : .bottom
    }

    /// 按拖动的距离调整大小（都从按下时的样子算，不会越拖越偏）。
    /// - 普通钉图、长截图拖角、长截图拖短边：保持长宽比缩放，对面的边 / 角不动
    /// - 长截图拖长的那个方向的边（竖着长的拖上下边）：只改窗口露出多少，不缩放
    private func resize(_ r: Resize, by d: CGSize) {
        guard window != nil else { return }
        let m = PinWindow.gripMargin
        let f = r.frame.insetBy(dx: m, dy: m)   // 图本身（按下时）
        var width = f.width, height = f.height
        switch r.handle {
        case .left, .topLeft, .bottomLeft: width -= d.width
        case .right, .topRight, .bottomRight: width += d.width
        case .top, .bottom: break
        }
        switch r.handle {
        case .top, .topLeft, .topRight: height += d.height
        case .bottom, .bottomLeft, .bottomRight: height -= d.height
        case .left, .right: break
        }
        let alongLong = (longAxis == .vertical && (r.handle == .top || r.handle == .bottom))
            || (longAxis == .horizontal && (r.handle == .left || r.handle == .right))
        if alongLong {
            // 只改露出的长度：在最小大小和整张图的长度之间；对面的边不动
            var frame = f
            if longAxis == .vertical {
                frame.size.height = min(max(height, Self.minimumSide), imageSize.height).rounded()
                if r.handle == .bottom { frame.origin.y = f.maxY - frame.height }
            } else {
                frame.size.width = min(max(width, Self.minimumSide), imageSize.width).rounded()
                if r.handle == .left { frame.origin.x = f.maxX - frame.width }
            }
            window?.setFrame(frame.insetBy(dx: -m, dy: -m), display: true)
            return
        }
        // 缩放：拖边按这条边的方向算，拖角按动得多的那个方向算
        let sx = width / f.width, sy = height / f.height
        let scale: CGFloat = switch r.handle {
        case .left, .right: sx
        case .top, .bottom: sy
        default: abs(sx - 1) >= abs(sy - 1) ? sx : sy
        }
        let smallest = Self.minimumSide / min(f.width, f.height)
        // 对面的边 / 角不动：以它为中心缩放（位置用比例表示：0 是左 / 下，1 是右 / 上）
        let (fx, fy): (CGFloat, CGFloat) = switch r.handle {
        case .left: (1, 0.5)
        case .right: (0, 0.5)
        case .top: (0.5, 0)
        case .bottom: (0.5, 1)
        case .topLeft: (1, 0)
        case .topRight: (0, 0)
        case .bottomLeft: (1, 1)
        case .bottomRight: (0, 1)
        }
        let c = content
        setZoom(r.zoom * max(scale, smallest), anchor: CGPoint(x: c.minX + fx * c.width, y: c.minY + fy * c.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if resizing == nil { NSCursor.arrow.set() }
    }

    /// 边缘、角上是暖色的调整大小光标（和截图选区的控制点同一种），中间是箭头
    private func updateCursor(at point: CGPoint) {
        guard resizing == nil else { return }
        (handle(at: point)?.cursor ?? .arrow).set()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        guard delta != 0, let window else { return }
        if event.modifierFlags.contains(.command) {
            // ⌘ + 滚轮：透明度
            let alpha = (window.alphaValue + delta * 0.005).clamped(to: Self.opacityRange)
            window.alphaValue = alpha
            showIndicator("透明度 \(Int((alpha * 100).rounded()))%")
        } else if let longAxis, !event.modifierFlags.contains(.option) {
            // 长截图：滚轮在窗口里翻看（按住 ⌥ 才是缩放）
            let raw = longAxis == .vertical ? event.scrollingDeltaY : (event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY)
            let step = event.hasPreciseScrollingDeltas ? raw : raw * 12
            scrollOffset = min(max(scrollOffset - step, 0), maxScroll)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.frame = imageFrame
            CATransaction.commit()
        } else {
            setZoom(zoom * exp(delta * 0.01), anchor: convert(event.locationInWindow, from: nil))
        }
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    /// 以 anchor（视图坐标）为中心缩放，保持该点在屏幕上的位置不变
    private func setZoom(_ newZoom: CGFloat, anchor: CGPoint) {
        guard let window else { return }
        let m = PinWindow.gripMargin
        let clamped = newZoom.clamped(to: Self.zoomRange)
        let base = capture.pointSize
        var newSize = CGSize(width: (base.width * clamped).rounded(), height: (base.height * clamped).rounded())
        guard newSize.width >= 20, newSize.height >= 20 else { return }
        // 长截图：窗口最多占屏幕的 85%，多出来的在窗口里滚动；滚动的位置按比例跟着缩放
        if let longAxis, let visible = window.screen?.visibleFrame {
            switch longAxis {
            case .vertical: newSize.height = min(newSize.height, (visible.height * 0.85).rounded())
            case .horizontal: newSize.width = min(newSize.width, (visible.width * 0.85).rounded())
            }
            scrollOffset *= clamped / zoom
        }
        zoom = clamped

        // 图本身：anchor 在图里的比例位置不变
        let old = window.frame.insetBy(dx: m, dy: m)
        let local = CGPoint(x: anchor.x - m, y: anchor.y - m)
        let fx = old.width > 0 ? local.x / old.width : 0.5
        let fy = old.height > 0 ? local.y / old.height : 0.5
        let origin = CGPoint(x: old.minX + local.x - fx * newSize.width,
                             y: old.minY + local.y - fy * newSize.height)
        window.setFrame(CGRect(origin: origin, size: newSize).insetBy(dx: -m, dy: -m), display: true)
        showIndicator("\(Int((zoom * 100).rounded()))%")
    }

    // MARK: - 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "存储为…", action: #selector(saveImage), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "原始大小", action: #selector(resetZoom), keyEquivalent: "").target = self

        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 80, 60, 40] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = percent
            item.target = self
            item.state = abs((window?.alphaValue ?? 1) * 100 - CGFloat(percent)) < 1 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭（双击 / Esc）", action: #selector(closePin), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() {
        copyToClipboard()
    }

    func copyToClipboard() {
        guard let png = capture.pngData() else { return }
        ClipboardWriter.write(png: png, to: .general)
        showIndicator("已复制")
    }

    @objc private func saveImage() {
        let format = Preferences.shared.imageFormat
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SaveLocation.fileName(prefix: "截图", fileExtension: format.fileExtension, date: capture.date)
        panel.directoryURL = SaveLocation.directory(for: .screenshot)
        panel.allowedContentTypes = [format == .png ? .png : format == .jpeg ? .jpeg : .heic]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url,
              let data = ImageEncoder.encode(image, format: format, quality: Preferences.shared.jpegQuality,
                                             scale: capture.scale) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func resetZoom() {
        setZoom(1, anchor: CGPoint(x: content.midX, y: content.midY))
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        window?.alphaValue = CGFloat(sender.tag) / 100
        showIndicator("透明度 \(sender.tag)%")
    }

    @objc private func closePin() {
        window?.close()
    }

    #if DEBUG
    /// 自测：模拟按住某个边 / 角拖动 delta（点）
    func debugResize(_ handle: RegionSelector.Handle, by delta: CGSize) {
        guard let window else { return }
        resize(Resize(handle: handle, start: .zero, frame: window.frame, zoom: zoom), by: delta)
    }
    var debugScrollOffset: CGFloat { scrollOffset }
    var debugZoom: CGFloat { zoom }
    var debugIsLong: Bool { longAxis != nil }
    #endif

    // MARK: - 提示（缩放比例 / 透明度）

    private func showIndicator(_ text: String) {
        indicator.setText(NSAttributedString(string: text, attributes: [
            .font: roundedFont(ofSize: 12, weight: .semibold),
            .foregroundColor: indicator.ink,
        ]))
        indicator.isHidden = false
        placeIndicator()
        indicatorTimer?.invalidate()
        indicatorTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.indicator.isHidden = true }
        }
    }

    private func placeIndicator() {
        let size = indicator.frame.size
        indicator.setFrameOrigin(CGPoint(x: (content.midX - size.width / 2).rounded(),
                                         y: (content.midY - size.height / 2).rounded()))
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
