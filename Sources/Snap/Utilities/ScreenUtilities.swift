import AppKit

extension NSScreen {
    /// 对应的 CoreGraphics 显示器编号（ScreenCaptureKit 用它来匹配 SCDisplay）
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    /// 包含该点（全局坐标）的屏幕；点恰好落在边缘外时取最近的屏幕
    static func screen(containing point: NSPoint) -> NSScreen? {
        let screens = NSScreen.screens
        if let hit = screens.first(where: { $0.frame.contains(point) }) { return hit }
        return screens.min { $0.frame.distance(to: point) < $1.frame.distance(to: point) }
    }

    /// 鼠标当前所在的屏幕
    static var underMouse: NSScreen? {
        screen(containing: NSEvent.mouseLocation)
    }
}

extension NSWindow {
    /// 一级窗口：放在鼠标所在屏幕的正中间（可用区域的中心，不含菜单栏和程序坞）。
    /// 系统自带的 center() 会偏上，这里是严格居中
    func centerOnScreen() {
        guard let visible = (NSScreen.underMouse ?? screen ?? NSScreen.main)?.visibleFrame else { return }
        setFrameOrigin(CGPoint(x: (visible.midX - frame.width / 2).rounded(), y: (visible.midY - frame.height / 2).rounded()))
    }

    /// 二级窗口：放在父窗口的正中间，并跟着父窗口一起移动、保持在它上面
    func center(over parent: NSWindow) {
        let target = CGPoint(x: (parent.frame.midX - frame.width / 2).rounded(), y: (parent.frame.midY - frame.height / 2).rounded())
        setFrameOrigin(target)
        if parent.childWindows?.contains(self) != true {
            parent.addChildWindow(self, ordered: .above)
        }
    }
}

extension CGRect {
    /// 点到矩形的距离（点在矩形内为 0）
    func distance(to point: CGPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 对齐到像素网格（scale = 每点像素数），保证选区边缘正好落在像素边界上
    func alignedToPixels(scale: CGFloat) -> CGRect {
        let minX = (self.minX * scale).rounded() / scale
        let minY = (self.minY * scale).rounded() / scale
        let maxX = (self.maxX * scale).rounded() / scale
        let maxY = (self.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension CGPoint {
    /// 限制在矩形范围内
    func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY))
    }
}
