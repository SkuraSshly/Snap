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

/// 菜单栏图标：和 App 图标同一个前倾的「V」（Velos 在希腊语里是「箭」）——左刃细且淡、右刃粗。
/// （18pt 里放不下扫描线，加上会像一个划掉的 V，所以菜单栏只留两片刃）
/// 模板图：颜色跟着菜单栏走（浅色 / 深色自动适配）。形状和 scripts/make-icon.swift 里的是同一组坐标。
enum VelosMark {
    static let menuBar: NSImage = {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // App 图标里 V 的范围约是 1024 坐标的 (250…800, 230…830)，放进 18pt
            context.translateBy(x: 9, y: 9)
            context.scaleBy(x: 0.0265, y: 0.0265)
            context.translateBy(x: -530, y: -525)
            let rotate = CGAffineTransform(translationX: 512, y: 512).rotated(by: -0.10).translatedBy(x: -512, y: -512)
            let tip = CGPoint(x: 486, y: 246)
            func blade(_ points: [CGPoint]) {
                let path = CGMutablePath()
                path.addLines(between: points, transform: rotate)
                path.closeSubpath()
                context.addPath(path)
                context.fillPath()
            }
            // 菜单栏里刃加宽一些，小尺寸也看得清；左刃淡一点，和右刃区分开
            context.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
            blade([CGPoint(x: 252, y: 760), CGPoint(x: 372, y: 760), CGPoint(x: tip.x + 50, y: tip.y + 14), tip])
            context.setFillColor(NSColor.black.cgColor)
            blade([CGPoint(x: 660, y: 806), CGPoint(x: 812, y: 806), CGPoint(x: tip.x + 66, y: tip.y + 4), tip])
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Snap"
        return image
    }()
}
