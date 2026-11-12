import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Velos

/// 圆角截图：切圆角、保存（PNG / HEIC 透明，JPEG 白底）、按 1x 缩小都保留圆角
@Suite struct CornerRoundingTests {
    /// 一张不透明的纯色图（和截图一样带 alpha 通道、但全部不透明）
    static func solid(width: Int = 120, height: Int = 80) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// 某个像素的 RGBA（x、y 从左上角算）
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return [p[0], p[1], p[2], p[3]]
    }

    static func decode(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    @Test func 切圆角后四角透明中间不变() throws {
        let rounded = try #require(ImageEncoder.rounded(Self.solid(), radius: 16))
        #expect(Self.pixel(rounded, 0, 0)[3] == 0)
        #expect(Self.pixel(rounded, 119, 79)[3] == 0)
        #expect(Self.pixel(rounded, 60, 40)[3] == 255)
        #expect(Self.pixel(rounded, 60, 0)[3] == 255)   // 边的中间不受影响
        #expect(ImageEncoder.hasTransparentCorner(rounded))
        #expect(!ImageEncoder.hasTransparentCorner(Self.solid()))
    }

    @Test func PNG保留透明圆角JPEG圆角外是白色() throws {
        let rounded = try #require(ImageEncoder.rounded(Self.solid(), radius: 16))
        let png = try #require(ImageEncoder.encode(rounded, format: .png, quality: 1, scale: 1).flatMap(Self.decode))
        #expect(Self.pixel(png, 0, 0)[3] == 0)
        let jpeg = try #require(ImageEncoder.encode(rounded, format: .jpeg, quality: 0.9, scale: 1).flatMap(Self.decode))
        let corner = Self.pixel(jpeg, 0, 0)
        #expect(corner[3] == 255 && corner[0] > 240 && corner[1] > 240 && corner[2] > 240, "\(corner)")
    }

    @Test func 普通截图照旧去掉透明通道() throws {
        let png = try #require(ImageEncoder.encode(Self.solid(), format: .png, quality: 1, scale: 1).flatMap(Self.decode))
        #expect([.none, .noneSkipFirst, .noneSkipLast].contains(png.alphaInfo))
    }

    @Test func 按1x缩小后圆角仍然透明() throws {
        let rounded = try #require(ImageEncoder.rounded(Self.solid(width: 240, height: 160), radius: 32))
        let small = try #require(ImageEncoder.downscaled(rounded, by: 2))
        #expect(small.width == 120 && Self.pixel(small, 0, 0)[3] == 0 && Self.pixel(small, 60, 40)[3] == 255)
    }
}
