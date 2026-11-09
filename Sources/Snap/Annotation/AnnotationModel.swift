import AppKit

/// 标注工具
enum AnnotationTool: String, CaseIterable {
    case rectangle, ellipse, arrow, line, pen, highlighter, text, counter, mosaic, blur

    var title: String {
        switch self {
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .arrow: "箭头"
        case .line: "直线"
        case .pen: "画笔"
        case .highlighter: "荧光笔"
        case .text: "文字"
        case .counter: "序号"
        case .mosaic: "马赛克"
        case .blur: "模糊"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "t.square"   // 不用 textformat：中文环境下它会被系统本地化成「格式」两个字
        case .counter: "1.circle"
        case .mosaic: "checkerboard.rectangle"
        case .blur: "drop.halffull"
        }
    }

    /// 马赛克和模糊没有颜色，只有强度
    var usesColor: Bool { self != .mosaic && self != .blur }
}

/// 每种工具的「大小」：属性栏里用拉条精确调整，单位都是点
extension AnnotationTool {
    /// 拉条左边的名称
    var sizeTitle: String {
        switch self {
        case .rectangle, .ellipse, .arrow, .line, .pen: "粗细"
        case .highlighter: "宽度"
        case .text: "字号"
        case .counter: "大小"
        case .mosaic, .blur: "强度"
        }
    }

    /// 可调范围：线宽 / 荧光笔宽度 / 字号 / 序号半径 / 马赛克方块边长 / 模糊半径
    var sizeRange: ClosedRange<CGFloat> {
        switch self {
        case .rectangle, .ellipse, .arrow, .line, .pen: 1...30
        case .highlighter: 6...60
        case .text: 10...120
        case .counter: 8...40
        case .mosaic: 4...40
        case .blur: 2...40
        }
    }

    /// 以前的「小 / 中 / 大」三档对应的数值（中就是默认值；读取旧版本保存的样式时换算）
    var presetSizes: [CGFloat] {
        switch self {
        case .rectangle, .ellipse, .arrow, .line, .pen: [2, 4, 7]
        case .highlighter: [12, 18, 26]
        case .text: [14, 20, 28]
        case .counter: [11, 14, 18]
        case .mosaic: [6, 10, 16]
        case .blur: [5, 10, 18]
        }
    }

    var defaultSize: CGFloat { presetSizes[1] }

    /// 有「填充」开关的工具：矩形、椭圆（实心），文字（加底色）
    var supportsFill: Bool { self == .rectangle || self == .ellipse || self == .text }
    /// 填充开关的说明
    var fillTitle: String { self == .text ? "文字背景（底色用所选颜色）" : "实心" }
}

/// 标注颜色：红、黄、绿、蓝、白、黑
enum AnnotationPalette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1),
        .white,
        .black,
    ]
}

/// 颜色、粗细和不透明度（每个工具各自记忆，见 ToolStyleMemory）
struct AnnotationStyle {
    var color: NSColor = AnnotationPalette.colors[0]
    /// 大小（点）：含义按工具不同，见 AnnotationTool.sizeTitle
    var size: CGFloat = AnnotationTool.rectangle.defaultSize
    /// 不透明度 0.1 ~ 1
    var opacity: CGFloat = 1
    /// 填充：矩形、椭圆画成实心；文字加底色
    var filled = false
}

/// 每个工具各自记住上次用的颜色、粗细和不透明度：截图界面和重新编辑窗口共用，
/// 保存在 Snap 的设置里（UserDefaults），下次启动仍然有效
@MainActor
enum ToolStyleMemory {
    private static let key = "annotationToolStyles"
    private static var styles: [AnnotationTool: AnnotationStyle]?

    /// 自测时用单独的设置文件，不改用户自己的记忆
    private static let defaults: UserDefaults = {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["SNAP_UITEST"] != nil || environment["SNAP_SHOWCASE"] != nil,
           let test = UserDefaults(suiteName: "local.snap.uitest") {
            test.removeObject(forKey: key)
            return test
        }
        #endif
        return .standard
    }()

    static func style(for tool: AnnotationTool) -> AnnotationStyle {
        loaded()[tool] ?? AnnotationStyle(size: tool.defaultSize)
    }

    static func remember(_ style: AnnotationStyle, for tool: AnnotationTool) {
        var all = loaded()
        all[tool] = style
        styles = all
        defaults.set(all.reduce(into: [String: [String: Any]]()) { result, entry in
            result[entry.key.rawValue] = ["color": ColorCode.hex(entry.value.color), "sizeValue": Double(entry.value.size),
                                          "opacity": Double(entry.value.opacity), "filled": entry.value.filled]
        }, forKey: key)
    }

    private static func loaded() -> [AnnotationTool: AnnotationStyle] {
        if let styles { return styles }
        var result: [AnnotationTool: AnnotationStyle] = [:]
        for (name, value) in defaults.dictionary(forKey: key) ?? [:] {
            guard let tool = AnnotationTool(rawValue: name), let entry = value as? [String: Any] else { continue }
            var style = AnnotationStyle(size: tool.defaultSize)
            if let hex = entry["color"] as? String, let parsed = ColorCode.parse(hex) {
                // 预设颜色用原来的颜色对象（工具栏按它标选中）
                style.color = AnnotationPalette.colors.first { $0.isSameColor(as: parsed.color) } ?? parsed.color
            }
            if let value = entry["sizeValue"] as? Double {
                style.size = min(max(CGFloat(value), tool.sizeRange.lowerBound), tool.sizeRange.upperBound)
            } else if let level = entry["size"] as? Int, tool.presetSizes.indices.contains(level) {
                style.size = tool.presetSizes[level]   // 旧版本保存的三档
            }
            if let opacity = entry["opacity"] as? Double { style.opacity = min(max(CGFloat(opacity), 0.1), 1) }
            if let filled = entry["filled"] as? Bool { style.filled = filled && tool.supportsFill }
            result[tool] = style
        }
        styles = result
        return result
    }

