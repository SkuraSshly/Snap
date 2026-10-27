import AppKit

/// 十字准星旁的放大镜：放大显示光标周围的像素，下方显示像素坐标和颜色值。
///
/// 放大画面：从冻结底图裁出光标周围 15×15 个像素，关闭插值后画到一张小位图上（约 0.2MB），
/// 每个像素都是边缘锐利的方块。自己画而不是依赖图层的放大过滤器，任何渲染路径下效果都一致。
final class MagnifierView: NSView {
    /// 放大区域横竖各显示多少个像素（奇数，正中间是光标所在的像素）
    static let pixelsAcross = 15
    /// 每个像素放大后的边长（点）
    static let pointsPerPixel: CGFloat = 8

    private static let zoomSide = CGFloat(pixelsAcross) * pointsPerPixel   // 120
    private static let padding: CGFloat = 7
    private static let infoHeight: CGFloat = 40

    /// 温暖磨砂的卡片底（虚化下面冻结的画面）
    private let panel = FrostedPanel(cornerRadius: 16, blending: .withinWindow, shadowRadius: 10)
    private let zoomView = NSView()
    private let zoomLayer = CALayer()
    private let crosshairLayer = CAShapeLayer()
    private let centerBoxLayer = CAShapeLayer()
    private let swatchView = NSView()
    private let coordinateLabel = NSTextField(labelWithString: "")
    private let colorLabel = NSTextField(labelWithString: "")

    /// 上次绘制的图像和像素位置：光标在同一个像素内移动时不重画
    private var lastImage: CGImage?
    private var lastPixel: (x: Int, y: Int)?
    private var currentHex = ""
    /// 按 C 复制的颜色值；光标移到别的像素后清除
    private var copiedHex: String?

