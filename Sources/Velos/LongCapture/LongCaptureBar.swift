import AppKit

// MARK: - 控制条

/// [竖向 | 横向] | 长度 | [取消] [编辑] [钉图] [保存] [完成]
@MainActor
final class LongCaptureBar: NSPanel {
    var onAxis: ((ScrollAxis) -> Void)?
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onDone: (() -> Void)?
    var onEdit: (() -> Void)?
    var onPin: (() -> Void)?

    private let bar = FrostedPanel(blending: .behindWindow)
    private let direction = SegmentedPill(titles: ["竖向", "横向"], help: "滚动方向")
    private let lengthLabel = NSTextField(labelWithString: "")
    private let cancelButton = ToolbarButton(symbol: "xmark", help: "取消长截图（Esc）")
    private let editButton = ToolbarButton(symbol: "square.and.pencil", help: "编辑：结束长截图，打开编辑窗口继续标注")
    private let pinButton = ToolbarButton(symbol: "pin", help: "钉在屏幕上：结束长截图，把整张长图钉在屏幕上")
    private let saveButton = ToolbarButton(symbol: "square.and.arrow.down", help: "完成并保存到文件")
    private let doneButton = PillButton(title: "完成", symbol: "checkmark", color: WarmPalette.apricot,
                                        help: "完成：复制到剪贴板、显示缩略图")
    private static let height: CGFloat = 42
    private static let inset: CGFloat = 40   // 给投影留出空间

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let root = NSView()
        contentView = root
        root.addSubview(bar)
        lengthLabel.font = roundedFont(ofSize: 12, weight: .medium, monospacedDigits: true)
        lengthLabel.textColor = WarmPalette(for: bar).ink
        direction.onSelect = { [weak self] index in self?.onAxis?(index == 0 ? .vertical : .horizontal) }
        cancelButton.action = { [weak self] in self?.onCancel?() }
        editButton.action = { [weak self] in self?.onEdit?() }
        pinButton.action = { [weak self] in self?.onPin?() }
        saveButton.action = { [weak self] in self?.onSave?() }
        doneButton.action = { [weak self] in self?.onDone?() }
        for view in [direction, lengthLabel, cancelButton, editButton, pinButton, saveButton, doneButton] as [NSView] { bar.addSubview(view) }
        setLength(0, axis: .vertical, scale: 1)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 显示拼好的长度：「已拼接 2400 像素」
    func setLength(_ pixels: Int, axis: ScrollAxis, scale: CGFloat) {
        lengthLabel.stringValue = pixels == 0 ? "等待滚动…" : "已拼接 \(pixels) 像素"
        direction.selectedIndex = axis == .vertical ? 0 : 1
        relayout()
    }

    /// 正在生成结果：按钮不能再点
    func setBusy() {
        for control in [direction, cancelButton, editButton, pinButton, saveButton, doneButton] as [WarmControl] { control.isEnabled = false }
        lengthLabel.stringValue = "正在生成…"
        relayout()
    }

    private func relayout() {
        let h = Self.height, button: CGFloat = 32, y = (h - button) / 2
        var x: CGFloat = 6
        func place(_ view: NSView, _ width: CGFloat) {
            view.frame = CGRect(x: x, y: y, width: width, height: button)
            x += width + 4
        }
        place(direction, 92)
        x += 6
        let labelSize = lengthLabel.fittingSize
        lengthLabel.frame = CGRect(x: x, y: ((h - labelSize.height) / 2).rounded(), width: max(ceil(labelSize.width), 118),
                                   height: labelSize.height)
        x += max(ceil(labelSize.width), 118) + 8
        place(cancelButton, button)
        place(editButton, button)
        place(pinButton, button)
        place(saveButton, button)
        place(doneButton, doneButton.fittingWidth)
        let width = x + 2
        let inset = Self.inset
        bar.frame = CGRect(x: inset, y: inset, width: width, height: h)
        let origin = frame.origin
        setFrame(CGRect(x: origin.x, y: origin.y, width: width + inset * 2, height: h + inset * 2), display: true)
    }

    /// 控制条本身（不含给投影留的边距）在屏幕上的位置和大小
    var barFrame: CGRect { frame.insetBy(dx: Self.inset, dy: Self.inset) }

    /// 把控制条本身的左下角放到 origin
    func place(at origin: CGPoint) {
        setFrameOrigin(CGPoint(x: origin.x - Self.inset, y: origin.y - Self.inset))
    }

    #if DEBUG
    func debugTapEdit() { onEdit?() }
    func debugTapPin() { onPin?() }
    var debugLengthText: String { lengthLabel.stringValue }
    #endif
}
