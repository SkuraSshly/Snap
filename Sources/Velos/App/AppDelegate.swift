import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        statusBar = StatusBarController()
        PermissionManager.shared.refresh()
        CaptureCoordinator.shared.start()
        LaunchAtLogin.shared.reregisterIfEnabled()   // 登录项指向正在运行的这一份 App
        ScreenTranslateController.shared.warmUpAllIfNeeded()   // 一次性：让系统预先编译文字识别模型
        DispatchQueue.global(qos: .utility).async { CapturedImage.removeStaleSharingFiles() }
        Log.capture.notice("Velos 已启动，屏幕录制权限：\(PermissionManager.shared.screenRecordingGranted ? "已授权" : "未授权", privacy: .public)")

        // 只有第一次运行才弹出权限引导；之后的每次启动（包括开机自启）都不弹出任何窗口
        if !Preferences.shared.hasCompletedOnboarding {
            OnboardingWindowController.show()
        }

        #if DEBUG
        DebugSnapshots.runIfRequested()
        DebugSnapshots.runSelfTestIfRequested()
        DebugUITest.runIfRequested()
        DebugAutoScrollProbe.runIfRequested()
        DebugAutoScrollE2E.runIfRequested()
        DebugPermissionRequest.runIfRequested()
        DebugRecordingTest.runIfRequested()
        DebugFeatureTest.runIfRequested()
        DebugShowcase.runIfRequested()
        DebugShowcase.runSettingsShotsIfRequested()
        #endif
    }

    /// Velos 已在运行时再次打开它（访达双击、启动台、Spotlight、`open` 命令）会走到这里。
    /// 菜单栏图标被隐藏后，这是除快捷键之外找回设置的唯一入口，所以直接打开设置窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.show()
        return false
    }
}

extension AppDelegate {
    /// 隐藏的主菜单：菜单栏应用不显示菜单栏，但 ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z 这些快捷键要靠「编辑」菜单分发给输入框，
    /// 没有它时设置、翻译结果等窗口里的输入框按快捷键没反应。截图界面、编辑窗口、翻译窗口自己的快捷键会先被它们拦下，不受影响。
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
