// 生成 App 图标：Resources/AppIcon.icns
// 用法：swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Resources/AppIcon.icns [预览.png]
//
// 图形全部用代码绘制（不用 SF Symbols、不用字体：授权不允许用于 App 图标），只用系统自带的 Core Graphics / Core Image：
// 纸白底 + 几团很淡的水彩色雾 + 两条半透明、虚化的薄纱 + 前倾的「V」（Velos 在希腊语里是「箭」：左刃细、右刃粗，
// 多段渐变的半透明玻璃片，背后一层柔光）+ 一道带辉光的扫描线（截图 / 识别文字）+ 箭尖和扫描线附近的光点 + 极细的纸面颗粒。
// 最上面叠一个截图选区：选区里那块画面像刚截下来一样浮起来（带白边和投影），原位置留虚线框和控制点，旁边一个十字光标。
// 菜单栏图标是同一个前倾的 V（Sources/Velos/UI/VelosIcons.swift 里的 VelosMark）。
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                           CGFloat(hex & 0xFF) / 255, alpha])!
}
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
}
let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

/// 固定种子的伪随机数（每次生成的图标一模一样）
struct Random {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
    }
}

// MARK: - 形状（1024 坐标系，y 向上）

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

/// 前倾的 V：两片刃（左细右粗），整体绕中心顺时针转约 6°
let vTransform = CGAffineTransform(translationX: 512, y: 512).rotated(by: -0.10).translatedBy(x: -512, y: -512)
let tip = CGPoint(x: 486, y: 246)
func polygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points, transform: vTransform)
    path.closeSubpath()
    return path
}
let leftBlade = polygon([CGPoint(x: 268, y: 752), CGPoint(x: 344, y: 752), CGPoint(x: tip.x + 36, y: tip.y + 14), tip])
let rightBlade = polygon([CGPoint(x: 676, y: 800), CGPoint(x: 790, y: 800), CGPoint(x: tip.x + 52, y: tip.y + 4), tip])
/// 右刃顶端（光点从这里散开）
let arrowHead = CGPoint(x: 733, y: 800).applying(vTransform)
let scanY: CGFloat = 511

/// 薄纱：一条两侧用贝塞尔曲线围成的弧形带
func gauze(from a: CGPoint, to b: CGPoint, bend: CGFloat, thickness: CGFloat) -> CGPath {
    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + bend)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: a.x, y: a.y + thickness * 0.15))
    path.addQuadCurve(to: CGPoint(x: b.x, y: b.y + thickness * 0.15), control: CGPoint(x: mid.x, y: mid.y + thickness))
    path.addLine(to: CGPoint(x: b.x, y: b.y - thickness * 0.15))
    path.addQuadCurve(to: CGPoint(x: a.x, y: a.y - thickness * 0.15), control: CGPoint(x: mid.x, y: mid.y - thickness * 0.4))
    path.closeSubpath()
    return path
}

// MARK: - 绘制

/// 在一张和目标同尺寸的透明图层上画，然后高斯模糊（radius 按 1024 坐标）
func blurredLayer(pixels: Int, radius: CGFloat, _ draw: (CGContext) -> Void) -> CGImage {
    let scale = CGFloat(pixels) / 1024
    let layer = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    layer.scaleBy(x: scale, y: scale)
    draw(layer)
    let input = CIImage(cgImage: layer.makeImage()!)
    let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(radius * scale)).cropped(to: input.extent)
    return CIContext(options: [.workingColorSpace: srgb]).createCGImage(blurred, from: input.extent)!
}

