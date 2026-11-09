import AppKit
import CoreImage

/// 标注所在的底图：画布坐标（点，原点左下）与底图像素（原点左上）之间的换算
struct BaseImage {
    let image: CGImage
    /// 每点像素数
    let scale: CGFloat
    /// 画布高度（点），用于翻转 y
    let canvasHeight: CGFloat

    /// 画布矩形对应的像素矩形（取整并限制在图像内）
    func pixelRect(for rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scale, y: (canvasHeight - rect.maxY) * scale,
               width: rect.width * scale, height: rect.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    func crop(_ rect: CGRect) -> CGImage? {
        let pixels = pixelRect(for: rect)
        guard !pixels.isEmpty else { return nil }
        return image.cropping(to: pixels)
    }
}

/// 绘制标注。实时预览和最终输出用的是同一套绘制代码，所见即所得。
@MainActor
final class AnnotationRenderer {
    let base: BaseImage
    /// 马赛克 / 模糊的处理结果缓存（区域不变就不重复计算）
    private var patchCache: [UUID: (rect: CGRect, image: CGImage)] = [:]
    /// Core Image（GPU）只在用到模糊时创建，随这次截图一起释放，空闲时不占 GPU 资源
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

    init(base: BaseImage) {
        self.base = base
    }

    func draw(_ annotations: [Annotation], in ctx: CGContext) {
        for annotation in annotations {
            draw(annotation, in: ctx)
        }
    }

    func draw(_ annotation: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(annotation.allowsOpacity ? annotation.opacity : 1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let color = annotation.color.cgColor

        switch annotation.shape {
        case .rectangle(let rect):
            if annotation.filled {
                ctx.setFillColor(color)
                ctx.fill(rect)
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(annotation.lineWidth)
                ctx.setLineJoin(.miter)
                ctx.stroke(rect)
            }

        case .ellipse(let rect):
            if annotation.filled {
                ctx.setFillColor(color)
                ctx.fillEllipse(in: rect)
            } else {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(annotation.lineWidth)
                ctx.strokeEllipse(in: rect)
            }

        case .line(let from, let to):
            ctx.setStrokeColor(color)
            ctx.setLineWidth(annotation.lineWidth)
            ctx.strokeLineSegments(between: [from, to])

        case .arrow(let from, let to):
            drawArrow(from: from, to: to, width: annotation.lineWidth, color: color, in: ctx)

        case .pen(let points):
            ctx.setStrokeColor(color)
            ctx.setLineWidth(annotation.lineWidth)
            ctx.addPath(Self.smoothPath(points))
            ctx.strokePath()

        case .highlighter(let points):
            // 整条笔画一次描边，自身重叠的地方不会颜色加深
            ctx.setStrokeColor(annotation.color.withAlphaComponent(0.38).cgColor)
            ctx.setLineWidth(annotation.highlighterWidth)
            ctx.setLineCap(.square)
            ctx.addPath(Self.smoothPath(points))
            ctx.strokePath()

        case .text(let string, let topLeft):
            let attributed = NSAttributedString(string: string,
                                                attributes: Annotation.textAttributes(color: annotation.textForeground,
                                                                                      fontSize: annotation.fontSize))
            let size = Self.textSize(attributed)
            let textRect = CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
            if annotation.filled {
                // 底色：比文字大一圈的圆角块，颜色就是所选颜色
                let pad = Annotation.textBackgroundPadding(fontSize: annotation.fontSize)
                let box = textRect.insetBy(dx: -pad.width, dy: -pad.height)
                let radius = annotation.fontSize * 0.22
                ctx.setFillColor(color)
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            }
            drawText(attributed, in: textRect, ctx: ctx)

        case .counter(let number, let center):
            let r = annotation.counterRadius
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            // 白色和黄色底上用黑字，其他用白字
            let light = annotation.color.usingColorSpace(.sRGB).map { $0.brightnessComponent > 0.85 && $0.saturationComponent < 0.9 } ?? false
            let textColor: NSColor = light || annotation.color == AnnotationPalette.colors[1] ? .black : .white
            let attributed = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: r * 1.15, weight: .bold),
                .foregroundColor: textColor,
            ])
            let size = Self.textSize(attributed)
            drawText(attributed, in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                            width: size.width, height: size.height), ctx: ctx)

        case .mosaic(let rect):
            if let patch = patch(for: annotation, rect: rect, make: { self.mosaic(rect, block: annotation.mosaicBlock) }) {
                ctx.interpolationQuality = .none
                ctx.draw(patch, in: rect)
            }

