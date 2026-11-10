import AppKit

// MARK: - 颜色代码

/// 颜色代码的解析与格式化
enum ColorCode {
    /// sRGB 颜色 → #RRGGBB（与截图界面按 C 复制的格式一致）
    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    /// 解析颜色代码，支持 #RRGGBB、RRGGBB、#RGB、#RRGGBBAA（最后两位是不透明度）、0xRRGGBB、rgb(255, 87, 51)、rgba(255, 87, 51, 0.5)
    /// - Returns: 不透明的颜色，以及代码里带的不透明度（没有则为 nil）
    static func parse(_ text: String) -> (color: NSColor, opacity: CGFloat?)? {
        var code = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // rgb(…) / rgba(…)
        if code.hasPrefix("rgb") {
            guard let open = code.firstIndex(of: "("), let close = code.lastIndex(of: ")"), open < close else { return nil }
            let parts = code[code.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 || parts.count == 4,
                  let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]),
                  [r, g, b].allSatisfy({ (0...255).contains($0) }) else { return nil }
            var opacity: CGFloat?
            if parts.count == 4 {
                guard let a = Double(parts[3]), (0...1).contains(a) else { return nil }
                opacity = CGFloat(a)
            }
            return (NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1), opacity)
        }
        if code.hasPrefix("#") { code.removeFirst() } else if code.hasPrefix("0x") { code.removeFirst(2) }
        guard code.allSatisfy(\.isHexDigit) else { return nil }
        if code.count == 3 { code = code.map { "\($0)\($0)" }.joined() }   // #F53 → #FF5533
        guard code.count == 6 || code.count == 8, let value = UInt64(code, radix: 16) else { return nil }
        let rgb = code.count == 8 ? value >> 8 : value
        let color = NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        let opacity: CGFloat? = code.count == 8 ? CGFloat(value & 0xFF) / 255 : nil
        return (color, opacity)
    }
}

// MARK: - 调色盘

/// 任意颜色的调色盘（温暖磨砂风格）：饱和度 / 亮度方块 + 色相条 + 颜色代码输入框；
/// 剪贴板里有颜色代码（例如截图界面按 C 复制的）时，多一个「使用剪贴板颜色」按钮。
/// 改动实时生效；点调色盘外面、按 Enter 或 Esc 关闭。
final class ColorPickerView: NSView, NSTextFieldDelegate {
    /// 选了颜色（不透明）；opacity 不为 nil 表示颜色代码里带了不透明度
    var onChange: ((NSColor, CGFloat?) -> Void)?
    var onClose: (() -> Void)?

    private let panel: FrostedPanel
    private let catcher = DismissCatcher()
    private let square = SaturationBrightnessView()
    private let hueBar = HueBar()
    private let preview = NSView()
    private let field = HexField()
    private var clipboardButton: PillButton?
    private var hue: CGFloat = 0, saturation: CGFloat = 1, brightness: CGFloat = 1

    private static let width: CGFloat = 228
    private static let inset: CGFloat = 12

