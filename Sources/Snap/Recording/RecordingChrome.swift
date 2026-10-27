import AppKit

/// 录制中的浮动控制条（温暖磨砂风格）：红点 + 计时 | 暂停 / 继续、麦克风静音、停止。
/// - 默认放在录制区域下方（就是选区阶段选项条的位置），放不下就放上方，全屏录制放在屏幕底部
/// - 可以拖到任何地方
/// - 不会成为焦点窗口：点它不会打断正在使用的 App
/// - 属于 Snap 的窗口，不会被录进视频
@MainActor
final class RecordingControlBar: NSPanel {
    /// 磨砂面板周围留出画投影的空间：要比投影的范围大，否则投影被窗口边缘截断，会看到一圈淡淡的方框
    private static let shadowInset: CGFloat = 40
    private static let height: CGFloat = 44

    private weak var manager: RecordingManager?
    private let bar = FrostedPanel(blending: .behindWindow)
    private let dot = NSView()
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let separator = WarmSeparator()
    private let pauseButton = ToolbarButton(symbol: "pause.fill", help: "暂停")
    private let microphoneButton = ToolbarButton(symbol: "mic.fill", help: "麦克风静音")
    private let stopButton: PillButton
    private var timer: Timer?

    init(manager: RecordingManager) {
        self.manager = manager
        stopButton = PillButton(title: "停止", symbol: "stop.fill", color: WarmPalette.coral,
                                help: "停止录制（\(CaptureCoordinator.shared.recordingHotkey.displayString)）")
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // 投影由磨砂面板自己画
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let root = DragArea()
        contentView = root
        root.addSubview(bar)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        timeLabel.font = roundedFont(ofSize: 14, weight: .semibold, monospacedDigits: true)
        timeLabel.lineBreakMode = .byClipping
        for view in [dot, timeLabel, separator, pauseButton, microphoneButton, stopButton] as [NSView] {
            bar.addSubview(view)
        }
        pauseButton.action = { [weak manager] in manager?.togglePause() }
        microphoneButton.action = { [weak manager] in manager?.toggleMicrophoneMute() }
        stopButton.action = { [weak manager] in Task { await manager?.stop() } }

        refresh()
        // 计时：只在录制期间运行，控制条关闭时停止
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTime() }
        }
    }

    /// 不抢键盘焦点
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }

    // MARK: - 状态

    /// 暂停 / 静音状态变化后刷新按钮
    func refresh() {
        guard let manager else { return }
        let paused = manager.isPaused
        dot.layer?.backgroundColor = (paused ? WarmPalette.apricot : OverlayAccent.recording).cgColor
        pauseButton.setSymbol(paused ? "play.fill" : "pause.fill")
        pauseButton.toolTip = paused ? "继续录制" : "暂停录制"

        microphoneButton.isHidden = !manager.capturesMicrophone && !manager.microphoneUnavailable
        if manager.microphoneUnavailable {
            microphoneButton.setSymbol("mic.slash")
            microphoneButton.isEnabled = false
            microphoneButton.toolTip = "没有麦克风权限，本次没有录制麦克风"
        } else {
            let muted = manager.isMicrophoneMuted
            microphoneButton.setSymbol(muted ? "mic.slash.fill" : "mic.fill")
            microphoneButton.isSelected = muted
            microphoneButton.toolTip = muted ? "麦克风已静音（点按取消静音）" : "麦克风静音"
        }
        refreshTime()
    }

    private func refreshTime() {
        guard let manager else { return }
        let text = StatusBarController.format(manager.elapsed)
        let palette = WarmPalette(for: bar)
        timeLabel.textColor = manager.isPaused ? WarmPalette.apricot : palette.ink
        if timeLabel.stringValue != text {
            let lengthChanged = timeLabel.stringValue.count != text.count
            timeLabel.stringValue = text
            if lengthChanged { relayout() }   // 超过一小时多出「h:」，重新排版
        }
    }

    // MARK: - 布局

    private func relayout() {
        let h = Self.height
        let button: CGFloat = 32
        var x: CGFloat = 16
        dot.frame = CGRect(x: x, y: (h - 8) / 2, width: 8, height: 8)
        x += 8 + 8
        let labelSize = timeLabel.fittingSize
        timeLabel.frame = CGRect(x: x, y: ((h - labelSize.height) / 2).rounded(), width: ceil(labelSize.width), height: labelSize.height)
        x += ceil(labelSize.width) + 10
        separator.frame = CGRect(x: x, y: (h - 20) / 2, width: 1, height: 20)
        x += 1 + 6
        pauseButton.frame = CGRect(x: x, y: (h - button) / 2, width: button, height: button)
        x += button + 2
        if !microphoneButton.isHidden {
            microphoneButton.frame = CGRect(x: x, y: (h - button) / 2, width: button, height: button)
            x += button + 2
        }
        x += 4
        let stopWidth = stopButton.fittingWidth
        stopButton.frame = CGRect(x: x, y: (h - 30) / 2, width: stopWidth, height: 30)
        x += stopWidth + 7

        // 保持左下角位置不变，只改宽度
        let inset = Self.shadowInset
        let origin = frame.origin
        bar.frame = CGRect(x: inset, y: inset, width: x, height: h)
        setFrame(CGRect(x: origin.x, y: origin.y, width: x + inset * 2, height: h + inset * 2), display: true)
    }

    /// 放在录制区域下方居中；下方放不下放上方；全屏录制放在屏幕底部居中
    func place(near region: CGRect, on screen: NSScreen, isFullScreen: Bool) {
        relayout()
        let visible = screen.visibleFrame
        let size = bar.frame.size
        let gap: CGFloat = 12
        var origin: CGPoint
        if !isFullScreen, region.minY - gap - size.height >= visible.minY + 8 {
            origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - gap - size.height)
        } else if !isFullScreen, region.maxY + gap + size.height <= visible.maxY - 8 {
            origin = CGPoint(x: region.midX - size.width / 2, y: region.maxY + gap)
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 28)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - 8 - size.width)
        setFrameOrigin(CGPoint(x: origin.x.rounded() - Self.shadowInset, y: origin.y.rounded() - Self.shadowInset))
    }

    #if DEBUG
    var debugBarFrame: CGRect { bar.frame.offsetBy(dx: frame.minX, dy: frame.minY) }
    var debugTimeText: String { timeLabel.stringValue }
    var debugMicrophoneVisible: Bool { !microphoneButton.isHidden }
    func debugClickPause() { pauseButton.action?() }
    func debugClickMicrophone() { microphoneButton.action?() }
    func debugClickStop() { stopButton.action?() }
    #endif
}

