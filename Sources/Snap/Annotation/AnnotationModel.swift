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

/// 粗细 / 字号 / 强度的三档
enum SizeLevel: Int, CaseIterable {
    case small, medium, large
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
    var size: SizeLevel = .medium
    /// 不透明度 0.1 ~ 1
    var opacity: CGFloat = 1
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
        loaded()[tool] ?? AnnotationStyle()
    }

    static func remember(_ style: AnnotationStyle, for tool: AnnotationTool) {
        var all = loaded()
        all[tool] = style
        styles = all
        defaults.set(all.reduce(into: [String: [String: Any]]()) { result, entry in
            result[entry.key.rawValue] = ["color": ColorCode.hex(entry.value.color), "size": entry.value.size.rawValue,
                                          "opacity": Double(entry.value.opacity)]
        }, forKey: key)
    }

    private static func loaded() -> [AnnotationTool: AnnotationStyle] {
        if let styles { return styles }
        var result: [AnnotationTool: AnnotationStyle] = [:]
        for (name, value) in defaults.dictionary(forKey: key) ?? [:] {
            guard let tool = AnnotationTool(rawValue: name), let entry = value as? [String: Any] else { continue }
            var style = AnnotationStyle()
            if let hex = entry["color"] as? String, let parsed = ColorCode.parse(hex) {
                // 预设颜色用原来的颜色对象（工具栏按它标选中）
                style.color = AnnotationPalette.colors.first { $0.isSameColor(as: parsed.color) } ?? parsed.color
            }
            if let size = (entry["size"] as? Int).flatMap(SizeLevel.init(rawValue:)) { style.size = size }
            if let opacity = entry["opacity"] as? Double { style.opacity = min(max(CGFloat(opacity), 0.1), 1) }
            result[tool] = style
        }
        styles = result
        return result
    }

    #if DEBUG
    /// 自测用：所有工具设成同一个样式
    static func debugSetAll(_ style: AnnotationStyle) {
        for tool in AnnotationTool.allCases { remember(style, for: tool) }
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
    var size: SizeLevel
    /// 不透明度 0.1 ~ 1（整个标注一起变淡）。马赛克 / 模糊永远不透明：变淡会露出被遮住的内容
    var opacity: CGFloat = 1

    init(shape: Shape, color: NSColor, size: SizeLevel, opacity: CGFloat = 1) {
        self.shape = shape
        self.color = color
        self.size = size
        self.opacity = Self.allowsOpacity(shape) ? opacity : 1
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

    var lineWidth: CGFloat { [2, 4, 7][size.rawValue] }
    var highlighterWidth: CGFloat { [12, 18, 26][size.rawValue] }
    var fontSize: CGFloat { Self.fontSize(for: size) }
    var counterRadius: CGFloat { [11, 14, 18][size.rawValue] }
    /// 马赛克方块边长
    var mosaicBlock: CGFloat { [6, 10, 16][size.rawValue] }
    /// 模糊半径（高斯模糊的 sigma）
    var blurRadius: CGFloat { [5, 10, 18][size.rawValue] }

    static func fontSize(for size: SizeLevel) -> CGFloat { [14, 20, 28][size.rawValue] }

    static func textFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    static func textAttributes(color: NSColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: textFont(size: fontSize), .foregroundColor: color]
    }
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
