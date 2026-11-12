import CoreGraphics
import Testing
@testable import Velos

/// 编辑窗口跟着窗口大小自动缩放时的适配比例
@MainActor
@Suite struct EditorFitTests {
    @Test func 整张放得下取宽高里较小的比例() {
        let m = EditorZoomView.fitMagnification(desk: CGSize(width: 400, height: 300), clip: CGSize(width: 800, height: 450), axis: .all)
        #expect(m == 1.5)
    }

    @Test func 竖着长的长截图按宽度适配() {
        let m = EditorZoomView.fitMagnification(desk: CGSize(width: 400, height: 3000), clip: CGSize(width: 600, height: 500), axis: .width)
        #expect(m == 1.5)
    }

    @Test func 横着长的长截图按高度适配() {
        let m = EditorZoomView.fitMagnification(desk: CGSize(width: 3000, height: 200), clip: CGSize(width: 600, height: 100), axis: .height)
        #expect(m == 0.5)
    }

    @Test func 空的桌面不出错() {
        #expect(EditorZoomView.fitMagnification(desk: .zero, clip: CGSize(width: 10, height: 10), axis: .all) == 1)
    }

    /// 截窗口时四角是透明的圆角：量出圆角半径，投影按这个圆角画（不在四角露出方块）
    @Test func 量出图片透明圆角的半径() throws {
        func image(cornerRadius r: CGFloat) -> CGImage? {
            let ctx = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx?.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 200, height: 120), cornerWidth: r, cornerHeight: r, transform: nil))
            ctx?.fillPath()
            return ctx?.makeImage()
        }
        let rounded = try #require(image(cornerRadius: 24))
        let measured = EditorDesk.transparentCornerRadius(of: rounded)
        #expect(abs(measured - 24) <= 4, "量出 \(measured)")
        let square = try #require(image(cornerRadius: 0))
        #expect(EditorDesk.transparentCornerRadius(of: square) == 0)
    }
}
