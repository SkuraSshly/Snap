import CoreGraphics

/// 截图界面的标注工具栏放在哪里（都是遮罩视图里的坐标）
enum ToolbarPlacement {
    /// - Parameters:
    ///   - size: 工具栏大小
    ///   - selection: 区域模式的选区；全屏模式传 nil
    ///   - bounds: 遮罩视图（整块屏幕）
    /// - Returns: 工具栏左下角。区域模式在选区下方右对齐；下方放不下就放上方（让出尺寸标签的位置）；
    ///   上下都放不下就放在选区内底部。全屏模式在屏幕底部中央。左右不超出屏幕
    static func origin(size: CGSize, selection: CGRect?, in bounds: CGRect) -> CGPoint {
        let margin: CGFloat = 8
        var frame: CGRect
        if let s = selection {
            frame = CGRect(x: s.maxX - size.width, y: s.minY - margin - size.height, width: size.width, height: size.height)
            if frame.minY < bounds.minY + 4 {
                frame.origin.y = s.maxY + margin + 22
                if frame.maxY > bounds.maxY - 4 {
                    frame.origin.y = s.minY + margin
                }
            }
        } else {
            frame = CGRect(x: (bounds.width - size.width) / 2, y: 28, width: size.width, height: size.height)
        }
        frame.origin.x = min(max(frame.minX, bounds.minX + 4), bounds.maxX - size.width - 4)
        return CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded())
    }
}