        case .blur(let rect):
            if let patch = patch(for: annotation, rect: rect, make: { self.blur(rect, radius: annotation.blurRadius) }) {
                ctx.draw(patch, in: rect)
            }
        }
    }

    /// 拖拽过程中的马赛克 / 模糊不进缓存（区域一直在变）
    func clearPatch(for id: UUID) {
        patchCache[id] = nil
    }

    // MARK: - 形状

    private func drawArrow(from: CGPoint, to: CGPoint, width: CGFloat, color: CGColor, in ctx: CGContext) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let ux = dx / length, uy = dy / length
        // 箭头头部大小随线宽变化，但不超过整支箭头的一半
        let headLength = min(max(12, width * 4), length * 0.5)
        let headHalfWidth = headLength * 0.45
        let base = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)

        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.strokeLineSegments(between: [from, CGPoint(x: base.x + ux * 1, y: base.y + uy * 1)])

        ctx.setFillColor(color)
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: base.x - uy * headHalfWidth, y: base.y + ux * headHalfWidth))
        ctx.addLine(to: CGPoint(x: base.x + uy * headHalfWidth, y: base.y - ux * headHalfWidth))
        ctx.closePath()
        ctx.fillPath()
    }

    /// 画笔轨迹平滑：用相邻点的中点做二次贝塞尔曲线，去掉折线感
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
            return path
        }
        for i in 1..<points.count {
            let previous = points[i - 1], current = points[i]
            let mid = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: mid, control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    // MARK: - 文字

    static func textSize(_ attributed: NSAttributedString) -> CGSize {
        let bounds = attributed.boundingRect(with: CGSize(width: 10_000, height: 10_000),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }

    private func drawText(_ attributed: NSAttributedString, in rect: CGRect, ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - 马赛克与模糊（基于底图的原始像素）

    private func patch(for annotation: Annotation, rect: CGRect, make: () -> CGImage?) -> CGImage? {
        if let cached = patchCache[annotation.id], cached.rect == rect { return cached.image }
        guard let image = make() else { return nil }
        patchCache[annotation.id] = (rect, image)
        return image
    }

    /// 马赛克：先缩小（每个方块取平均色），再不插值地放大回原尺寸
    private func mosaic(_ rect: CGRect, block: CGFloat) -> CGImage? {
        guard let source = base.crop(rect) else { return nil }
        let blockPixels = max(1, block * base.scale)
        let smallWidth = max(1, Int((CGFloat(source.width) / blockPixels).rounded(.up)))
        let smallHeight = max(1, Int((CGFloat(source.height) / blockPixels).rounded(.up)))
        let space = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let small = CGContext(data: nil, width: smallWidth, height: smallHeight, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        small.interpolationQuality = .medium
        small.draw(source, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let reduced = small.makeImage(),
              let large = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        large.interpolationQuality = .none
        large.draw(reduced, in: CGRect(x: 0, y: 0, width: CGFloat(smallWidth) * blockPixels,
                                       height: CGFloat(smallHeight) * blockPixels)
                                .offsetBy(dx: 0, dy: CGFloat(source.height) - CGFloat(smallHeight) * blockPixels))
        return large.makeImage()
    }

    /// 高斯模糊（Core Image，GPU 计算）；边缘先向外延伸，避免模糊后四周发黑
    private func blur(_ rect: CGRect, radius: CGFloat) -> CGImage? {
        guard let source = base.crop(rect) else { return nil }
        let input = CIImage(cgImage: source)
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius * base.scale))
            .cropped(to: input.extent)
        return ciContext.createCGImage(output, from: input.extent, format: .BGRA8,
                                            colorSpace: source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: - 输出

    /// 把底图的一块区域连同标注合成一张原生像素图像
    /// - Parameter rect: 画布坐标中的区域（已对齐像素）
    func composite(_ annotations: [Annotation], cropping rect: CGRect) -> CGImage? {
        let pixels = base.pixelRect(for: rect)
        guard !pixels.isEmpty, let source = base.image.cropping(to: pixels) else { return nil }
        let space = base.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // 先按像素 1:1 画底图（不插值，原图像素不变），再按「点」坐标叠加标注
        ctx.interpolationQuality = .none
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        ctx.scaleBy(x: base.scale, y: base.scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.interpolationQuality = .high
        draw(annotations, in: ctx)
        return ctx.makeImage()
    }
}
