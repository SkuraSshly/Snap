import AppKit

/// 程序入口。
/// 使用 AppKit 生命周期而不是 SwiftUI 的 `App`：菜单栏程序不需要场景管理，
/// AppKit 方式更轻，窗口什么时候创建、什么时候释放也完全可控（SwiftUI 只用来画界面）。
@main
enum SnapMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Info.plist 已设置 LSUIElement = YES（不出现在程序坞），这里显式再设一次作为保险
        app.setActivationPolicy(.accessory)
        // NSApplication.delegate 是弱引用，必须保证 delegate 在整个运行期间存活
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
