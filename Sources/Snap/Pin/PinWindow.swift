import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

/// 钉在屏幕上的截图：置顶的浮动小窗。
/// - 单击选中（蓝色边框），选中后按 Esc 关闭、⌘C 复制；双击直接关闭
/// - 拖动移动；滚轮 / 触控板双指捏合缩放（以鼠标位置为中心）
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
    private let imageLayer = CALayer()
    private let borderLayer = CAShapeLayer()
    private let indicator = PillLabel(padding: NSSize(width: 10, height: 4))
    private var indicatorTimer: Timer?

    /// 相对原始大小的缩放比例
    private var zoom: CGFloat = 1
    private static let zoomRange: ClosedRange<CGFloat> = 0.1...8
    private static let opacityRange: ClosedRange<CGFloat> = 0.2...1

    init(capture: CapturedImage, image: CGImage) {
        self.capture = capture
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: capture.pointSize))
        wantsLayer = true

        // 原始大小时，图层的点尺寸 × contentsScale 正好等于图像像素，一个像素对一个像素显示
        imageLayer.contents = image
        imageLayer.contentsScale = capture.scale
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear   // 缩小时用三线性过滤，文字不出现锯齿
        imageLayer.magnificationFilter = .linear
        layer?.addSublayer(imageLayer)

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
        borderLayer.path = CGPath(rect: bounds.insetBy(dx: width / 2, dy: width / 2), transform: nil)
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
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
        // 单击：选中这张钉图（之后按 Esc 关闭）；按住拖动：移动窗口（系统负责跟随鼠标，松开时返回）
        window?.makeKey()
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        guard delta != 0, let window else { return }
        if event.modifierFlags.contains(.command) {
            // ⌘ + 滚轮：透明度
            let alpha = (window.alphaValue + delta * 0.005).clamped(to: Self.opacityRange)
            window.alphaValue = alpha
            showIndicator("透明度 \(Int((alpha * 100).rounded()))%")
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
        let clamped = newZoom.clamped(to: Self.zoomRange)
        let base = capture.pointSize
        let newSize = CGSize(width: (base.width * clamped).rounded(), height: (base.height * clamped).rounded())
        guard newSize.width >= 20, newSize.height >= 20 else { return }
        zoom = clamped

        let old = window.frame
        let fx = old.width > 0 ? anchor.x / old.width : 0.5
        let fy = old.height > 0 ? anchor.y / old.height : 0.5
        let origin = CGPoint(x: old.minX + anchor.x - fx * newSize.width,
                             y: old.minY + anchor.y - fy * newSize.height)
        window.setFrame(CGRect(origin: origin, size: newSize), display: true)
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
        setZoom(1, anchor: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        window?.alphaValue = CGFloat(sender.tag) / 100
        showIndicator("透明度 \(sender.tag)%")
    }

    @objc private func closePin() {
        window?.close()
    }

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
        indicator.setFrameOrigin(CGPoint(x: ((bounds.width - size.width) / 2).rounded(),
                                         y: ((bounds.height - size.height) / 2).rounded()))
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
