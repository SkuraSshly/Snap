import CoreGraphics
import Testing
@testable import Velos

/// 截图界面的标注工具栏位置
@Suite struct ToolbarPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 300, height: 40)

    @Test func 放在选区下方右对齐() {
        let origin = ToolbarPlacement.origin(size: size, selection: CGRect(x: 200, y: 300, width: 400, height: 200), in: screen)
        #expect(origin == CGPoint(x: 300, y: 300 - 8 - 40))
    }

    @Test func 下方放不下时放到上方并让出尺寸标签() {
        let origin = ToolbarPlacement.origin(size: size, selection: CGRect(x: 200, y: 20, width: 400, height: 200), in: screen)
        #expect(origin.y == CGFloat(220 + 8 + 22))
    }

    @Test func 上下都放不下时放在选区内底部() {
        let origin = ToolbarPlacement.origin(size: size, selection: CGRect(x: 200, y: 10, width: 400, height: 770), in: screen)
        #expect(origin.y == CGFloat(10 + 8))
    }

    @Test func 全屏模式在底部中央() {
        #expect(ToolbarPlacement.origin(size: size, selection: nil, in: screen) == CGPoint(x: 350, y: 28))
    }

    @Test func 左右不超出屏幕() {
        let left = ToolbarPlacement.origin(size: size, selection: CGRect(x: 0, y: 300, width: 100, height: 100), in: screen)
        #expect(left.x == CGFloat(4))
        let right = ToolbarPlacement.origin(size: size, selection: CGRect(x: 900, y: 300, width: 200, height: 100), in: screen)
        #expect(right.x == CGFloat(1000 - 300 - 4))
    }
}
