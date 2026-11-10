import AppKit

/// 选区界面（截图、截屏翻译、录屏选区）期间的前台 App 管理：
/// 1. 记下开始前正在用的 App，结束后把焦点还给它
/// 2. 把 Velos 切到前台（前台 App 才能显示十字准星）
/// 3. 成为前台之后，如果被别的 App 抢走前台（⌘Tab、弹窗），通知调用方——键盘已经到不了选区界面，应该取消，免得遮罩卡在屏幕上
///
/// 判断前台用 NSWorkspace 的通知，不用 NSApp.isActive：不激活面板成为焦点窗口后它也会返回 true，但系统前台其实还是原来的 App
@MainActor
final class FrontmostAppGuard {
    private let previousApp: NSRunningApplication?
    private var token: NSObjectProtocol?
    private var isWatchingDeactivation = false

    /// 在选区界面出现前创建：记下当前的前台 App
    init() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == .current ? nil : frontmost
    }

    /// Velos 是否真的是系统前台 App
    var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication == .current }

    /// 切到前台。由快捷键触发时系统会同意（macOS 14 起是「协作式激活」，没有用户操作时可能被拒绝；
    /// 被拒绝时遮罩仍是焦点窗口，键盘操作不受影响，只是指针保持箭头）
    /// - Parameters:
    ///   - onActivated: Velos 第一次成为前台（这时可以设置十字准星）
    ///   - onLost: 成为前台之后，别的 App 抢走了前台
    func activate(onActivated: @escaping () -> Void, onLost: @escaping (NSRunningApplication) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app else { return }
                if app == .current {
                    guard !self.isWatchingDeactivation else { return }
                    self.isWatchingDeactivation = true
                    onActivated()
                } else if self.isWatchingDeactivation {
                    onLost(app)
                }
            }
        }
        NSApp.activate()
    }

    /// 不再监听前台变化（选区界面关闭时）
    func stopWatching() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }

    /// 把焦点还给开始前正在用的 App
    func restorePreviousApp() {
        guard isFrontmost, let previousApp, !previousApp.isTerminated else { return }
        NSApp.yieldActivation(to: previousApp)
        previousApp.activate(from: .current, options: [])
    }
}
