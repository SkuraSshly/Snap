import AppKit

/// 标注工具栏（温暖磨砂风格，见 WarmStyle）：
/// 第一行：10 个标注工具 | 撤销 重做 | 钉图 保存 | 取消 [✓ 完成]
/// 第二行（选了工具或选中了标注时出现）：6 种颜色 + 任意颜色 | 3 档粗细 / 字号 / 强度 | 不透明度
final class AnnotationToolbar: NSView {
    enum Action {
        case undo, redo, pin, save, longCapture, cancel, done
    }

    var onSelectTool: ((AnnotationTool?) -> Void)?
    var onSelectColor: ((NSColor) -> Void)?
    /// 拖大小拉条（点，含义按工具不同）
    var onSelectSize: ((CGFloat) -> Void)?
    /// 点「实心 / 文字背景」开关
    var onToggleFill: (() -> Void)?
    /// 拖不透明度滑块（0.1 ~ 1）
    var onSelectOpacity: ((CGFloat) -> Void)?
    /// 调色盘里选了颜色；opacity 不为 nil 表示颜色代码里带了不透明度（#RRGGBBAA、rgba）
    var onPickColor: ((NSColor, CGFloat?) -> Void)?
    var onAction: ((Action) -> Void)?

    private let mainBar: FrostedPanel
    private let propertyBar: FrostedPanel
    private var toolButtons: [AnnotationTool: ToolbarButton] = [:]
    private var actionButtons: [Action: ToolbarButton] = [:]
    private let doneButton = PillButton(title: "完成", symbol: "checkmark", color: WarmPalette.apricot, help: "完成（Enter）")
    private var colorButtons: [SwatchButton] = []
    private let sizeSlider = SizeSlider()
    private let fillButton = ToolbarButton(symbol: "rectangle.fill", help: "实心")
    private let propertySeparator = WarmSeparator()
    private let customColorButton = CustomColorButton()
    private let opacitySeparator = WarmSeparator()
    private let opacitySlider = OpacitySlider()
    private let blending: NSVisualEffectView.BlendingMode
    /// 截图界面有「长截图」按钮；重新编辑窗口没有
    private let showsLongCapture: Bool
    private var currentColor: NSColor = AnnotationPalette.colors[0]
    private(set) var colorPicker: ColorPickerView?

    private static let buttonSize: CGFloat = 32
    private static let spacing: CGFloat = 2
    private static let padding: CGFloat = 5
    private static let gap: CGFloat = 8

    #if DEBUG
    /// 自测：长截图按钮是否可用；没有这个按钮时为 nil
    var debugLongCaptureEnabled: Bool? { actionButtons[.longCapture]?.isEnabled }
    #endif

    /// 主栏的高度（定位时用）
    static var mainBarHeight: CGFloat { buttonSize + padding * 2 }

