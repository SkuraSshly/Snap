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
}