    init() {
        let side = Self.zoomSide
        super.init(frame: NSRect(x: 0, y: 0, width: side + Self.padding * 2,
                                 height: side + Self.padding * 2 + Self.infoHeight))
        wantsLayer = true
        panel.frame = bounds
        addSubview(panel)

        // 放大区域：圆角，超出屏幕边缘的部分显示为深暖色
        zoomView.frame = CGRect(x: Self.padding, y: Self.infoHeight + Self.padding, width: side, height: side)
        zoomView.wantsLayer = true
        if let container = zoomView.layer {
            container.backgroundColor = NSColor(srgbRed: 0.18, green: 0.14, blue: 0.12, alpha: 1).cgColor
            container.cornerRadius = 10
            container.cornerCurve = .continuous
            container.masksToBounds = true
            container.borderWidth = 1
            container.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor

            zoomLayer.frame = container.bounds
            zoomLayer.contentsGravity = .resize
            container.addSublayer(zoomLayer)

            // 中心十字：贯穿中间一行、一列的杏色半透明条带，帮助对准
            let p = Self.pointsPerPixel
            let center = CGFloat(Self.pixelsAcross / 2) * p
            let bands = CGMutablePath()
            bands.addRect(CGRect(x: center, y: 0, width: p, height: side))
            bands.addRect(CGRect(x: 0, y: center, width: side, height: p))
            crosshairLayer.path = bands
            crosshairLayer.fillColor = WarmPalette.apricot.withAlphaComponent(0.3).cgColor
            container.addSublayer(crosshairLayer)

            // 中心像素的方框：白线 + 深色描边，在任何颜色上都看得清
            centerBoxLayer.path = CGPath(roundedRect: CGRect(x: center, y: center, width: p, height: p),
                                         cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            centerBoxLayer.fillColor = nil
            centerBoxLayer.strokeColor = NSColor.white.cgColor
            centerBoxLayer.lineWidth = 1.5
            centerBoxLayer.shadowColor = NSColor(srgbRed: 0.2, green: 0.12, blue: 0.06, alpha: 1).cgColor
            centerBoxLayer.shadowOpacity = 1
            centerBoxLayer.shadowRadius = 0.6
            centerBoxLayer.shadowOffset = .zero
            container.addSublayer(centerBoxLayer)
        }
        addSubview(zoomView)

        // 信息区：坐标 + 颜色圆点 + 颜色值（暖棕色、圆润等宽数字，移动时不跳动）
        let font = roundedFont(ofSize: 11.5, weight: .semibold, monospacedDigits: true)
        let ink = WarmPalette(for: self).ink
        for label in [coordinateLabel, colorLabel] {
            label.font = font
            label.textColor = ink
            label.lineBreakMode = .byClipping
            addSubview(label)
        }
        coordinateLabel.frame = NSRect(x: Self.padding + 3, y: 22, width: side, height: 15)
        colorLabel.frame = NSRect(x: Self.padding + 21, y: 5, width: side - 18, height: 15)

        swatchView.frame = CGRect(x: Self.padding + 3, y: 6, width: 13, height: 13)
        swatchView.wantsLayer = true
        swatchView.layer?.cornerRadius = 6.5
        swatchView.layer?.borderWidth = 1.5
        swatchView.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        addSubview(swatchView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 不拦截鼠标
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 更新放大内容
    /// - Parameters:
    ///   - image: 冻结的整屏底图
    ///   - pixelX / pixelY: 光标所在像素（以图像左上角为原点）
    ///   - scale: 屏幕缩放倍数（放大位图按这个倍数绘制，Retina 屏上同样锐利）
    ///   - color: 该像素的 sRGB 颜色
    func update(image: CGImage, pixelX: Int, pixelY: Int, scale: CGFloat, color: SRGBColor?) {
        if lastImage === image, let lastPixel, lastPixel == (pixelX, pixelY) { return }
        let pixelChanged = lastPixel.map { $0 != (pixelX, pixelY) } ?? true
        lastImage = image
        lastPixel = (pixelX, pixelY)
        if pixelChanged { copiedHex = nil }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        zoomLayer.contents = Self.renderZoom(of: image, pixelX: pixelX, pixelY: pixelY, scale: scale)
        zoomLayer.contentsScale = scale
        if let color {
            currentHex = color.hex
            swatchView.layer?.backgroundColor = color.cgColor
        }
        CATransaction.commit()

        coordinateLabel.stringValue = "X \(pixelX)   Y \(pixelY)"
        updateColorLabel()
    }

    /// 按 C 复制后的反馈：显示刚复制的值，直到光标移到别的像素
    func showCopied() {
        copiedHex = currentHex
        updateColorLabel()
    }

    private func updateColorLabel() {
        if let copiedHex {
            colorLabel.stringValue = "已复制 \(copiedHex)"
        } else {
            colorLabel.stringValue = "\(currentHex)   C 复制"
        }
    }

    /// 裁出光标周围的像素，关闭插值放大画成一张小位图；超出屏幕边缘的部分是黑色
    private static func renderZoom(of image: CGImage, pixelX: Int, pixelY: Int, scale: CGFloat) -> CGImage? {
        let n = pixelsAcross
        let unit = pointsPerPixel * scale                    // 每个源像素放大后占多少个位图像素
        let side = Int((CGFloat(n) * unit).rounded())
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none                 // 最近邻：每个像素放大成边缘锐利的方块

        // 源像素范围（以图像左上角为原点），裁掉超出图像的部分
        let source = CGRect(x: pixelX - n / 2, y: pixelY - n / 2, width: n, height: n)
        let visible = source.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if !visible.isEmpty, let crop = image.cropping(to: visible) {
            // 位图原点在左下角，源坐标原点在左上角，y 需要翻转
            context.draw(crop, in: CGRect(x: (visible.minX - source.minX) * unit,
                                          y: (source.maxY - visible.maxY) * unit,
                                          width: visible.width * unit,
                                          height: visible.height * unit))
        }
        return context.makeImage()
    }

    /// 放在光标右下方；靠近屏幕边缘时翻到另一侧
    func place(near cursor: CGPoint, in bounds: CGRect) {
        let size = frame.size
        let gap: CGFloat = 22
        var origin = CGPoint(x: cursor.x + gap, y: cursor.y - gap - size.height)
        if origin.x + size.width > bounds.maxX { origin.x = cursor.x - gap - size.width }
        if origin.y < bounds.minY { origin.y = cursor.y + gap }
        setFrameOrigin(CGPoint(x: origin.x.rounded(), y: origin.y.rounded()))
    }
}

/// 8 位 sRGB 颜色
struct SRGBColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}