/// 控制条的底板：按钮以外的地方都可以按住拖动整个控制条
private final class DragArea: NSView {
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 点在按钮上交给按钮；其他地方（磨砂底板、计时文字）都由这里接管，用来拖动
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is WarmControl { return hit }
            view = current.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let window else { return }
        let p = NSEvent.mouseLocation
        window.setFrameOrigin(CGPoint(x: dragStart.origin.x + p.x - dragStart.mouse.x,
                                      y: dragStart.origin.y + p.y - dragStart.mouse.y))
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { NSCursor.pop() }
        dragStart = nil
    }
}

// MARK: - 红框

/// 录制区域的边框：录制中是红色实线，暂停时变成杏色虚线。
/// 画在录制区域外侧，不挡住内容；鼠标可以穿透；属于 Snap 的窗口，不会被录进视频。
@MainActor
final class RecordingFrameWindow: NSPanel {
    private let shape = CAShapeLayer()

    var isPaused = false { didSet { updateStyle() } }

    init(region: CGRect, screen: NSScreen, isFullScreen: Bool) {
        // 区域录制：边框画在区域外 1~3pt；全屏录制：沿屏幕边缘画在内侧
        let outset: CGFloat = 3
        let frame = isFullScreen ? screen.frame : region.insetBy(dx: -outset, dy: -outset)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let lineWidth: CGFloat = isFullScreen ? 3 : 2
        shape.frame = view.bounds
        shape.contentsScale = screen.backingScaleFactor
        shape.fillColor = nil
        shape.lineWidth = lineWidth
        shape.lineJoin = .round
        shape.path = CGPath(rect: view.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
        view.layer?.addSublayer(shape)
        contentView = view
        updateStyle()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func updateStyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.strokeColor = (isPaused ? WarmPalette.apricot : OverlayAccent.recording).cgColor
        shape.lineDashPattern = isPaused ? [7, 5] : nil
        CATransaction.commit()
    }

    #if DEBUG
    var debugIsDashed: Bool { shape.lineDashPattern != nil }
    #endif
}
