import AppKit
import SwiftUI

/// 权限引导窗口：首次运行时自动弹出；缺权限时也会从菜单或截图入口弹出。
/// 窗口关闭后控制器和 SwiftUI 视图一并释放（视图里的轮询计时器也随之停止）。
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private static var current: OnboardingWindowController?
    private let window: NSWindow

    static func show() {
        let controller = current ?? OnboardingWindowController()
        current = controller
        controller.present()
    }

    private override init() {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                          backing: .buffered, defer: true)
        super.init()

        let view = OnboardingView(onDone: { [weak self] in self?.window.close() })
        // NSHostingController 作为内容控制器时，窗口会自动贴合 SwiftUI 内容的尺寸
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "Snap 权限设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    private func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 无论是否授权，关掉窗口都算走完首次引导：之后启动不再自动弹出
        Preferences.shared.hasCompletedOnboarding = true
        Self.current = nil
    }
}
