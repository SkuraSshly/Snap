import AppKit

/// 标注工具栏（温暖磨砂风格，见 WarmStyle）：
/// 第一行：10 个标注工具 | 撤销 重做 | 钉图 保存 | 取消 [✓ 完成]
/// 第二行（选了工具后出现）：6 种颜色 + 3 档粗细 / 字号 / 强度
final class AnnotationToolbar: NSView {
    enum Action {
        case undo, redo, pin, save, cancel, done
    }

    var onSelectTool: ((AnnotationTool?) -> Void)?
    var onSelectColor: ((NSColor) -> Void)?
    var onSelectSize: ((SizeLevel) -> Void)?
    var onAction: ((Action) -> Void)?

    private let mainBar: FrostedPanel
    private let propertyBar: FrostedPanel
    private var toolButtons: [AnnotationTool: ToolbarButton] = [:]
    private var actionButtons: [Action: ToolbarButton] = [:]
    private let doneButton = PillButton(title: "完成", symbol: "checkmark", color: WarmPalette.apricot, help: "完成（Enter）")
    private var colorButtons: [SwatchButton] = []
    private var sizeButtons: [SizeButton] = []
    private let propertySeparator = WarmSeparator()

    private static let buttonSize: CGFloat = 32
    private static let spacing: CGFloat = 2
    private static let padding: CGFloat = 5
    private static let gap: CGFloat = 8

    /// 主栏的高度（定位时用）
    static var mainBarHeight: CGFloat { buttonSize + padding * 2 }

