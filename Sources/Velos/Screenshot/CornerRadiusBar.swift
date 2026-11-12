import AppKit

/// 截图界面选区左上角、尺寸标签右边的圆角拉条：拖动（或在上面滚动）调整截图的圆角，选区跟着实时变圆。
/// 0 是直角；记住上次的大小
@MainActor
final class CornerRadiusBar: NSView {
    var onChange: ((CGFloat) -> Void)?

    private let panel = FrostedPanel(blending: .withinWindow, shadowRadius: 8)
    private let slider = SizeSlider(frame: .zero)

    /// 圆角最大多少点
    static let maximum: CGFloat = 40
    private static let size = CGSize(width: 176, height: 26)

    init(radius: CGFloat) {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        addSubview(panel)
        panel.frame = bounds
        slider.configure(title: "圆角", range: 0...Self.maximum)
        slider.format = { $0 < 0.5 ? "直角" : "\(Int($0.rounded()))" }
        slider.toolTip = "截图的圆角（0–\(Int(Self.maximum)) 点，可以在上面滚动微调）"
        slider.value = min(max(radius, 0), Self.maximum)
        slider.onChange = { [weak self] value in self?.onChange?(value) }
        slider.frame = bounds.insetBy(dx: 2, dy: 0)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var radius: CGFloat { slider.value }

    #if DEBUG
    func debugSet(_ value: CGFloat) { slider.set(value) }
    #endif
}
