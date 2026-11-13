import CoreGraphics
import Testing
@testable import Velos

/// 钉图默认的位置和大小：原始大小、钉在原位；比屏幕大才缩小
@MainActor
@Suite struct PinFrameTests {
    /// 一块 1440×900 点的屏幕，上面 32 点是菜单栏，下面 70 点是程序坞
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = CGRect(x: 0, y: 70, width: 1440, height: 798)

    @Test func 普通截图原大小钉在原位() {
        let source = CGRect(x: 300, y: 200, width: 500, height: 300)
        #expect(PinManager.pinFrame(size: source.size, source: source, screen: screen, visible: visible) == source)
    }

    @Test func 很大的截图也是原大小只要在屏幕里() {
        // 以前超过屏幕 80% 就缩到 60%；现在只要放得下就原大小、原位
        let source = CGRect(x: 20, y: 80, width: 1300, height: 780)
        #expect(PinManager.pinFrame(size: source.size, source: source, screen: screen, visible: visible) == source)
        // 全屏截图：原大小盖满整块屏幕
        #expect(PinManager.pinFrame(size: screen.size, source: screen, screen: screen, visible: visible) == screen)
    }

    @Test func 比屏幕还大才缩小到正好放得下() {
        // 例如在更大的外接屏上截的图，钉到这块屏幕上
        let size = CGSize(width: 2880, height: 1800)
        let frame = PinManager.pinFrame(size: size, source: CGRect(origin: .zero, size: size), screen: screen, visible: visible)
        #expect(frame.width <= visible.width && frame.height <= visible.height && visible.contains(frame))
        #expect(abs(frame.width / frame.height - size.width / size.height) < 0.01)   // 长宽比不变
    }

    @Test func 长截图原宽度钉在原位只露出一段() {
        // 选区左上角在 (400, 800)，拼出来 600 × 5000 点
        let size = CGSize(width: 600, height: 5000)
        let source = CGRect(x: 400, y: 300, width: 600, height: 500)   // 开头那一屏的位置
        let frame = PinManager.pinFrame(size: size, source: source, screen: screen, visible: visible)
        #expect(frame.width == 600, "原宽度")
        #expect(frame.height <= (visible.height * 0.85).rounded() && frame.height > 500, "只露出一段：\(frame.height)")
        #expect(frame.minX == 400, "左边和原位对齐")
        #expect(visible.contains(frame), "\(frame)")
    }
}