/// 画面本身（纸白底、色雾、薄纱、V、扫描线、光点、颗粒），裁成圆角方块；截图选区在 render 里叠上去
func scene(pixels: Int) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let small = pixels <= 64   // 很小：线条再加粗
    // 128 像素及以下（访达、程序坞、设置侧栏里看到的大小）用「清晰版」：不要薄纱、柔光、粒子、颗粒这些会糊成一片的细节，
    // 两片刃不透明、颜色更饱和，扫描线加粗——缩小后依然轮廓分明
    let simple = pixels <= 128

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // 1. 纸白底（清晰版底色稍深一点，和 V 拉开对比）
    context.drawLinearGradient(simple ? gradient([color(0xFBF5EE), color(0xF2E7DB), color(0xE6D7C7)], [0, 0.55, 1])
                                      : gradient([color(0xFDFAF5), color(0xF6EEE4), color(0xEDE2D6)], [0, 0.55, 1]),
                               start: CGPoint(x: 260, y: 924), end: CGPoint(x: 760, y: 100), options: extend)

    // 2. 水彩色雾：几团很淡的颜色，模糊后叠上去
    context.draw(blurredLayer(pixels: pixels, radius: 90) { layer in
        for (center, radius, hex, alpha) in [(CGPoint(x: 760, y: 760), 260.0, 0xFFC7A8, 0.55),   // 右上 蜜桃
                                             (CGPoint(x: 330, y: 330), 230.0, 0xE4D2F0, 0.55),   // 左下 淡紫
                                             (CGPoint(x: 620, y: 360), 200.0, 0xFFB08A, 0.35),   // 中下 杏
                                             (CGPoint(x: 300, y: 780), 180.0, 0xFFE6C8, 0.55)] { // 左上 香槟
            layer.setFillColor(color(UInt32(hex), CGFloat(alpha)))
            layer.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
    }, in: full)

    // 3. 薄纱：两条半透明弧形带，从 V 后面斜穿过去，虚化
    if !simple {
    context.draw(blurredLayer(pixels: pixels, radius: 14) { layer in
        for (path, from, to) in [(gauze(from: CGPoint(x: 60, y: 300), to: CGPoint(x: 980, y: 700), bend: -40, thickness: 150),
                                  color(0xFFFFFF, 0.15), color(0xFFC9AE, 0.75)),
                                 (gauze(from: CGPoint(x: 40, y: 640), to: CGPoint(x: 990, y: 420), bend: 60, thickness: 110),
                                  color(0xE6D6F5, 0.70), color(0xFFF3EA, 0.15))] {
            layer.saveGState()
            layer.addPath(path)
            layer.clip()
            layer.drawLinearGradient(gradient([from, to], [0, 1]), start: CGPoint(x: 60, y: 0), end: CGPoint(x: 980, y: 0), options: extend)
            layer.restoreGState()
            // 纱的一条亮边
            layer.addPath(path)
            layer.setStrokeColor(color(0xFFFFFF, 0.45))
            layer.setLineWidth(2)
            layer.strokePath()
        }
    }, in: full)
    }
    // 纱上的细丝：几根很细的曲线，轻微虚化，像薄纱的织纹
    if !simple {
        context.draw(blurredLayer(pixels: pixels, radius: 1.2) { layer in
            layer.setLineWidth(1.6)
            for i in 0..<9 {
                let k = CGFloat(i) / 8
                layer.setStrokeColor(color(0xFFFFFF, 0.22 + 0.25 * (1 - abs(k - 0.5) * 2)))
                layer.move(to: CGPoint(x: 60, y: 300 - 18 + k * 36))
                layer.addQuadCurve(to: CGPoint(x: 980, y: 700 - 18 + k * 36), control: CGPoint(x: 520, y: 460 + 40 + k * 120))
                layer.strokePath()
                layer.move(to: CGPoint(x: 40, y: 640 - 14 + k * 28))
                layer.addQuadCurve(to: CGPoint(x: 990, y: 420 - 14 + k * 28), control: CGPoint(x: 515, y: 590 + k * 90))
                layer.strokePath()
            }
        }, in: full)
    }

    // 4. V 背后的柔光
    if !simple {
        context.draw(blurredLayer(pixels: pixels, radius: 40) { layer in
            layer.setFillColor(color(0xF58A5E, 0.45))
            layer.addPath(leftBlade); layer.addPath(rightBlade)
            layer.fillPath()
        }, in: full.offsetBy(dx: 0, dy: -14))
    }

    // 5. 两片刃：多段渐变、略透明，叠在一起的地方更深
    func blade(_ path: CGPath, _ colors: [UInt32], alpha: CGFloat) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setAlpha(alpha)
        let box = path.boundingBoxOfPath
        context.drawLinearGradient(gradient(colors.map { color($0) }, [0, 0.35, 0.7, 1]),
                                   start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: extend)
        // 一侧的高光（玻璃的厚度感）
        context.setAlpha(1)
        context.drawLinearGradient(gradient([color(0xFFFFFF, 0.45), color(0xFFFFFF, 0)], [0, 1]),
                                   start: CGPoint(x: box.minX, y: box.midY), end: CGPoint(x: box.minX + box.width * 0.45, y: box.midY),
                                   options: [])
        context.restoreGState()
        context.addPath(path)
        context.setStrokeColor(color(0xFFFFFF, 0.7))
        context.setLineWidth(simple ? 0 : 2.5)
        context.strokePath()
    }
    if simple {
        blade(leftBlade, [0xFFD3AE, 0xFDB083, 0xF88E63, 0xEE714F], alpha: 1)
        blade(rightBlade, [0xFFA27A, 0xF7784F, 0xE8544D, 0xC93A4E], alpha: 1)
    } else {
        // 和清晰版同样饱和的颜色，只留一点点透明，让后面的薄纱隐约透出来
        blade(leftBlade, [0xFFD3AE, 0xFDB083, 0xF88E63, 0xEE714F], alpha: 0.94)
        blade(rightBlade, [0xFFA27A, 0xF7784F, 0xE8544D, 0xC93A4E], alpha: 0.95)
    }

    // 6. 扫描线：一道细亮线 + 虚化的辉光
    if !simple {
    context.draw(blurredLayer(pixels: pixels, radius: 12) { layer in
        layer.clip(to: CGRect(x: 120, y: scanY - 10, width: 784, height: 20))
        layer.drawLinearGradient(gradient([color(0xFF9C78, 0), color(0xFF9C78, 0.8), color(0xFF9C78, 0)], [0, 0.55, 1]),
                                 start: CGPoint(x: 120, y: 0), end: CGPoint(x: 904, y: 0), options: [])
    }, in: full)
    }
    let lineHeight: CGFloat = small ? 14 : (simple ? 8 : 3.6)
    context.saveGState()
    context.clip(to: CGRect(x: 130, y: scanY - lineHeight / 2, width: 764, height: lineHeight))
    context.drawLinearGradient(gradient([color(0xE2673F, 0), color(0xE2673F, 0.95), color(0xFFF4EA, 1), color(0xE2673F, 0.9), color(0xE2673F, 0)],
                                        [0, 0.35, 0.55, 0.75, 1]),
                               start: CGPoint(x: 130, y: 0), end: CGPoint(x: 894, y: 0), options: [])
    context.restoreGState()

    if !simple {
        // 7. 光点：沿扫描线和从箭尖散开，大小、透明度各不相同；大的几颗带一点虚光
        var random = Random(state: 20261109)
        var dots: [(CGPoint, CGFloat, CGFloat, UInt32)] = []
        for _ in 0..<46 {   // 扫描线附近
            let x = 150 + random.next() * 724
            let y = scanY + (random.next() - 0.5) * 70 * (0.3 + random.next())
            dots.append((CGPoint(x: x, y: y), 2.0 + random.next() * 4.0, 0.35 + random.next() * 0.55,
                         random.next() < 0.5 ? 0xFFFFFF : 0xF58A5E))
        }
        for i in 0..<34 {   // 从箭尖向左上散开，越远越小越淡
            let distance = 14 + CGFloat(i) * 2.4 + random.next() * 16
            let angle = 2.35 + (random.next() - 0.5) * 1.2
            let p = CGPoint(x: arrowHead.x + cos(angle) * distance, y: arrowHead.y + sin(angle) * distance)
            let fade = 1 - distance / 120
            dots.append((p, (2.2 + random.next() * 4.8) * (0.5 + fade), max(0.12, fade) * (0.5 + random.next() * 0.5),
                         random.next() < 0.6 ? 0xFFFFFF : 0xF79A70))
        }
        context.draw(blurredLayer(pixels: pixels, radius: 4) { layer in
            for (p, r, a, hex) in dots where r > 3 {
                layer.setFillColor(color(hex, a))
                layer.fillEllipse(in: CGRect(x: p.x - r * 2.2, y: p.y - r * 2.2, width: r * 4.4, height: r * 4.4))
            }
        }, in: full)
        for (p, r, a, hex) in dots {
            context.setFillColor(color(hex, a))
            context.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }

        // 8. 极细的纸面颗粒
        var grain = Random(state: 7)
        let step: CGFloat = 1024 / CGFloat(pixels) * 2
        var y: CGFloat = 100
        while y < 924 {
            var x: CGFloat = 100
            while x < 924 {
                let v = grain.next()
                if v > 0.55 {
                    context.setFillColor(v > 0.8 ? color(0x7A5A48, 0.045) : color(0xFFFFFF, 0.08))
                    context.fill(CGRect(x: x, y: y, width: step, height: step))
                }
                x += step
            }
            y += step
        }
    }
    context.restoreGState()
    return context.makeImage()!
}