    /// 在 superview 里弹出，位置在 anchor（触发按钮）上方，放不下就放下方
    @discardableResult
    static func show(in superview: NSView, anchor: CGRect, color: NSColor,
                     blending: NSVisualEffectView.BlendingMode) -> ColorPickerView {
        let picker = ColorPickerView(color: color, blending: blending)
        picker.catcher.frame = superview.bounds
        picker.catcher.onDismiss = { [weak picker] in picker?.close() }
        superview.addSubview(picker.catcher)
        superview.addSubview(picker)
        let size = picker.frame.size
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 8)
        if origin.y + size.height > superview.bounds.maxY - 4 { origin.y = anchor.minY - 8 - size.height }
        origin.x = min(max(origin.x, 4), superview.bounds.maxX - size.width - 4)
        picker.setFrameOrigin(CGPoint(x: origin.x.rounded(), y: origin.y.rounded()))
        return picker
    }

    private init(color: NSColor, blending: NSVisualEffectView.BlendingMode) {
        panel = FrostedPanel(cornerRadius: 16, blending: blending)
        super.init(frame: .zero)
        let srgb = color.usingColorSpace(.sRGB) ?? color
        hue = srgb.hueComponent
        saturation = srgb.saturationComponent
        brightness = srgb.brightnessComponent

        let w = Self.width, inset = Self.inset, inner = w - inset * 2
        let clipboard = Self.clipboardColor().flatMap { ColorCode.hex($0.color) == ColorCode.hex(srgb) ? nil : $0 }
        let clipboardHeight: CGFloat = clipboard == nil ? 0 : 34
        let height = inset + 132 + 10 + 14 + 12 + 26 + clipboardHeight + inset
        frame = CGRect(x: 0, y: 0, width: w, height: height)
        panel.frame = bounds
        addSubview(panel)

        var y = height - inset - 132
        square.frame = CGRect(x: inset, y: y, width: inner, height: 132)
        square.onChange = { [weak self] s, b in
            self?.saturation = s
            self?.brightness = b
            self?.emit()
        }
        panel.addSubview(square)
        y -= 10 + 14
        hueBar.frame = CGRect(x: inset, y: y, width: inner, height: 14)
        hueBar.onChange = { [weak self] h in
            self?.hue = h
            self?.emit()
        }
        panel.addSubview(hueBar)
        y -= 12 + 26
        preview.frame = CGRect(x: inset, y: y, width: 26, height: 26)
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 13
        preview.layer?.borderWidth = 1.5
        preview.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        panel.addSubview(preview)
        field.frame = CGRect(x: inset + 34, y: y + 1, width: inner - 34, height: 24)
        field.delegate = self
        field.placeholderString = "#FF5733"
        field.font = roundedFont(ofSize: 13, weight: .semibold, monospacedDigits: true)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.toolTip = "输入或粘贴颜色代码，例如 #FF5733、#F53、rgb(255, 87, 51)；按 Enter 确定"
        panel.addSubview(field)
        if let clipboard {
            y -= 8 + 26
            let button = PillButton(title: "使用剪贴板颜色 \(ColorCode.hex(clipboard.color))", symbol: "doc.on.clipboard",
                                    color: clipboard.color.blended(withFraction: 0.15, of: .black) ?? clipboard.color,
                                    help: "使用剪贴板里的颜色代码")
            button.frame = CGRect(x: inset, y: y, width: inner, height: 26)
            button.action = { [weak self] in
                self?.apply(clipboard.color, opacity: clipboard.opacity)
                self?.close()
            }
            panel.addSubview(button)
            clipboardButton = button
        }
        syncControls(updateField: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isOpen: Bool { superview != nil }

    func close() {
        guard isOpen else { return }
        catcher.removeFromSuperview()
        removeFromSuperview()
        onClose?()
    }

    private var currentColor: NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).usingColorSpace(.sRGB)!
    }

    private func emit() {
        syncControls(updateField: true)
        onChange?(currentColor, nil)
    }

    private func apply(_ color: NSColor, opacity: CGFloat?) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        hue = srgb.hueComponent
        saturation = srgb.saturationComponent
        brightness = srgb.brightnessComponent
        syncControls(updateField: true)
        onChange?(srgb, opacity)
    }

    private func syncControls(updateField: Bool) {
        square.hue = hue
        square.saturation = saturation
        square.brightness = brightness
        hueBar.hue = hue
        preview.layer?.backgroundColor = currentColor.cgColor
        if updateField { field.stringValue = ColorCode.hex(currentColor) }
    }

    static func clipboardColor() -> (color: NSColor, opacity: CGFloat?)? {
        guard let text = Clipboard.target.string(forType: .string), text.count <= 40 else { return nil }
        return ColorCode.parse(text)
    }

    // MARK: - 颜色代码输入

    func controlTextDidChange(_ notification: Notification) {
        // 输入到合法的代码就实时预览
        if let parsed = ColorCode.parse(field.stringValue) {
            let srgb = parsed.color
            hue = srgb.hueComponent
            saturation = srgb.saturationComponent
            brightness = srgb.brightnessComponent
            syncControls(updateField: false)
            onChange?(srgb, parsed.opacity)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if let parsed = ColorCode.parse(field.stringValue) { apply(parsed.color, opacity: parsed.opacity) }
            close()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    #if DEBUG
    func debugType(_ text: String) {
        field.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }
    var debugClipboardButton: PillButton? { clipboardButton }
    var debugFieldText: String { field.stringValue }
    func debugPickHue(_ h: CGFloat, saturation s: CGFloat, brightness b: CGFloat) {
        hue = h; saturation = s; brightness = b
        emit()
    }
    #endif
}

/// 颜色代码输入框：Velos 没有「编辑」菜单，⌘V / ⌘C / ⌘X / ⌘A / ⌘Z 需要自己转给输入框
private final class HexField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let editor = currentEditor() as? NSTextView else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "v": editor.paste(nil)
        case "c": editor.copy(nil)
        case "x": editor.cut(nil)
        case "a": editor.selectAll(nil)
        case "z": editor.undoManager?.undo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// 饱和度（横向）/ 亮度（纵向）方块
private final class SaturationBrightnessView: NSView {
    var onChange: ((CGFloat, CGFloat) -> Void)?
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }
    var saturation: CGFloat = 1 { didSet { needsDisplay = true } }
    var brightness: CGFloat = 1 { didSet { needsDisplay = true } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).setFill()
        bounds.fill()
        NSGradient(starting: .white, ending: NSColor.white.withAlphaComponent(0))?.draw(in: bounds, angle: 0)
        NSGradient(starting: NSColor.black.withAlphaComponent(0), ending: .black)?.draw(in: bounds, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        // 当前位置的圆圈
        let p = CGPoint(x: bounds.minX + saturation * bounds.width, y: bounds.minY + brightness * bounds.height)
        let ring = NSBezierPath(ovalIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
        ring.lineWidth = 2.5
        NSColor.white.setStroke()
        ring.stroke()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let outer = NSBezierPath(ovalIn: CGRect(x: p.x - 8.5, y: p.y - 8.5, width: 17, height: 17))
        outer.lineWidth = 1
        outer.stroke()
    }

    override func mouseDown(with event: NSEvent) { pick(event) }
    override func mouseDragged(with event: NSEvent) { pick(event) }

    private func pick(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let s = min(max((p.x - bounds.minX) / bounds.width, 0), 1)
        let b = min(max((p.y - bounds.minY) / bounds.height, 0), 1)
        saturation = s
        brightness = b
        onChange?(s, b)
    }
}

/// 色相条
private final class HueBar: NSView {
    var onChange: ((CGFloat) -> Void)?
    var hue: CGFloat = 0 { didSet { needsDisplay = true } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let colors = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { NSColor(hue: $0, saturation: 1, brightness: 1, alpha: 1) }
        NSGradient(colors: colors)?.draw(in: shape, angle: 0)
        let x = bounds.minX + hue * bounds.width
        let knob = NSBezierPath(ovalIn: CGRect(x: x - 8, y: bounds.midY - 8, width: 16, height: 16))
        NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).setFill()
        knob.fill()
        knob.lineWidth = 2.5
        NSColor.white.setStroke()
        knob.stroke()
    }

    override func mouseDown(with event: NSEvent) { pick(event) }
    override func mouseDragged(with event: NSEvent) { pick(event) }

    private func pick(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hue = min(max((p.x - bounds.minX) / bounds.width, 0), 0.999)
        onChange?(hue)
    }
}
