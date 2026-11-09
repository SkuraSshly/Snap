import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        PermissionManager.shared.refresh()
        CaptureCoordinator.shared.start()
        LaunchAtLogin.shared.reregisterIfEnabled()   // 登录项指向正在运行的这一份 App
        ScreenTranslateController.shared.warmUpAllIfNeeded()   // 一次性：让系统预先编译文字识别模型
        DispatchQueue.global(qos: .utility).async { CapturedImage.removeStaleSharingFiles() }
        Log.capture.notice("Snap 已启动，屏幕录制权限：\(PermissionManager.shared.screenRecordingGranted ? "已授权" : "未授权", privacy: .public)")

        // 只有第一次运行才弹出权限引导；之后的每次启动（包括开机自启）都不弹出任何窗口
        if !Preferences.shared.hasCompletedOnboarding {
            OnboardingWindowController.show()
        }

        #if DEBUG
        DebugSnapshots.runIfRequested()
        DebugSnapshots.runSelfTestIfRequested()
        DebugUITest.runIfRequested()
        DebugAutoScrollProbe.runIfRequested()
        DebugRecordingTest.runIfRequested()
        DebugFeatureTest.runIfRequested()
        DebugShowcase.runIfRequested()
        DebugShowcase.runSettingsShotsIfRequested()
        #endif
    }

    /// Snap 已在运行时再次打开它（访达双击、启动台、Spotlight、`open` 命令）会走到这里。
    /// 菜单栏图标被隐藏后，这是除快捷键之外找回设置的唯一入口，所以直接打开设置窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.show()
        return false
    }
}
