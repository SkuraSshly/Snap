import AppKit

/// 遮罩窗口的内容：冻结的底图 + 暗色蒙版 + 区域边框 + 控制点 + 尺寸标签。
/// 全部用 Core Animation 图层绘制，状态变化时关闭隐式动画，切换模式即时生效。
final class OverlayView: NSView {
    weak var handler: OverlayEventHandler?

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let sizeLabel: PillLabel
    private var sizeLabelText = ""
    /// 放在尺寸标签右边的小控件（截图界面的圆角拉条）；随尺寸标签一起摆放、显示、隐藏
    var accessory: NSView? {
        didSet {
            if oldValue !== accessory { oldValue?.removeFromSuperview() }
            if let accessory, accessory.superview !== self { addSubview(accessory) }
            placeAccessory()
        }
    }
    private var trackingArea: NSTrackingArea?

    /// 控制点直径（点）
    private static let handleDiameter: CGFloat = 8

    /// - Parameters:
    ///   - image: 冻结的整屏底图（原生像素）；录屏时为 nil，遮罩透明，下面是实时画面
    ///   - scale: 每点像素数，需与这块屏幕的 backingScaleFactor 一致
    init(frame: NSRect, image: CGImage?, scale: CGFloat, accent: NSColor) {
        // 截图界面虚化冻结的画面；录屏界面（没有底图）虚化后面实时的屏幕
        sizeLabel = PillLabel(padding: NSSize(width: 9, height: 3), blending: image == nil ? .behindWindow : .withinWindow)
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        if image == nil {
            // 录屏选区下面是实时画面：铺一层肉眼不可见的底色（alpha 约 1/255），
            // 否则完全透明的地方鼠标会穿透到下面的窗口，选区内部无法拖动
            root.backgroundColor = NSColor(white: 0, alpha: 0.004).cgColor
        }

        // 底图：图层尺寸（点）× contentsScale 正好等于图像像素，一个像素对一个像素显示，不做任何插值
        imageLayer.frame = bounds
        imageLayer.contents = image
        imageLayer.contentsScale = scale
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        root.addSublayer(imageLayer)

        // 蒙版：奇偶填充规则，在区域处挖出一个洞
        dimLayer.frame = bounds
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        root.addSublayer(dimLayer)

        borderLayer.frame = bounds
        borderLayer.fillColor = nil
        borderLayer.strokeColor = accent.cgColor
        borderLayer.contentsScale = scale
        root.addSublayer(borderLayer)

        // 控制点：白色圆点 + 主题色描边
        handlesLayer.frame = bounds
        handlesLayer.fillColor = NSColor.white.cgColor
        handlesLayer.strokeColor = accent.cgColor
        handlesLayer.lineWidth = 1.5
        handlesLayer.contentsScale = scale
        root.addSublayer(handlesLayer)

        sizeLabel.isHidden = true
        addSubview(sizeLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 标注图层放在底图之上、蒙版之下：选区外的标注会和底图一起被压暗
    func installAnnotationLayer(_ annotationLayer: CALayer) {
        guard annotationLayer.superlayer !== layer else { return }
        annotationLayer.removeFromSuperlayer()
        annotationLayer.frame = bounds
        layer?.insertSublayer(annotationLayer, above: imageLayer)
    }

    // MARK: - 状态

    func apply(_ state: OverlayState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch state.mode {
        case .fullscreen:
            sizeLabel.isHidden = true
            handlesLayer.path = nil
            if state.isActiveScreen {
                // 整块屏幕高亮：不加蒙版，沿屏幕内侧画一圈粗边框
                dimLayer.path = nil
                borderLayer.lineWidth = 4
                borderLayer.path = CGPath(rect: bounds.insetBy(dx: 2, dy: 2), transform: nil)
            } else {
                dimLayer.path = CGPath(rect: bounds, transform: nil)
                borderLayer.path = nil
            }

        case .region:
            let dim = CGMutablePath()
            dim.addRect(bounds)
            if let region = state.region {
                let radius = state.regionStyle == .selection ? min(state.cornerRadius, region.width / 2, region.height / 2) : 0
                dim.addPath(CGPath(roundedRect: region, cornerWidth: radius, cornerHeight: radius, transform: nil))
                switch state.regionStyle {
                case .selection:
                    // 1 点宽的边框画在选区外侧，不遮挡选中的内容；有圆角时跟着圆角
                    borderLayer.lineWidth = 1
                    let outline = region.insetBy(dx: -0.5, dy: -0.5)
                    borderLayer.path = CGPath(roundedRect: outline, cornerWidth: radius > 0 ? radius + 0.5 : 0,
                                              cornerHeight: radius > 0 ? radius + 0.5 : 0, transform: nil)
                    handlesLayer.path = handlesPath(for: region)
                case .window:
                    // 识别出的窗口：2 点宽的边框画在窗口内侧，不会被屏幕边缘裁掉
                    borderLayer.lineWidth = 2
                    borderLayer.path = CGPath(rect: region.insetBy(dx: 1, dy: 1), transform: nil)
                    handlesLayer.path = nil
                }
                showSizeLabel(for: region, pixelSize: state.regionPixelSize)
            } else {
                borderLayer.path = nil
                handlesLayer.path = nil
                sizeLabel.isHidden = true
            }
            dimLayer.path = dim
        }
        placeAccessory()
    }

    /// 小控件放在尺寸标签右边、同一行；放不下时换到标签下面一行
    private func placeAccessory() {
        guard let accessory else { return }
        accessory.isHidden = sizeLabel.isHidden
        guard !sizeLabel.isHidden else { return }
        let label = sizeLabel.frame, size = accessory.frame.size
        var origin = CGPoint(x: label.maxX + 6, y: label.midY - size.height / 2)
        if origin.x + size.width > bounds.maxX - 2 { origin = CGPoint(x: label.minX, y: label.minY - 6 - size.height) }
        origin.x = min(max(origin.x, bounds.minX + 2), bounds.maxX - size.width - 2)
        accessory.setFrameOrigin(origin)
    }

    private func handlesPath(for rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let d = Self.handleDiameter
        for handle in RegionSelector.Handle.allCases {
            let center = handle.point(in: rect)
            path.addEllipse(in: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d))
        }
        return path
    }

    /// 尺寸标签：默认在区域左上角外侧，放不下时移到区域内侧
    private func showSizeLabel(for region: CGRect, pixelSize: CGSize?) {
        guard let pixelSize else {
            sizeLabel.isHidden = true
            return
        }
        let text = "\(Int(pixelSize.width.rounded())) × \(Int(pixelSize.height.rounded()))"
        if text != sizeLabelText {
            sizeLabelText = text
            sizeLabel.setText(NSAttributedString(string: text, attributes: [
                .font: roundedFont(ofSize: 12, weight: .semibold, monospacedDigits: true),
                .foregroundColor: sizeLabel.ink,
            ]))
        }
        let size = sizeLabel.frame.size
        var origin = CGPoint(x: region.minX, y: region.maxY + 8)
        if origin.y + size.height > bounds.maxY - 2 {
            origin = CGPoint(x: region.minX + 8, y: region.maxY - size.height - 8)
        }
        origin.x = min(max(origin.x, bounds.minX + 2), bounds.maxX - size.width - 2)
        sizeLabel.setFrameOrigin(origin)
        sizeLabel.isHidden = false
    }

    // MARK: - 鼠标

    /// 点击未成为焦点的遮罩（例如另一块屏幕上的）时，第一下点击也直接生效
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // activeAlways：Velos 还没切到前台时也能收到鼠标移动事件
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func globalPoint(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    /// 指针随位置变化（控制点、选区内外），所以不用固定的 cursor rect，而是每次移动时设置
    private func updateCursor(_ point: NSPoint) {
        handler?.overlayCursor(at: point).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(globalPoint(event))
    }

    override func mouseEntered(with event: NSEvent) {
        let point = globalPoint(event)
        handler?.overlayMouseMoved(to: point)
        updateCursor(point)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = globalPoint(event)
        handler?.overlayMouseMoved(to: point)
        updateCursor(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = globalPoint(event)
        handler?.overlayMouseDown(at: point)
        updateCursor(point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = globalPoint(event)
        handler?.overlayMouseDragged(to: point)
        updateCursor(point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = globalPoint(event)
        handler?.overlayMouseUp(at: point)
        updateCursor(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = globalPoint(event)
        handler?.overlayRightMouseDown(at: point)
        updateCursor(point)
    }
}