/// 截图选区（1024 坐标系）：框住 V 的右刃和扫描线相交的地方
let selection = CGRect(x: 446, y: 352, width: 352, height: 300)
/// 截下来的那一块浮起来：往左上挪一点、放大一点
let liftOffset = CGPoint(x: -26, y: 30)
let liftScale: CGFloat = 1.06

/// 一个十字光标（截图时的样子）：珊瑚色细十字，外面一圈白色柔光，中间留空
/// weight：线宽（小尺寸图标加粗，缩小后依然看得清）
func drawCrosshair(_ context: CGContext, at p: CGPoint, size: CGFloat, weight: CGFloat = 4) {
    let arm = size / 2, gap = weight * 1.8
    let path = CGMutablePath()
    path.move(to: CGPoint(x: p.x - arm, y: p.y)); path.addLine(to: CGPoint(x: p.x - gap, y: p.y))
    path.move(to: CGPoint(x: p.x + gap, y: p.y)); path.addLine(to: CGPoint(x: p.x + arm, y: p.y))
    path.move(to: CGPoint(x: p.x, y: p.y - arm)); path.addLine(to: CGPoint(x: p.x, y: p.y - gap))
    path.move(to: CGPoint(x: p.x, y: p.y + gap)); path.addLine(to: CGPoint(x: p.x, y: p.y + arm))
    context.setLineCap(.round)
    // 柔和的白色光晕 + 和虚线框同色的珊瑚色细线（不用系统那种黑十字，免得在浅色画面里太硬）
    context.saveGState()
    context.setShadow(offset: .zero, blur: 10, color: color(0xFFFFFF, 0.9))
    context.addPath(path); context.setStrokeColor(color(0xFFFFFF, 0.9)); context.setLineWidth(weight * 2.3); context.strokePath()
    context.restoreGState()
    context.addPath(path); context.setStrokeColor(color(0xE2673F)); context.setLineWidth(weight); context.strokePath()
}