    #if DEBUG
    /// 自测用：所有工具设成同一个颜色 / 不透明度，大小用各自的第 level 档（0 小、1 中、2 大）
    static func debugSetAll(_ style: AnnotationStyle, level: Int = 1) {
        for tool in AnnotationTool.allCases {
            var each = style
            each.size = tool.presetSizes[level]
            remember(each, for: tool)
        }
    }
    /// 自测用：直接写入设置文件里的原始内容（模拟旧版本保存的格式）
    static func debugStoreRaw(_ raw: [String: [String: Any]]) {
        defaults.set(raw, forKey: key)
        styles = nil
    }
    /// 自测用：丢掉内存里的记忆，从设置文件重新读取（模拟重新启动）
    static func debugReload() { styles = nil }
    /// 自测结束：删掉测试用的设置
    static func debugCleanUp() {
        styles = nil
        if defaults !== UserDefaults.standard { defaults.removePersistentDomain(forName: "local.snap.uitest") }
    }
    #endif
}

/// 一个标注。坐标是画布坐标（单位：点，原点在左下角，与 AppKit 一致）：
/// 截图界面里是所在屏幕的坐标，重新编辑窗口里是图片自身的坐标。
struct Annotation: Identifiable {
    enum Shape {
        case rectangle(CGRect)
        case ellipse(CGRect)
        case arrow(from: CGPoint, to: CGPoint)
        case line(from: CGPoint, to: CGPoint)
        case pen([CGPoint])
        case highlighter([CGPoint])
        /// topLeft：文字左上角
        case text(String, topLeft: CGPoint)
        case counter(Int, center: CGPoint)
        case mosaic(CGRect)
        case blur(CGRect)
    }

    let id = UUID()
    var shape: Shape
    var color: NSColor
    /// 大小（点）：线宽 / 荧光笔宽度 / 字号 / 序号半径 / 马赛克方块 / 模糊半径，按工具不同
    var size: CGFloat
    /// 不透明度 0.1 ~ 1（整个标注一起变淡）。马赛克 / 模糊永远不透明：变淡会露出被遮住的内容
    var opacity: CGFloat = 1
    /// 填充：矩形、椭圆是实心；文字有底色（其他标注忽略）
    var filled = false

    init(shape: Shape, color: NSColor, size: CGFloat, opacity: CGFloat = 1, filled: Bool = false) {
        self.shape = shape
        self.color = color
        self.size = size
        self.opacity = Self.allowsOpacity(shape) ? opacity : 1
        self.filled = filled
    }

    /// 能不能调不透明度（马赛克、模糊不能）
    var allowsOpacity: Bool { Self.allowsOpacity(shape) }

    private static func allowsOpacity(_ shape: Shape) -> Bool {
        switch shape {
        case .mosaic, .blur: false
        default: true
        }
    }

    /// 画出这种标注的工具（选中标注时，属性栏按它显示颜色 / 粗细）
    var tool: AnnotationTool {
        switch shape {
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .arrow: .arrow
        case .line: .line
        case .pen: .pen
        case .highlighter: .highlighter
        case .text: .text
        case .counter: .counter
        case .mosaic: .mosaic
        case .blur: .blur
        }
    }

    // MARK: - 各工具的尺寸（单位：点）

    // 都直接就是 size：每种标注只用其中一个
    var lineWidth: CGFloat { size }
    var highlighterWidth: CGFloat { size }
    var fontSize: CGFloat { size }
    var counterRadius: CGFloat { size }
    /// 马赛克方块边长
    var mosaicBlock: CGFloat { size }
    /// 模糊半径（高斯模糊的 sigma）
    var blurRadius: CGFloat { size }

    static func textFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    static func textAttributes(color: NSColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: textFont(size: fontSize), .foregroundColor: color]
    }

    /// 有底色的文字：文字用白色还是黑色（浅色底上用黑字，其他用白字）
    static func textColor(onBackground background: NSColor) -> NSColor {
        guard let c = background.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    /// 文字底色比文字本身大出的边距
    static func textBackgroundPadding(fontSize: CGFloat) -> CGSize {
        CGSize(width: (fontSize * 0.3).rounded(), height: (fontSize * 0.12).rounded())
    }

    /// 绘制文字时用的颜色：有底色时自动用白 / 黑字
    var textForeground: NSColor { filled ? Self.textColor(onBackground: color) : color }
}

/// 标注列表 + 撤销 / 重做
@MainActor
final class AnnotationDocument {
    private(set) var annotations: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    var isEmpty: Bool { annotations.isEmpty }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// 下一个序号：现有最大序号 + 1（删掉中间某个序号不会出现重复；撤销后自动回退）
    var nextCounterNumber: Int {
        annotations.reduce(0) { maximum, annotation in
            if case .counter(let number, _) = annotation.shape { return max(maximum, number) }
            return maximum
        } + 1
    }

    func add(_ annotation: Annotation) {
        recordUndo()
        annotations.append(annotation)
    }

    /// 记一个撤销点（之后的修改可以一次撤销回来）
    func recordUndo() {
        undoStack.append(annotations)
        redoStack.removeAll()
    }

    func annotation(withID id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    /// 替换同一个标注（移动时用）；需要的话先调用 recordUndo 记撤销点
    func replace(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    /// 删除一个标注（可撤销）
    @discardableResult
    func remove(id: UUID) -> Bool {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        recordUndo()
        annotations.remove(at: index)
        return true
    }

    @discardableResult
    func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(annotations)
        annotations = previous
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(annotations)
        annotations = next
        return true
    }
}
