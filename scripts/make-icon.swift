// 生成 Snap 的 App 图标：Resources/AppIcon.icns
// 用法：swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Resources/AppIcon.icns
//
// 图形全部用代码绘制（不使用 SF Symbols：其授权不允许用于 App 图标）：
// 杏色到珊瑚色渐变的圆角方块（与界面的温暖风格一致）+ 奶油色取景框四角 + 中间的镜头圆环
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Snap-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, alpha])!
}

/// 以 1024×1024 的坐标绘制，按目标尺寸缩放（矢量绘制，每个尺寸都清晰）
func render(pixels: Int) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)

    // macOS 图标网格：824×824 的主体，四周留 100 的边距
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // 柔和投影
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x5A2E14, 0.30))
    context.addPath(shape)
    context.setFillColor(color(0xF09060))
    context.fillPath()
    context.restoreGState()

    // 渐变：上方浅杏色 → 下方珊瑚色
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: srgb, colors: [color(0xFBBD86), color(0xF5935C), color(0xEC6A4C)] as CFArray,
                              locations: [0, 0.5, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // 顶部一层很淡的高光
    let shine = CGGradient(colorsSpace: srgb, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    context.restoreGState()

    let cream = color(0xFFF8EF)
    context.setStrokeColor(cream)
    context.setFillColor(cream)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    // 取景框四角
    let frame = CGRect(x: 262, y: 262, width: 500, height: 500)
    let arm: CGFloat = 128
    context.setLineWidth(46)
    for (corner, dx, dy) in [(CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0),
                             (CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0), (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0)] {
        context.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        context.addLine(to: corner)
        context.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        context.strokePath()
    }

    // 中间的镜头：圆环 + 实心圆点
    context.setLineWidth(38)
    context.strokeEllipse(in: CGRect(x: 512 - 112, y: 512 - 112, width: 224, height: 224))
    context.fillEllipse(in: CGRect(x: 512 - 50, y: 512 - 50, width: 100, height: 100))
    return context.makeImage()!
}

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let url = iconset.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, render(pixels: points * factor), nil)
        CGImageDestinationFinalize(destination)
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "已生成 \(output.path)" : "iconutil 失败")
