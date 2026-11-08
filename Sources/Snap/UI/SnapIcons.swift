import AppKit

/// 自己画的图标（系统图标里没有合适的）。都是模板图：颜色由按钮决定（平时暖棕色，选中时白色），和系统图标一致
enum SnapIcons {
    /// 长截图：上面一个开口的框（一整页），下面一把剪刀（剪下来）
    static let longCapture: NSImage = {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: true) { _ in
            drawLongCapture()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "长截图"
        return image
    }()

    /// 在 18 × 18 的坐标里画（y 轴向下）
    static func drawLongCapture(color: NSColor = .black) {
        color.setStroke()
        let frame = NSBezierPath()
        frame.lineWidth = 1.5
        frame.lineCapStyle = .round
        frame.lineJoinStyle = .round
        // 开口的框：左边、上边（圆角）、右边，底边留空
        frame.move(to: CGPoint(x: 3.25, y: 9.6))
        frame.line(to: CGPoint(x: 3.25, y: 4.5))
        frame.appendArc(withCenter: CGPoint(x: 5, y: 4.5), radius: 1.75, startAngle: 180, endAngle: 270, clockwise: false)
        frame.line(to: CGPoint(x: 13, y: 2.75))
        frame.appendArc(withCenter: CGPoint(x: 13, y: 4.5), radius: 1.75, startAngle: 270, endAngle: 360, clockwise: false)
        frame.line(to: CGPoint(x: 14.75, y: 9.6))
        frame.stroke()

        // 剪刀：两条刀刃在框的下沿交叉，下面两个圆形把手
        let blades = NSBezierPath()
        blades.lineWidth = 1.5
        blades.lineCapStyle = .round
        blades.move(to: CGPoint(x: 6.6, y: 6.4))
        blades.line(to: CGPoint(x: 11.3, y: 13.2))
        blades.move(to: CGPoint(x: 11.4, y: 6.4))
        blades.line(to: CGPoint(x: 6.7, y: 13.2))
        blades.stroke()
        for center in [CGPoint(x: 5.7, y: 14.9), CGPoint(x: 12.3, y: 14.9)] {
            let handle = NSBezierPath(ovalIn: CGRect(x: center.x - 1.9, y: center.y - 1.9, width: 3.8, height: 3.8))
            handle.lineWidth = 1.5
            handle.stroke()
        }
    }
}
