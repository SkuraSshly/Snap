import AppKit
import Synchronization

/// Velos 自己画的光标，配合温暖风格。macOS 没有公开的「移动」光标，系统调整大小的小三角又是黑色的，所以自己画：
/// 杏色填充 + 深杏色细边 + 白色描边（任何背景上都看得清，和系统光标一样）+ 柔和投影。
/// 用矢量绘制，Retina 屏上自动按像素重画，不会发虚。
///
/// - `NSCursor.snapMove`：四向移动（鼠标在能拖动的标注上）
/// - `NSCursor.warmResize(angle:outward:)`：一对背靠背的小三角（选区、标注的控制点，拉条的白点）
enum WarmCursor {
    /// 光标图的边长（点），热点在正中
    static let side: CGFloat = 26

    /// 一种光标的形状：要填充的路径（可以有好几块，各自的颜色）和画完填充后再叠上的东西
    struct Shape {
        struct Part {
            let path: CGPath
            let fill: NSColor
            let edge: NSColor
        }
        var parts: [Part]
        var overlay: ((CGContext) -> Void)? = nil
    }

    /// 画一个光标：先画所有部分的白色描边 + 投影（整块描边，再在上面填充，相接处不露白线），再填充、描细边
    static func draw(_ shape: Shape, in ctx: CGContext) {
        let outline = CGMutablePath()
        for part in shape.parts { outline.addPath(part.path) }
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.6), blur: 1.8, color: NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.addPath(outline)
        ctx.setLineWidth(2.6)
        ctx.setStrokeColor(.white)
        ctx.strokePath()
        ctx.restoreGState()
        for part in shape.parts {
            ctx.addPath(part.path)
            ctx.setFillColor(part.fill.cgColor)
            ctx.fillPath()
            ctx.addPath(part.path)
            ctx.setLineWidth(0.7)
            ctx.setStrokeColor(part.edge.cgColor)
            ctx.strokePath()
        }
        shape.overlay?(ctx)
    }

    static func makeCursor(_ shape: @escaping @Sendable (CGPoint) -> Shape) -> NSCursor {
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(shape(CGPoint(x: side / 2, y: side / 2)), in: ctx)
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: side / 2, y: side / 2))
    }

    /// 以 center 为原点、沿 angle 方向 along、向左侧 side 的点
    static func point(_ center: CGPoint, angle: CGFloat) -> (CGFloat, CGFloat) -> CGPoint {
        let ux = cos(angle), uy = sin(angle)
        return { along, side in CGPoint(x: center.x + ux * along - uy * side, y: center.y + uy * along + ux * side) }
    }

    // MARK: - 形状

    /// 四个箭头：细杆 + 圆润的三角箭头，中心白圈里一个可可色小圆点
    static func move(center c: CGPoint) -> Shape {
        let shaftHalfWidth: CGFloat = 0.85
        let headBase: CGFloat = 7.4, headTip: CGFloat = 11.2, headHalfWidth: CGFloat = 3.1
        let arrows = CGMutablePath()
        for k in 0..<4 {
            let p = point(c, angle: CGFloat(k) * .pi / 2)
            arrows.addLines(between: [p(0, -shaftHalfWidth), p(headBase + 0.5, -shaftHalfWidth),
                                      p(headBase + 0.5, shaftHalfWidth), p(0, shaftHalfWidth)])
            arrows.closeSubpath()
            arrows.addLines(between: [p(headTip, 0), p(headBase, -headHalfWidth), p(headBase, headHalfWidth)])
            arrows.closeSubpath()
        }
        return Shape(parts: [.init(path: arrows, fill: WarmPalette.apricot, edge: WarmPalette.apricotEdge)]) { ctx in
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: CGRect(x: c.x - 2.6, y: c.y - 2.6, width: 5.2, height: 5.2))
            ctx.setFillColor(WarmPalette.cocoa.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 1.7, y: c.y - 1.7, width: 3.4, height: 3.4))
        }
    }

    /// 两个背靠背的三角：沿 angle 方向一前一后，中间留一点空隙。
    /// outward 时朝外的是杏色、朝里的是浅杏色（往外拖是放大，一眼看出来）；否则两个一样
    static func resize(center c: CGPoint, angle: CGFloat, outward: Bool) -> Shape {
        let p = point(c, angle: angle)
        // 细长的等腰三角：底边 6.6、高 7.2；两个三角之间空 4.4
        let gap: CGFloat = 2.2, length: CGFloat = 7.2, halfWidth: CGFloat = 3.3
        func triangle(_ sign: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: [p(sign * (gap + length), 0), p(sign * gap, -halfWidth), p(sign * gap, halfWidth)])
            path.closeSubpath()
            return path
        }
        let strong = Shape.Part(path: triangle(1), fill: WarmPalette.apricot, edge: WarmPalette.apricotEdge)
        let back = outward
            ? Shape.Part(path: triangle(-1), fill: WarmPalette.apricotPale, edge: WarmPalette.apricotPaleEdge)
            : Shape.Part(path: triangle(-1), fill: WarmPalette.apricot, edge: WarmPalette.apricotEdge)
        return Shape(parts: [strong, back])
    }

    #if DEBUG
    /// 自测：把几种光标放大画在浅色、深色、杏色、蓝色背景上，方便看效果（每行一种背景，每列一种光标）
    static func debugRenderPreview(to url: URL) {
        let scale: CGFloat = 5
        let backgrounds: [NSColor] = [.white, NSColor(white: 0.18, alpha: 1), WarmPalette.apricot,
                                      NSColor(srgbRed: 0.13, green: 0.27, blue: 0.53, alpha: 1)]
        let shapes: [(CGPoint) -> Shape] = [
            move(center:),
            { resize(center: $0, angle: .pi, outward: true) },
            { resize(center: $0, angle: .pi / 2, outward: true) },
            { resize(center: $0, angle: .pi / 4, outward: true) },
            { resize(center: $0, angle: 0, outward: false) },
        ]
        let tile = side * scale
        guard let ctx = CGContext(data: nil, width: Int(tile) * shapes.count, height: Int(tile) * backgrounds.count,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        for (row, background) in backgrounds.enumerated() {
            for (column, shape) in shapes.enumerated() {
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(column) * tile, y: CGFloat(row) * tile)
                ctx.setFillColor(background.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: tile, height: tile))
                ctx.scaleBy(x: scale, y: scale)
                draw(shape(CGPoint(x: side / 2, y: side / 2)), in: ctx)
                ctx.restoreGState()
            }
        }
        guard let image = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif
}

extension NSCursor {
    /// 四向移动光标：鼠标在能拖动的标注上时显示
    static let snapMove = WarmCursor.makeCursor { WarmCursor.move(center: $0) }

    /// 调整大小的光标（一对背靠背的小三角）。
    /// - Parameters:
    ///   - angle: 「往外」的方向（弧度，0 向右、π/2 向上），取最接近的 45° 方向
    ///   - outward: true：朝外的三角深、朝里的浅（选区、标注的控制点）；false：两个一样（拉条的白点）
    static func warmResize(angle: CGFloat, outward: Bool) -> NSCursor {
        let octant = (Int((angle / (.pi / 4)).rounded()) % 8 + 8) % 8
        let key = octant * 2 + (outward ? 1 : 0)
        return resizeCursors.withLock { cache in
            if let cached = cache[key] { return cached }
            let cursor = WarmCursor.makeCursor { WarmCursor.resize(center: $0, angle: CGFloat(octant) * .pi / 4, outward: outward) }
            cache[key] = cursor
            return cursor
        }
    }

    /// 16 种（8 个方向 × 深浅两种）用到时才画，画一次就留着
    private static let resizeCursors = Mutex<[Int: NSCursor]>([:])
}
