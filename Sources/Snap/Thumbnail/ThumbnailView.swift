import AppKit

/// 截图 / 录屏完成后屏幕角落的缩略图（参照 CleanShot X）：
/// - 截图：单击在编辑窗口里继续标注；悬停按钮：关闭、钉图、保存（保存后变成「在访达中显示」）
/// - 录屏：单击预览播放；左下角显示时长；悬停按钮：关闭、移到废纸篓、导出 GIF、拷贝文件、在访达中显示
/// - GIF：单击用默认的看图 App 打开；悬停按钮与录屏相同（没有「导出 GIF」）
/// - 拖拽：把文件拖进聊天、邮件、访达等任何 App
final class ThumbnailView: NSView, NSDraggingSource {
    enum Kind: Equatable {
        case screenshot
        case recording(duration: TimeInterval)
        case gif(duration: TimeInterval)
    }

    var onOpen: (() -> Void)?
    var onPin: (() -> Void)?
    var onSave: (() -> Void)?
    var onReveal: (() -> Void)?
    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?
    var onGIF: (() -> Void)?
    var onDragFinished: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    /// 开始拖拽时提供文件
    var fileProvider: (() -> URL?)?

    private let imageLayer = CALayer()
    private let previewImage: CGImage
    private let closeButton = ThumbnailButton(symbol: "xmark", help: "关闭")
    private let pinButton = ThumbnailButton(symbol: "pin.fill", help: "钉在屏幕上")
    private let saveButton = ThumbnailButton(symbol: "square.and.arrow.down", help: "保存到文件")
    private let revealButton = ThumbnailButton(symbol: "folder", help: "在访达中显示")
    private let copyButton = ThumbnailButton(symbol: "doc.on.doc", help: "拷贝文件")
    private let deleteButton = ThumbnailButton(symbol: "trash", help: "移到废纸篓")
    private let gifButton = ThumbnailButton(text: "GIF", help: "导出为 GIF")
    private let durationBadge = PillLabel(padding: NSSize(width: 7, height: 2))
    /// 正中间的状态文字（「正在生成 GIF 42%」等）
    private let statusLabel = PillLabel(padding: NSSize(width: 10, height: 4))
    /// 悬停出现按钮时时长标签会被挡住（缩略图很窄时），这时先把它藏起来
    private var badgeHidesOnHover = false
    let kind: Kind
    private var trackingArea: NSTrackingArea?
    private var mouseDownPoint: CGPoint?
    private var isDragging = false

