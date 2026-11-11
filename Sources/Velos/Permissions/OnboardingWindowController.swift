import AppKit
import SwiftUI

/// 权限引导窗口：首次运行时自动弹出；缺权限时也会从菜单或截图入口弹出。
/// 独立打开时放在屏幕正中间；从设置窗口打开时作为二级窗口，放在设置窗口正中间、跟着设置窗口移动。
/// 窗口关闭后控制器和 SwiftUI 视图一并释放（视图里的轮询计时器也随之停止）。
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private static var current: OnboardingWindowController?
    private let window: NSWindow

    /// - Parameter parent: 传入时作为它的二级窗口，放在它正中间（例如从设置窗口打开）
    static func show(over parent: NSWindow? = nil) {
        if let controller = current {
            controller.present(over: parent)
            return
        }
        let controller = OnboardingWindowController()
        current = controller
        controller.present(over: parent)
    }

    private override init() {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        super.init()

        let view = OnboardingView(onDone: { [weak self] in self?.finish() })
        // NSHostingController 作为内容控制器时，窗口会自动贴合 SwiftUI 内容的尺寸
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "Velos 权限设置"
        window.identifier = .velosCapturable
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.followActiveSpace()
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    private func present(over parent: NSWindow?) {
        // 先让窗口按内容定好大小，才能算出居中的位置（SwiftUI 的尺寸要等一轮刷新才报上来，这里直接量）
        if let view = window.contentViewController?.view {
            let size = view.fittingSize
            if size.width > 0, size.height > 0 { window.setContentSize(size) }
        }
        let wasVisible = window.isVisible
        window.bringToFront()
        // 窗口第一次显示时系统会自己定位置，所以显示之后再摆（同一轮刷新里完成，不会看到窗口跳动）
        if let parent, parent.isVisible {
            window.center(over: parent)
        } else if !wasVisible {
            window.centerOnScreen()
        }
    }

    /// 点「完成」：关闭窗口
    private func finish() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        window.parent?.removeChildWindow(window)
        Self.didClose()
    }

    /// 无论是否授权，关掉窗口都算走完首次引导：之后启动不再自动弹出
    private static func didClose() {
        Preferences.shared.hasCompletedOnboarding = true
        current = nil
    }

    #if DEBUG
    static var debugWindow: NSWindow? { current?.window }
    #endif
}
