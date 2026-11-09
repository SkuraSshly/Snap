import AppKit

/// 区域选择的交互逻辑（截图和录屏共用）：
/// 悬停识别窗口、单击选中窗口、拖拽新建选区、拖动移动、8 个控制点和四条边调整大小、方向键微调。
///
/// 只管理几何状态，不负责绘制。坐标统一为 AppKit 全局坐标（单位：点），
/// 选区始终对齐到所在屏幕的像素网格，保证显示的就是最终裁剪出来的像素。
@MainActor
final class RegionSelector {
    struct ScreenInfo {
        let frame: CGRect
        let scale: CGFloat
    }

    /// 8 个控制点（AppKit 坐标中 top 是 maxY）
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .top: CGPoint(x: rect.midX, y: rect.maxY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
            case .right: CGPoint(x: rect.maxX, y: rect.midY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottom: CGPoint(x: rect.midX, y: rect.minY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .left: CGPoint(x: rect.minX, y: rect.midY)
            }
        }

        var cursor: NSCursor {
            let position: NSCursor.FrameResizePosition = switch self {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .left: .left
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
    }

    private enum Interaction {
        case idle
        /// 已按下但还没拖动：松开时算单击（单击高亮窗口 = 选中这个窗口）
        case pressed(anchor: CGPoint, displayID: CGDirectDisplayID)
        case creating(anchor: CGPoint)
        case moving(start: CGPoint, original: CGRect)
        case resizing(handle: Handle, original: CGRect)
    }

    /// 参与选择的屏幕（只有已冻结 / 已显示遮罩的屏幕）
    var screens: [CGDirectDisplayID: ScreenInfo] = [:]
    /// 从前到后的窗口矩形
    var windows: [CGRect] = []

    private(set) var selection: CGRect?
    private(set) var selectionDisplayID: CGDirectDisplayID?
    private(set) var hoveredWindow: CGRect?
    private(set) var hoveredDisplayID: CGDirectDisplayID?
    private var interaction: Interaction = .idle

    /// 按下后移动超过这个距离才算拖拽，否则算单击
    private let dragThreshold: CGFloat = 3
    /// 控制点的点击范围（半径）
    private let handleHitRadius: CGFloat = 7
    /// 边框的点击范围（向内外各扩展）
    private let edgeHitTolerance: CGFloat = 4
    /// 选区最小尺寸（点），小于它视为误触
    private let minimumSize: CGFloat = 2

    // MARK: - 查询

    /// 鼠标正按着（拖选、移动、调整中）：工具栏此时隐藏，免得挡视线
    var isInteracting: Bool {
        if case .idle = interaction { return false }
        return true
    }

    /// 正在新建或调整大小（此时需要放大镜帮助对准像素）
    var isSizing: Bool {
        switch interaction {
        case .creating, .resizing: true
        default: false
        }
    }

    /// 按 Enter 时要截取的区域：有选区用选区，否则用高亮的窗口；拖拽进行中不截取
    var target: (rect: CGRect, displayID: CGDirectDisplayID)? {
        guard case .idle = interaction else { return nil }
        if let selection, let selectionDisplayID { return (selection, selectionDisplayID) }
        if let hoveredWindow, let hoveredDisplayID { return (hoveredWindow, hoveredDisplayID) }
        return nil
    }

    /// 该位置应显示的鼠标指针
    func cursor(at point: CGPoint) -> NSCursor {
        switch interaction {
        case .moving: return .closedHand
        case .resizing(let handle, _): return handle.cursor
        case .creating, .pressed: return .crosshair
        case .idle: break
        }
        guard let selection else { return .crosshair }
        if let handle = handle(at: point, in: selection) { return handle.cursor }
        return selection.contains(point) ? .openHand : .crosshair
    }

    /// 正好按在选区的 8 个控制点之一上（不含四条边，免得和在选区边缘画标注冲突）：
    /// 选着标注工具时也能拖这几个点调整选区
    func cornerHandle(at point: CGPoint) -> Handle? {
        guard let selection else { return nil }
        return Handle.allCases.first {
            let p = $0.point(in: selection)
            return hypot(point.x - p.x, point.y - p.y) <= handleHitRadius
        }
    }

    // MARK: - 鼠标

    func mouseMoved(to point: CGPoint) {
        guard case .idle = interaction, selection == nil else { return }
        updateHover(at: point)
    }

    func mouseDown(at point: CGPoint) {
        if let selection, let id = selectionDisplayID, screens[id] != nil {
            if let handle = handle(at: point, in: selection) {
                interaction = .resizing(handle: handle, original: selection)
                return
            }
            if selection.contains(point) {
                interaction = .moving(start: point, original: selection)
                return
            }
        }
        // 在选区外按下：可能是单击选窗口，也可能是重新拖一个新选区
        guard let id = displayID(at: point), let screen = screens[id] else { return }
        interaction = .pressed(anchor: snap(point.clamped(to: screen.frame), scale: screen.scale), displayID: id)
    }

    func mouseDragged(to point: CGPoint) {
        switch interaction {
        case .idle:
            return

        case .pressed(let anchor, let id):
            guard hypot(point.x - anchor.x, point.y - anchor.y) >= dragThreshold else { return }
            // 开始拖拽新选区：旧选区和窗口高亮都清掉
            interaction = .creating(anchor: anchor)
            selectionDisplayID = id
            clearHover()
            updateCreating(from: anchor, to: point)

        case .creating(let anchor):
            updateCreating(from: anchor, to: point)

        case .moving(let start, let original):
            guard let screen = selectionScreen else { return }
            selection = moved(original, by: CGSize(width: point.x - start.x, height: point.y - start.y), within: screen)

        case .resizing(let handle, let original):
            guard let screen = selectionScreen else { return }
            selection = resized(original, handle: handle, to: point.clamped(to: screen.frame))
                .alignedToPixels(scale: screen.scale)
        }
    }

    func mouseUp(at point: CGPoint) {
        defer { interaction = .idle }
        switch interaction {
        case .pressed(_, let id):
            // 单击：如果点在高亮的窗口上，就把这个窗口作为选区（之后可以继续调整）
            if let hoveredWindow, hoveredDisplayID == id, hoveredWindow.contains(point) {
                selection = hoveredWindow
                selectionDisplayID = id
                clearHover()
            }
        case .creating, .resizing:
            if let selection, selection.width < minimumSize || selection.height < minimumSize {
                clearSelection(at: point)
            }
        default:
            break
        }
    }

    /// 切换模式等情况下中止正在进行的拖拽（已有选区保留）
    func cancelInteraction() {
        interaction = .idle
        if let selection, selection.width < minimumSize || selection.height < minimumSize {
            self.selection = nil
            selectionDisplayID = nil
        }
    }

    /// 清除选区，回到悬停识别窗口的状态
    func clearSelection(at point: CGPoint) {
        selection = nil
        selectionDisplayID = nil
        interaction = .idle
        updateHover(at: point)
    }

    // MARK: - 方向键微调

    /// 按像素移动选区（dx 向右为正，dy 向上为正）；没有选区时返回 false
    @discardableResult
    func nudge(dxPixels: Int, dyPixels: Int) -> Bool {
        guard case .idle = interaction, let selection, let screen = selectionScreen else { return false }
        let offset = CGSize(width: CGFloat(dxPixels) / screen.scale, height: CGFloat(dyPixels) / screen.scale)
        self.selection = moved(selection, by: offset, within: screen)
        return true
    }

    // MARK: - 内部计算

    private func updateCreating(from anchor: CGPoint, to point: CGPoint) {
        guard let screen = selectionScreen else { return }
        let current = point.clamped(to: screen.frame)
        selection = CGRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
                           width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
            .alignedToPixels(scale: screen.scale)
    }

    private var selectionScreen: ScreenInfo? {
        selectionDisplayID.flatMap { screens[$0] }
    }

    private func displayID(at point: CGPoint) -> CGDirectDisplayID? {
        guard let id = NSScreen.screen(containing: point)?.displayID, screens[id] != nil else { return nil }
        return id
    }

    /// 悬停识别：找到鼠标下最靠前的窗口，裁剪到所在屏幕
    private func updateHover(at point: CGPoint) {
        guard let id = displayID(at: point), let screen = screens[id],
              let window = windows.first(where: { $0.contains(point) }) else {
            clearHover()
            return
        }
        let visible = window.intersection(screen.frame).alignedToPixels(scale: screen.scale)
        guard visible.width >= minimumSize, visible.height >= minimumSize else {
            clearHover()
            return
        }
        hoveredWindow = visible
        hoveredDisplayID = id
    }

    private func clearHover() {
        hoveredWindow = nil
        hoveredDisplayID = nil
    }

    /// 命中哪个控制点：先看 8 个控制点，再看四条边
    private func handle(at point: CGPoint, in rect: CGRect) -> Handle? {
        if let handle = Handle.allCases.first(where: {
            let p = $0.point(in: rect)
            return hypot(point.x - p.x, point.y - p.y) <= handleHitRadius
        }) {
            return handle
        }
        let t = edgeHitTolerance
        let withinX = point.x >= rect.minX - t && point.x <= rect.maxX + t
        let withinY = point.y >= rect.minY - t && point.y <= rect.maxY + t
        if withinX && abs(point.y - rect.maxY) <= t { return .top }
        if withinX && abs(point.y - rect.minY) <= t { return .bottom }
        if withinY && abs(point.x - rect.minX) <= t { return .left }
        if withinY && abs(point.x - rect.maxX) <= t { return .right }
        return nil
    }

    /// 拖动控制点后的新矩形：总是从拖拽开始时的矩形计算，越过对边时自动翻转
    private func resized(_ rect: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = p.x; maxY = p.y
        case .top: maxY = p.y
        case .topRight: maxX = p.x; maxY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; minY = p.y
        case .bottom: minY = p.y
        case .bottomLeft: minX = p.x; minY = p.y
        case .left: minX = p.x
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    /// 平移并限制在屏幕内，结果对齐像素
    private func moved(_ rect: CGRect, by offset: CGSize, within screen: ScreenInfo) -> CGRect {
        let frame = screen.frame
        var result = rect.offsetBy(dx: offset.width, dy: offset.height)
        result.origin.x = min(max(result.minX, frame.minX), frame.maxX - result.width)
        result.origin.y = min(max(result.minY, frame.minY), frame.maxY - result.height)
        // 只对齐原点，保持尺寸不变
        result.origin = snap(result.origin, scale: screen.scale)
        return result
    }

    private func snap(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }
}