    /// - Parameter blending: 截图界面 .withinWindow（虚化冻结画面）；编辑窗口同样
    init(blending: NSVisualEffectView.BlendingMode = .withinWindow) {
        mainBar = FrostedPanel(blending: blending)
        propertyBar = FrostedPanel(blending: blending)
        super.init(frame: .zero)
        addSubview(mainBar)
        addSubview(propertyBar)
        buildMainBar()
        buildPropertyBar()
        update(tool: nil, style: AnnotationStyle(), canUndo: false, canRedo: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 两行之间的空隙不拦截鼠标（让下面的遮罩照常接收）
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    // MARK: - 构建

    private func buildMainBar() {
        var x = Self.padding + 2
        func add(_ view: NSView, width: CGFloat) {
            view.frame = CGRect(x: x, y: Self.padding, width: width, height: Self.buttonSize)
            mainBar.addSubview(view)
            x += width + Self.spacing
        }
        func separator() {
            let line = WarmSeparator(frame: CGRect(x: x + 5, y: Self.padding + 8, width: 1.5, height: Self.buttonSize - 16))
            mainBar.addSubview(line)
            x += 13
        }

        for tool in AnnotationTool.allCases {
            let button = ToolbarButton(symbol: tool.symbol, help: tool.title)
            button.action = { [weak self] in
                guard let self else { return }
                // 再点一次当前工具：取消选择（回到调整选区）
                self.onSelectTool?(button.isSelected ? nil : tool)
            }
            toolButtons[tool] = button
            add(button, width: Self.buttonSize)
        }
        separator()
        addAction(.undo, symbol: "arrow.uturn.backward", help: "撤销（⌘Z）", add: add)
        addAction(.redo, symbol: "arrow.uturn.forward", help: "重做（⌘⇧Z）", add: add)
        separator()
        addAction(.pin, symbol: "pin", help: "钉在屏幕上", add: add)
        addAction(.save, symbol: "square.and.arrow.down", help: "保存到文件（⌘S）", add: add)
        separator()
        addAction(.cancel, symbol: "xmark", help: "取消（Esc）", add: add)
        doneButton.action = { [weak self] in self?.onAction?(.done) }
        add(doneButton, width: doneButton.fittingWidth)

        mainBar.frame = CGRect(x: 0, y: 0, width: x - Self.spacing + Self.padding + 2, height: Self.mainBarHeight)
    }

    private func addAction(_ action: Action, symbol: String, help: String, add: (NSView, CGFloat) -> Void) {
        let button = ToolbarButton(symbol: symbol, help: help)
        button.action = { [weak self] in self?.onAction?(action) }
        actionButtons[action] = button
        add(button, Self.buttonSize)
    }

    private func buildPropertyBar() {
        for color in AnnotationPalette.colors {
            let swatch = SwatchButton(color: color)
            swatch.action = { [weak self] in self?.onSelectColor?(color) }
            propertyBar.addSubview(swatch)
            colorButtons.append(swatch)
        }
        propertyBar.addSubview(propertySeparator)
        for level in SizeLevel.allCases {
            let button = SizeButton(level: level)
            button.action = { [weak self] in self?.onSelectSize?(level) }
            propertyBar.addSubview(button)
            sizeButtons.append(button)
        }
    }

    // MARK: - 状态

    /// 刷新选中状态；选了工具时显示第二行（马赛克 / 模糊只显示强度）
    func update(tool: AnnotationTool?, style: AnnotationStyle, canUndo: Bool, canRedo: Bool) {
        for (t, button) in toolButtons { button.isSelected = t == tool }
        actionButtons[.undo]?.isEnabled = canUndo
        actionButtons[.redo]?.isEnabled = canRedo

        // 第二行布局：颜色（需要时）| 粗细
        let showColors = tool?.usesColor ?? false
        var x = Self.padding + 4
        for swatch in colorButtons {
            swatch.isHidden = !showColors
            swatch.isSelected = swatch.color == style.color
            if showColors {
                swatch.frame = CGRect(x: x, y: Self.padding, width: 28, height: Self.buttonSize)
                x += 28 + Self.spacing
            }
        }
        propertySeparator.isHidden = !showColors
        if showColors {
            propertySeparator.frame = CGRect(x: x + 4, y: Self.padding + 8, width: 1.5, height: Self.buttonSize - 16)
            x += 13
        }
        for button in sizeButtons {
            button.isSelected = button.level == style.size
            button.symbolMode = tool == .text ? .text : .dot
            button.frame = CGRect(x: x, y: Self.padding, width: Self.buttonSize, height: Self.buttonSize)
            x += Self.buttonSize + Self.spacing
        }
        propertyBar.frame.size = CGSize(width: x - Self.spacing + Self.padding + 4, height: Self.mainBarHeight)
        propertyBar.isHidden = tool == nil
        layoutBars()
    }

    /// 两行右对齐：主栏在上，属性栏在下
    private func layoutBars() {
        let width = max(mainBar.frame.width, propertyBar.isHidden ? 0 : propertyBar.frame.width)
        let propertyHeight = propertyBar.isHidden ? 0 : propertyBar.frame.height + Self.gap
        let height = mainBar.frame.height + propertyHeight
        setFrameSize(CGSize(width: width, height: height))
        mainBar.setFrameOrigin(CGPoint(x: width - mainBar.frame.width, y: height - mainBar.frame.height))
        propertyBar.setFrameOrigin(CGPoint(x: width - propertyBar.frame.width, y: 0))
    }
}

// MARK: - 属性栏按钮

/// 颜色圆点：白色描边的小圆，选中时外面多一圈杏色
final class SwatchButton: WarmControl {
    let color: NSColor
    var isSelected = false { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        toolTip = "颜色"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = isHovered && !isSelected ? 19 : 18
        let circle = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        if isSelected {
            WarmPalette.apricot.setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -3.5, dy: -3.5))
            ring.lineWidth = 2
            ring.stroke()
        }
        // 柔和的小投影，让圆点「浮」在磨砂底上
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.3, green: 0.18, blue: 0.1, alpha: 0.25)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.set()
        color.setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let edge = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
        edge.lineWidth = 1.5
        edge.stroke()
    }
}

/// 粗细 / 字号按钮：圆点大小或字母大小表示三档，选中时杏色圆底
final class SizeButton: WarmControl {
    enum SymbolMode { case dot, text }
    let level: SizeLevel
    var isSelected = false { didSet { needsDisplay = true } }
    var symbolMode: SymbolMode = .dot { didSet { needsDisplay = true } }

    init(level: SizeLevel) {
        self.level = level
        super.init(frame: .zero)
        toolTip = ["细 / 小", "中", "粗 / 大"][level.rawValue]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let palette = self.palette
        let circle = bounds.insetBy(dx: 1, dy: 1)
        if isSelected {
            WarmPalette.apricot.setFill()
            NSBezierPath(ovalIn: circle).fill()
        } else if isHovered {
            palette.hover.setFill()
            NSBezierPath(ovalIn: circle).fill()
        }
        let ink = isSelected ? NSColor.white : palette.ink
        switch symbolMode {
        case .dot:
            let diameter: CGFloat = [5, 9, 13][level.rawValue]
            ink.setFill()
            NSBezierPath(ovalIn: CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                                        width: diameter, height: diameter)).fill()
        case .text:
            let attributed = NSAttributedString(string: "A", attributes: [
                .font: roundedFont(ofSize: [11, 14, 18][level.rawValue], weight: .bold),
                .foregroundColor: ink,
            ])
            let size = attributed.size()
            attributed.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }
    }
}
