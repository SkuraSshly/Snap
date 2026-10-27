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

/// 当前的颜色和粗细（所有工具共用，像 Snipaste 一样切换工具后保持）
struct AnnotationStyle {
    var color: NSColor = AnnotationPalette.colors[0]
    var size: SizeLevel = .medium

    /// 上次用的颜色和粗细：截图界面和重新编辑窗口共用，本次运行期间保留
    @MainActor static var lastUsed = AnnotationStyle()
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

    /// 下一个序号：按现有序号数量递增，撤销后自动回退
    var nextCounterNumber: Int {
        annotations.reduce(0) { count, annotation in
            if case .counter = annotation.shape { return count + 1 }
            return count
        } + 1
    }

    func add(_ annotation: Annotation) {
        undoStack.append(annotations)
        redoStack.removeAll()
        annotations.append(annotation)
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