    /// - Parameters:
    ///   - blending: 截图界面 .withinWindow（虚化冻结画面）；编辑窗口同样
    ///   - showsLongCapture: 显示「长截图」按钮（只在截图界面）
    init(blending: NSVisualEffectView.BlendingMode = .withinWindow, showsLongCapture: Bool = false) {
        mainBar = FrostedPanel(blending: blending)
        propertyBar = FrostedPanel(blending: blending)
        self.blending = blending
        self.showsLongCapture = showsLongCapture
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
            // 弱引用 button：按钮持有这个闭包，闭包再强引用按钮就成了循环引用，
            // 每次截图后工具栏的按钮（连同图标、图层）都释放不掉，用得越多内存越高
            button.action = { [weak self, weak button] in
                guard let self, let button else { return }
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
        // 长截图放在钉图、下载的左边
        if showsLongCapture {
            addAction(.longCapture, symbol: "scissors", help: "长截图：滚动页面，截取超出屏幕的内容", add: add)
            actionButtons[.longCapture]?.setImage(VelosIcons.longCapture)
        }
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
        customColorButton.action = { [weak self] in self?.toggleColorPicker() }
        propertyBar.addSubview(customColorButton)
        propertyBar.addSubview(propertySeparator)
        sizeSlider.onChange = { [weak self] value in self?.onSelectSize?(value) }
        propertyBar.addSubview(sizeSlider)
        fillButton.action = { [weak self] in self?.onToggleFill?() }
        propertyBar.addSubview(fillButton)
        propertyBar.addSubview(opacitySeparator)
        opacitySlider.onChange = { [weak self] value in self?.onSelectOpacity?(value) }
        propertyBar.addSubview(opacitySlider)
    }

    // MARK: - 调色盘

    var isShowingColorPicker: Bool { colorPicker?.isOpen == true }

    /// 关闭调色盘；原来开着的返回 true（Esc 先关调色盘）
    @discardableResult
    func closeColorPicker() -> Bool {
        guard let colorPicker, colorPicker.isOpen else { return false }
        colorPicker.close()
        return true
    }

    private func toggleColorPicker() {
        if closeColorPicker() { return }
        guard let host = superview else { return }
        // 横向对准任意颜色按钮，纵向避开整个工具栏（放在工具栏上方，放不下放下方），不挡住主栏
        let button = host.convert(customColorButton.frame, from: propertyBar)
        let anchor = CGRect(x: button.minX, y: frame.minY, width: button.width, height: frame.height)
        let picker = ColorPickerView.show(in: host, anchor: anchor, color: currentColor, blending: blending)
        picker.onChange = { [weak self] color, opacity in self?.onPickColor?(color, opacity) }
        picker.onClose = { [weak self, weak picker] in
            picker?.window?.makeFirstResponder(nil)
            if self?.colorPicker === picker { self?.colorPicker = nil }
        }
        colorPicker = picker
    }

    /// 工具栏移走（截图结束、换屏幕）时调色盘一起关掉
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview !== superview { closeColorPicker() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    // MARK: - 状态

    /// 刷新选中状态；选了工具时显示第二行（马赛克 / 模糊只显示强度）。
    /// - Parameter selectionTool: 没选工具但选中了标注时，按这个标注的种类显示第二行
    /// - Parameter canLongCapture: 长截图按钮是否可用（已经画了标注时不可用）
    func update(tool: AnnotationTool?, style: AnnotationStyle, canUndo: Bool, canRedo: Bool,
                selectionTool: AnnotationTool? = nil, canLongCapture: Bool = true) {
        for (t, button) in toolButtons { button.isSelected = t == tool }
        if let longCapture = actionButtons[.longCapture] {
            longCapture.isEnabled = canLongCapture
            longCapture.toolTip = canLongCapture ? "长截图：滚动页面，截取超出屏幕的内容"
                                                 : "长截图要在画标注之前开始"
        }
        actionButtons[.undo]?.isEnabled = canUndo
        actionButtons[.redo]?.isEnabled = canRedo
        currentColor = style.color
        let propertyTool = tool ?? selectionTool

        // 第二行布局：颜色 + 任意颜色（需要时）| 粗细 | 不透明度（需要时）
        // 马赛克 / 模糊没有颜色，也不能调不透明度（变淡会露出被遮住的内容）
        let showColors = propertyTool?.usesColor ?? false
        var x = Self.padding + 4
        for swatch in colorButtons {
            swatch.isHidden = !showColors
            swatch.isSelected = swatch.color.isSameColor(as: style.color)
            if showColors {
                swatch.frame = CGRect(x: x, y: Self.padding, width: 28, height: Self.buttonSize)
                x += 28 + Self.spacing
            }
        }
        customColorButton.isHidden = !showColors
        customColorButton.customColor = colorButtons.contains { $0.isSelected } ? nil : style.color
        if showColors {
            customColorButton.frame = CGRect(x: x, y: Self.padding, width: 28, height: Self.buttonSize)
            x += 28 + Self.spacing
        } else {
            closeColorPicker()
        }
        propertySeparator.isHidden = !showColors
        if showColors {
            propertySeparator.frame = CGRect(x: x + 4, y: Self.padding + 8, width: 1.5, height: Self.buttonSize - 16)
            x += 13
        }
        if let propertyTool {
            sizeSlider.configure(title: propertyTool.sizeTitle, range: propertyTool.sizeRange)
            sizeSlider.value = style.size
        }
        sizeSlider.frame = CGRect(x: x, y: Self.padding, width: SizeSlider.width, height: Self.buttonSize)
        x += SizeSlider.width + Self.spacing
        // 矩形、椭圆：实心开关；文字：底色开关
        let showsFill = propertyTool?.supportsFill ?? false
        fillButton.isHidden = !showsFill
        if let propertyTool, showsFill {
            fillButton.setSymbol(propertyTool == .ellipse ? "circle.fill" : propertyTool == .text ? "a.square.fill" : "rectangle.fill")
            fillButton.toolTip = propertyTool.fillTitle
            fillButton.isSelected = style.filled
            fillButton.frame = CGRect(x: x, y: Self.padding, width: Self.buttonSize, height: Self.buttonSize)
            x += Self.buttonSize + Self.spacing
        }
        opacitySeparator.isHidden = !showColors
        opacitySlider.isHidden = !showColors
        if showColors {
            opacitySeparator.frame = CGRect(x: x + 4, y: Self.padding + 8, width: 1.5, height: Self.buttonSize - 16)
            x += 13
            opacitySlider.value = style.opacity
            opacitySlider.frame = CGRect(x: x, y: Self.padding, width: OpacitySlider.width, height: Self.buttonSize)
            x += OpacitySlider.width + Self.spacing
        }
        propertyBar.frame.size = CGSize(width: x - Self.spacing + Self.padding + 4, height: Self.mainBarHeight)
        propertyBar.isHidden = propertyTool == nil
        layoutBars()
    }

    #if DEBUG
    func debugToggleColorPicker() { toggleColorPicker() }
    var debugOpacitySlider: OpacitySlider { opacitySlider }
    var debugSizeSlider: SizeSlider { sizeSlider }
    var debugFillButton: ToolbarButton { fillButton }
    var debugCustomColorButton: CustomColorButton { customColorButton }
    var debugPropertyBarVisible: Bool { !propertyBar.isHidden }
    var debugShowsOpacity: Bool { !opacitySlider.isHidden }
    #endif

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

extension NSColor {
    /// 按 sRGB 的 8 位分量比较（调色盘、颜色代码得到的颜色与预设颜色比较时用）
    func isSameColor(as other: NSColor) -> Bool { ColorCode.hex(self) == ColorCode.hex(other) }
}

/// 任意颜色按钮：彩虹色的圆环；当前颜色不是预设颜色时，圆环中间显示这个颜色并标为选中
final class CustomColorButton: WarmControl {
    var customColor: NSColor? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "任意颜色：调色盘，或输入 / 粘贴颜色代码"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateAppearance() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = isHovered && customColor == nil ? 19 : 18
        let circle = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        if customColor != nil {
            WarmPalette.apricot.setStroke()
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -3.5, dy: -3.5))
            ring.lineWidth = 2
            ring.stroke()
        }
        // 彩虹圆环：分段画 36 段圆弧
        let center = CGPoint(x: circle.midX, y: circle.midY)
        let radius = diameter / 2 - 2.25
        for i in 0..<36 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: CGFloat(i) * 10 + 90, endAngle: CGFloat(i + 1) * 10 + 90.6)
            arc.lineWidth = 4.5
            NSColor(hue: CGFloat(i) / 36, saturation: 0.85, brightness: 1, alpha: 1).setStroke()
            arc.stroke()
        }
        let inner = circle.insetBy(dx: 4.5, dy: 4.5)
        (customColor ?? NSColor.white).setFill()
        NSBezierPath(ovalIn: inner).fill()
        if customColor == nil {
            // 中间一个小加号
            let plus = NSBezierPath()
            plus.move(to: CGPoint(x: center.x - 2.5, y: center.y))
            plus.line(to: CGPoint(x: center.x + 2.5, y: center.y))
            plus.move(to: CGPoint(x: center.x, y: center.y - 2.5))
            plus.line(to: CGPoint(x: center.x, y: center.y + 2.5))
            plus.lineWidth = 1.5
            plus.lineCapStyle = .round
            NSColor(white: 0.35, alpha: 1).setStroke()
            plus.stroke()
        }
    }
}

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