    init(image: CGImage, size: CGSize, scale: CGFloat, kind: Kind = .screenshot) {
        previewImage = image
        self.kind = kind
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(srgbRed: 1, green: 0.96, blue: 0.92, alpha: 0.7).cgColor   // 奶油色细边
        layer?.backgroundColor = NSColor.black.cgColor

        imageLayer.frame = bounds
        imageLayer.contents = image
        imageLayer.contentsScale = scale
        imageLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(imageLayer)

        closeButton.action = { [weak self] in self?.onClose?() }
        pinButton.action = { [weak self] in self?.onPin?() }
        saveButton.action = { [weak self] in self?.onSave?() }
        revealButton.action = { [weak self] in self?.onReveal?() }
        copyButton.action = { [weak self] in self?.onCopy?() }
        deleteButton.action = { [weak self] in self?.onDelete?() }
        gifButton.action = { [weak self] in self?.onGIF?() }
        let buttons: [ThumbnailButton] = switch kind {
        case .screenshot: [closeButton, pinButton, saveButton, revealButton]
        case .recording: [closeButton, deleteButton, gifButton, copyButton, revealButton]
        case .gif: [closeButton, deleteButton, copyButton, revealButton]
        }
        for button in buttons {
            button.isHidden = true
            addSubview(button)
        }
        let s = ThumbnailButton.size
        let top = size.height - s - 7, right = size.width - s - 7
        closeButton.frame = CGRect(x: 7, y: top, width: s, height: s)
        switch kind {
        case .screenshot:
            pinButton.frame = CGRect(x: right, y: 7, width: s, height: s)
            // 「保存」和「在访达中显示」共用一个位置：保存前是前者，保存后换成后者
            saveButton.frame = CGRect(x: right - s - 6, y: 7, width: s, height: s)
            revealButton.frame = saveButton.frame
            toolTip = "单击编辑 · 拖到其他 App"
        case .recording(let duration), .gif(let duration):
            let isGIF: Bool = if case .gif = kind { true } else { false }
            deleteButton.frame = CGRect(x: right, y: top, width: s, height: s)
            revealButton.frame = CGRect(x: right, y: 7, width: s, height: s)
            copyButton.frame = CGRect(x: right - s - 6, y: 7, width: s, height: s)
            gifButton.frame = CGRect(x: right - (s + 6) * 2, y: 7, width: s, height: s)
            // 左下角常驻时长标签：▶ 00:12（GIF 为「GIF 00:12」）
            let ink = durationBadge.ink
            let font = roundedFont(ofSize: 11, weight: .semibold, monospacedDigits: true)
            let text = NSMutableAttributedString()
            if isGIF {
                text.append(NSAttributedString(string: "GIF", attributes: [.font: roundedFont(ofSize: 10, weight: .heavy), .foregroundColor: ink]))
            } else {
                let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold).applying(.init(paletteColors: [ink]))
                if let play = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let attachment = NSTextAttachment()
                    attachment.image = play
                    attachment.bounds = CGRect(x: 0, y: 0.5, width: play.size.width, height: play.size.height)
                    text.append(NSAttributedString(attachment: attachment))
                }
            }
            text.append(NSAttributedString(string: " " + StatusBarController.format(duration.rounded()), attributes: [
                .font: font, .foregroundColor: ink,
            ]))
            durationBadge.setText(text)
            durationBadge.setFrameOrigin(CGPoint(x: 7, y: 7 + (s - durationBadge.frame.height) / 2))
            addSubview(durationBadge)
            let leftmost = isGIF ? copyButton : gifButton
            badgeHidesOnHover = durationBadge.frame.maxX + 4 > leftmost.frame.minX
            toolTip = isGIF ? "单击打开 · 拖到其他 App" : "单击预览 · 拖到其他 App"
        }
        statusLabel.isHidden = true
        addSubview(statusLabel)
    }

    /// 封面图（导出 GIF 后，GIF 缩略图沿用视频的封面）
    var image: CGImage { previewImage }

    /// 正在处理（导出 GIF）：只保留关闭按钮（关闭 = 取消）
    var isBusy = false {
        didSet { updateButtons() }
    }

    /// 在正中间显示状态文字；nil 隐藏
    func setStatus(_ text: String?) {
        guard let text else {
            statusLabel.isHidden = true
            return
        }
        statusLabel.setText(NSAttributedString(string: text, attributes: [
            .font: roundedFont(ofSize: 12, weight: .semibold, monospacedDigits: true),
            .foregroundColor: statusLabel.ink,
        ]))
        statusLabel.setFrameOrigin(CGPoint(x: ((bounds.width - statusLabel.frame.width) / 2).rounded(),
                                           y: ((bounds.height - statusLabel.frame.height) / 2).rounded()))
        statusLabel.isHidden = false
        statusLabel.layoutSubtreeIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 是否已保存到文件
    var isSaved = false {
        didSet { updateButtons() }
    }

    private var isHovered = false {
        didSet { updateButtons() }
    }

    #if DEBUG
    func debugSetHovered(_ hovered: Bool) { isHovered = hovered }
    var debugDurationText: String { durationBadge.debugText }
    var debugVisibleButtons: [String] {
        [closeButton, pinButton, saveButton, revealButton, copyButton, deleteButton, gifButton]
            .filter { $0.superview != nil && !$0.isHidden }.compactMap(\.toolTip)
    }
    var debugCopySymbol: String { copyButton.symbol }
    var debugStatusText: String? { statusLabel.isHidden ? nil : statusLabel.debugText }
    #endif

    private func updateButtons() {
        closeButton.isHidden = !isHovered
        switch kind {
        case .screenshot:
            pinButton.isHidden = !isHovered
            saveButton.isHidden = !isHovered || isSaved
            revealButton.isHidden = !isHovered || !isSaved
        case .recording, .gif:
            let show = isHovered && !isBusy
            deleteButton.isHidden = !show
            copyButton.isHidden = !show
            revealButton.isHidden = !show
            gifButton.isHidden = !show
            durationBadge.isHidden = show && badgeHidesOnHover
        }
    }

    /// 拷贝后按钮短暂变成对勾
    func showCopied() {
        copyButton.setSymbol("checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.setSymbol("doc.on.doc")
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChanged?(false)
    }

    // MARK: - 单击与拖拽

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, !isBusy, let start = mouseDownPoint else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, let url = fileProvider?() else { return }
        isDragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: NSImage(cgImage: previewImage, size: bounds.size))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        if !isDragging, !isBusy, mouseDownPoint != nil {
            onOpen?()
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        if operation != [] { onDragFinished?() }
    }
}

/// 缩略图上的圆形小按钮（温暖磨砂风格）：奶油色毛玻璃小圆 + 暖棕色图标，悬停时略微加深。
/// 第一下点击就生效，不需要先激活窗口。
final class ThumbnailButton: WarmControl {
    static let size: CGFloat = 26
    private let panel = FrostedPanel(blending: .withinWindow, shadowRadius: 5)
    private let highlight = NSView()
    private let iconView = NSImageView()
    private(set) var symbol: String

    init(symbol: String, help: String) {
        self.symbol = symbol
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        toolTip = help
        panel.frame = bounds
        addSubview(panel)
        highlight.frame = bounds
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = Self.size / 2
        addSubview(highlight)
        iconView.imageScaling = .scaleNone
        iconView.frame = bounds
        addSubview(iconView)
        setSymbol(symbol)
    }

    /// 文字图标（例如「GIF」，没有合适的系统图标时用）
    convenience init(text: String, help: String) {
        self.init(symbol: "", help: help)
        symbol = text
        let attributes: [NSAttributedString.Key: Any] = [.font: roundedFont(ofSize: 9.5, weight: .heavy), .foregroundColor: NSColor.black]
        let size = (text as NSString).size(withAttributes: attributes)
        let image = NSImage(size: size, flipped: false) { _ in
            (text as NSString).draw(at: .zero, withAttributes: attributes)
            return true
        }
        image.isTemplate = true   // 按主题着色，与其他图标颜色一致
        iconView.image = image
    }

    func setSymbol(_ symbol: String) {
        self.symbol = symbol
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?.withSymbolConfiguration(config)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 整个圆都由按钮自己响应（不让里面的磨砂面板吞掉点击）
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : (frame.contains(point) ? self : nil) }

    override func updateAppearance() {
        let palette = self.palette
        highlight.layer?.backgroundColor = (isPressed ? palette.pressed : isHovered ? palette.hover : .clear).cgColor
        iconView.contentTintColor = palette.ink
    }
}
