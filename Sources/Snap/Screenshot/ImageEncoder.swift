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
        CGImageDestinationAddImage(destination, opaque(image) ?? image, properties as CFDictionary)
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

    /// 高质量缩小：用于「按 1x 保存」和缩略图
    static func downscaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        guard factor > 1 else { return image }
        let width = max(1, Int((CGFloat(image.width) / factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) / factor).rounded()))
        guard let context = makeContext(width: width, height: height, like: image) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// 与原图同色彩空间的不透明位图（BGRA，alpha 位不使用）
    private static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }
}
