import AppKit
import Carbon.HIToolbox
import Testing
@testable import Velos

/// 标注编辑的共用按键（截图界面、编辑窗口都先交给 AnnotationController.handleEditingKey）
@MainActor
@Suite struct AnnotationKeyTests {
    /// 一块 200×200 的空白画布上画好一个矩形 (20,20)–(80,80)，并选中它
    static func controllerWithSelectedRectangle() -> AnnotationController {
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let controller = AnnotationController(base: BaseImage(image: ctx.makeImage()!, scale: 1, canvasHeight: 200))
        controller.canvasBounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        controller.tool = .rectangle
        _ = controller.mouseDown(at: CGPoint(x: 20, y: 20), shift: false)
        controller.mouseDragged(to: CGPoint(x: 80, y: 80), shift: false)
        controller.mouseUp(at: CGPoint(x: 80, y: 80), shift: false)
        // 点在矩形的边上：选中它
        _ = controller.mouseDown(at: CGPoint(x: 20, y: 50), shift: false)
        controller.mouseUp(at: CGPoint(x: 20, y: 50), shift: false)
        return controller
    }

    static func key(_ code: Int, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))!
    }

    @Test func 准备好选中的矩形() {
        let controller = Self.controllerWithSelectedRectangle()
        #expect(controller.document.annotations.count == 1)
        #expect(controller.hasSelection)
    }

    @Test func 方向键移动1点Shift移动10点() throws {
        let controller = Self.controllerWithSelectedRectangle()
        let before = try #require(controller.selectedAnnotation?.bounds)
        #expect(controller.handleEditingKey(Self.key(kVK_RightArrow)) == true)
        #expect(controller.handleEditingKey(Self.key(kVK_UpArrow, .shift)) == true)
        let after = try #require(controller.selectedAnnotation?.bounds)
        #expect(after.minX == before.minX + 1)
        #expect(after.minY == before.minY + 10)
    }

    /// 截图界面和编辑窗口统一：按着 ⌘ / ⌥ / ⌃ 的方向键不移动标注（返回 false：是标注按键但没起作用）
    @Test func 按着Command的方向键不移动标注() throws {
        let controller = Self.controllerWithSelectedRectangle()
        let before = try #require(controller.selectedAnnotation?.bounds)
        #expect(controller.handleEditingKey(Self.key(kVK_LeftArrow, .command)) == false)
        #expect(controller.handleEditingKey(Self.key(kVK_LeftArrow, .option)) == false)
        #expect(controller.selectedAnnotation?.bounds == before)
    }

    @Test func 没有选中时方向键交给宿主() {
        let controller = Self.controllerWithSelectedRectangle()
        controller.deselect()
        #expect(controller.handleEditingKey(Self.key(kVK_RightArrow)) == nil)
    }

    @Test func Esc先取消选中再交给宿主() {
        let controller = Self.controllerWithSelectedRectangle()
        #expect(controller.handleEditingKey(Self.key(kVK_Escape)) == true)
        #expect(!controller.hasSelection)
        #expect(controller.handleEditingKey(Self.key(kVK_Escape)) == nil)
    }

    @Test func Delete删除选中的标注可以撤销() {
        let controller = Self.controllerWithSelectedRectangle()
        #expect(controller.handleEditingKey(Self.key(kVK_Delete)) == true)
        #expect(controller.document.isEmpty)
        #expect(controller.handleEditingKey(Self.key(kVK_Delete)) == false)   // 没有选中：没起作用
        #expect(controller.handleEditingKey(Self.key(kVK_ANSI_Z, .command)) == true)
        #expect(controller.document.annotations.count == 1)
        #expect(controller.handleEditingKey(Self.key(kVK_ANSI_Z, [.command, .shift])) == true)
        #expect(controller.document.isEmpty)
    }

    @Test func 其他按键交给宿主() {
        let controller = Self.controllerWithSelectedRectangle()
        #expect(controller.handleEditingKey(Self.key(kVK_Return)) == nil)
        #expect(controller.handleEditingKey(Self.key(kVK_ANSI_S, .command)) == nil)
        #expect(controller.handleEditingKey(Self.key(kVK_ANSI_C)) == nil)
    }

    @Test func 方向键步长() {
        #expect(ArrowKey.step([]) == 1)
        #expect(ArrowKey.step(.shift) == 10)
        #expect(ArrowKey.step([.command]) == nil)
        #expect(ArrowKey.step([.shift, .control]) == nil)
        #expect(ArrowKey.direction(UInt16(kVK_DownArrow))! == (0, -1))
        #expect(ArrowKey.direction(UInt16(kVK_ANSI_A)) == nil)
    }
}
