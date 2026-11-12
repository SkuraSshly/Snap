import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 图像编码与缩放（都可以在后台线程调用）。
/// 编码时保留图像自带的色彩空间：ImageIO 会把 Display P3 / sRGB 的 ICC 配置文件写进文件，颜色不偏。
enum ImageEncoder {
    /// 编码成指定格式
    /// - Parameters:
    ///   - quality: 0~1，只对 JPEG / HEIC 有效
    ///   - scale: 每点像素数，写入 DPI（2x 为 144），让其他软件按正确的物理尺寸显示，与系统截图一致
    static func encode(_ image: CGImage, format: ImageFormat, quality: Double, scale: CGFloat) -> Data? {
        let type: UTType = switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // 切了圆角的图四角透明：PNG、HEIC 保留透明；JPEG 不支持透明，圆角外填白色。其他截图本来不透明，去掉 alpha 通道
        let output: CGImage = if hasTransparentCorner(image) {
            format == .jpeg ? (onWhite(image) ?? image) : image
        } else {
            opaque(image) ?? image
        }
        CGImageDestinationAddImage(destination, output, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 去掉 alpha 通道：截图本身完全不透明，但 ScreenCaptureKit 给的图带 alpha，
    /// 直接编码会让 PNG 多存一个通道（体积约大 25%）。按原尺寸、原色彩空间、不插值地逐像素复制，结果完全一致。
    static func opaque(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        guard let context = makeContext(width: image.width, height: image.height, like: image) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// 高质量缩小：用于「按 1x 保存」和缩略图（四角透明的保留透明）
    static func downscaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        guard factor > 1 else { return image }
        let width = max(1, Int((CGFloat(image.width) / factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) / factor).rounded()))
        guard let context = makeContext(width: width, height: height, like: image, alpha: hasTransparentCorner(image))
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 与原图同色彩空间的位图（BGRA）：默认不透明（alpha 位不使用），alpha 为 true 时带透明
    private static func makeContext(width: Int, height: Int, like image: CGImage, alpha: Bool = false) -> CGContext? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = alpha ? CGImageAlphaInfo.premultipliedFirst.rawValue : CGImageAlphaInfo.noneSkipFirst.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: info | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    // MARK: - 圆角

    /// 切成圆角：radius 是像素，圆角外透明
    static func rounded(_ image: CGImage, radius: CGFloat) -> CGImage? {
        guard radius > 0, let context = makeContext(width: image.width, height: image.height, like: image, alpha: true)
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.interpolationQuality = .none
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// 左上角的像素是透明的：切了圆角的截图（普通截图四角都不透明）。只看一个像素，很快
    static func hasTransparentCorner(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        guard let corner = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return data[3] < 250
    }

    /// 铺在白底上（JPEG 不支持透明）
    private static func onWhite(_ image: CGImage) -> CGImage? {
        guard let context = makeContext(width: image.width, height: image.height, like: image) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
