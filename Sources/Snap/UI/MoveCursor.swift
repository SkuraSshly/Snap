import AppKit

extension NSCursor {
    /// 四向移动光标：鼠标在能拖动的标注上时显示。macOS 没有公开的「移动」光标，这里自己画，
    /// 配合温暖风格：可可色的四个箭头、白色描边（任何背景上都看得清，和系统光标一样）、柔和投影、杏色圆心。
    /// 用矢量绘制，Retina 屏上自动按像素重画，不会发虚。
    static let snapMove: NSCursor = {
        let side: CGFloat = 26
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawMoveArrows(in: ctx, center: CGPoint(x: side / 2, y: side / 2))
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: side / 2, y: side / 2))
    }()

    /// 四个箭头：细杆 + 圆润的三角箭头，中心一个杏色小圆点
    private static func drawMoveArrows(in ctx: CGContext, center c: CGPoint) {
        let shaftHalfWidth: CGFloat = 0.85
        let headBase: CGFloat = 7.4, headTip: CGFloat = 11.2, headHalfWidth: CGFloat = 3.1
        let arrows = CGMutablePath()
        for (ux, uy) in [(CGFloat(1), CGFloat(0)), (0, 1), (-1, 0), (0, -1)] {
            // 沿箭头方向 along、向侧面 side 的点
            func p(_ along: CGFloat, _ side: CGFloat) -> CGPoint {
                CGPoint(x: c.x + ux * along - uy * side, y: c.y + uy * along + ux * side)
            }
            arrows.move(to: p(0, -shaftHalfWidth))
            arrows.addLine(to: p(headBase + 0.5, -shaftHalfWidth))
            arrows.addLine(to: p(headBase + 0.5, shaftHalfWidth))
            arrows.addLine(to: p(0, shaftHalfWidth))
            arrows.closeSubpath()
            arrows.move(to: p(headTip, 0))
            arrows.addLine(to: p(headBase, -headHalfWidth))
            arrows.addLine(to: p(headBase, headHalfWidth))
            arrows.closeSubpath()
        }
        let ink = NSColor(srgbRed: 0.30, green: 0.21, blue: 0.15, alpha: 1).cgColor

        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        // 1. 白色描边 + 投影（先画整块描边，再在上面填充，箭头相接处不会露出白线）
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.6), blur: 1.8, color: NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.addPath(arrows)
        ctx.setLineWidth(2.6)
        ctx.setStrokeColor(.white)
        ctx.strokePath()
        ctx.restoreGState()
        // 2. 可可色填充，再描一圈同色细线，让箭头的尖角圆润一点
        ctx.addPath(arrows)
        ctx.setFillColor(ink)
        ctx.fillPath()
        ctx.addPath(arrows)
        ctx.setLineWidth(0.7)
        ctx.setStrokeColor(ink)
        ctx.strokePath()
        // 3. 中心：白圈里一个杏色圆点
        ctx.setFillColor(.white)
        ctx.fillEllipse(in: CGRect(x: c.x - 2.6, y: c.y - 2.6, width: 5.2, height: 5.2))
        ctx.setFillColor(WarmPalette.apricot.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 1.7, y: c.y - 1.7, width: 3.4, height: 3.4))
    }

    #if DEBUG
    /// 自测：把移动光标放大画在浅色、深色、照片般的背景上，方便看效果
    static func debugRenderMovePreview(to url: URL) {
        let scale: CGFloat = 6, tile: CGFloat = 26
        let backgrounds: [NSColor] = [.white, NSColor(white: 0.18, alpha: 1), WarmPalette.apricot,
                                      NSColor(srgbRed: 0.13, green: 0.27, blue: 0.53, alpha: 1)]
        let width = Int(tile * scale) * backgrounds.count, height = Int(tile * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        for (i, background) in backgrounds.enumerated() {
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(i) * tile * scale, y: 0)
            ctx.setFillColor(background.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: tile * scale, height: tile * scale))
            ctx.scaleBy(x: scale, y: scale)
            drawMoveArrows(in: ctx, center: CGPoint(x: tile / 2, y: tile / 2))
            ctx.restoreGState()
        }
        guard let image = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif
}
