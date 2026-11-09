import AppKit

/// 温暖磨砂风格的小标签（见 WarmStyle）：顶部提示条、选区尺寸、钉图缩放比例。
/// 用 NSTextField 绘制文字（按屏幕倍数渲染，清晰锐利）。
final class PillLabel: NSView {
    private let panel: FrostedPanel
    private let field = NSTextField(labelWithString: "")
    private let padding: NSSize

    /// - Parameters:
    ///   - cornerRadius: nil 表示胶囊形
    ///   - blending: 截图界面 .withinWindow（虚化冻结画面），录屏界面 .behindWindow（虚化实时屏幕）
    init(padding: NSSize, cornerRadius: CGFloat? = nil, blending: NSVisualEffectView.BlendingMode = .withinWindow) {
        self.padding = padding
        panel = FrostedPanel(cornerRadius: cornerRadius, blending: blending, shadowRadius: 8)
        super.init(frame: .zero)
        addSubview(panel)
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = false
        field.isSelectable = false
        field.lineBreakMode = .byClipping
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 文字颜色：浅色模式暖棕、深色模式奶油色
    var ink: NSColor { WarmPalette(for: self).ink }
    var secondaryInk: NSColor { WarmPalette(for: self).secondaryInk }

    /// 设置文字并按文字大小调整自身尺寸
    func setText(_ text: NSAttributedString) {
        field.attributedStringValue = text
        let textSize = field.fittingSize
        let size = NSSize(width: ceil(textSize.width + padding.width * 2),
                          height: ceil(textSize.height + padding.height * 2))
        setFrameSize(size)
        panel.frame = bounds
        field.frame = NSRect(x: padding.width, y: padding.height, width: ceil(textSize.width), height: ceil(textSize.height))
    }

    /// 不拦截鼠标：提示条下面的区域照样可以拖选
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    #if DEBUG
    var debugText: String { field.stringValue }
    #endif
}