/// 图标：画面 + 截图选区；原位置留虚线框和控制点；
/// 选区里那块画面像刚截下来的截图一样浮起来（清晰、带白边和投影）；右下角一个截图十字光标
func render(pixels: Int) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let small = pixels <= 64
    let simple = pixels <= 128   // 清晰版：选区外不虚化，虚线和控制点加粗，不画十字光标
    let crisp = scene(pixels: pixels)

    // 投影
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x5A3A2A, 0.22))
    context.addPath(shape)
    context.setFillColor(color(0xF3ECE3))
    context.fillPath()
    context.restoreGState()

    // 1. 选区外：原样的画面
    context.saveGState()
    context.addPath(shape)
    context.clip()
    // 选区外不虚化、不蒙白纱，任何尺寸都保持锐利；浮起来的那块靠白边和投影突出
    context.draw(crisp, in: full)


    // 2. 原位置：选区里留一点暗影（被截走的地方），一圈虚线框，四角控制点
    context.setFillColor(color(0x6A3A2A, 0.06))
    context.fill(selection)
    if !small {
        context.setLineWidth(simple ? 10 : 4)
        context.setStrokeColor(color(0xFFFFFF, 0.95))
        context.stroke(selection)
        context.setLineDash(phase: 0, lengths: simple ? [30, 22] : [16, 12])
        context.setStrokeColor(color(0xE2673F))
        context.stroke(selection)
        context.setLineDash(phase: 0, lengths: [])
        for x in [selection.minX, selection.maxX] {
            for y in [selection.minY, selection.maxY] {
                let r: CGFloat = simple ? 20 : 11
                let dot = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                context.setFillColor(color(0xFFFFFF)); context.fillEllipse(in: dot)
                context.setStrokeColor(color(0xE2673F)); context.setLineWidth(simple ? 8 : 4); context.strokeEllipse(in: dot)
            }
        }
    }

    // 3. 浮起来的那一块：清晰的画面，白边 + 投影
    let lifted = CGRect(x: selection.midX + liftOffset.x - selection.width * liftScale / 2,
                        y: selection.midY + liftOffset.y - selection.height * liftScale / 2,
                        width: selection.width * liftScale, height: selection.height * liftScale)
    let card = CGPath(roundedRect: lifted, cornerWidth: 20, cornerHeight: 20, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 38, color: color(0x5A2A1C, 0.38))
    context.addPath(card); context.setFillColor(color(0xFFFFFF)); context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(card)
    context.clip()
    // 把选区里的画面放大、平移到卡片上（内容和原位置一一对应）
    context.translateBy(x: lifted.minX, y: lifted.minY)
    context.scaleBy(x: liftScale, y: liftScale)
    context.translateBy(x: -selection.minX, y: -selection.minY)
    context.draw(crisp, in: full)
    context.restoreGState()
    context.addPath(card)
    context.setStrokeColor(color(0xFFFFFF))
    context.setLineWidth(small ? 16 : (simple ? 11 : 7))
    context.strokePath()

    // 4. 十字光标：停在选区右下角（刚拖完选区的位置）；小尺寸加大加粗
    if small {
        drawCrosshair(context, at: CGPoint(x: selection.maxX + 44, y: selection.minY - 44), size: 120, weight: 22)
    } else if simple {
        drawCrosshair(context, at: CGPoint(x: selection.maxX + 40, y: selection.minY - 40), size: 104, weight: 12)
    } else {
        drawCrosshair(context, at: CGPoint(x: selection.maxX + 34, y: selection.minY - 34), size: 74)
    }
    context.restoreGState()

    // 内沿一圈细高光
    context.addPath(CGPath(roundedRect: body.insetBy(dx: 2.5, dy: 2.5), cornerWidth: 182, cornerHeight: 182, transform: nil))
    context.setStrokeColor(color(0xFFFFFF, 0.75))
    context.setLineWidth(small ? 0 : 4)
    context.strokePath()
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
if CommandLine.arguments.count > 2 {
    writePNG(render(pixels: 1024), to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        writePNG(render(pixels: points * factor), to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "已生成 \(output.path)" : "iconutil 失败")
