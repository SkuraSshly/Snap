import AppKit
import AVFoundation
import CoreGraphics

/// 统一管理系统权限：
/// - 屏幕与系统录音（必需）：截图、录屏、录制系统声音都依赖它
/// - 麦克风（可选）：只有录屏时录麦克风才需要
/// - 辅助功能（可选）：只有长截图的自动滚动、滚动限速才需要（替别的 App 发送 / 调整滚动事件）
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var microphoneStatus: AVAuthorizationStatus = .notDetermined
    @Published private(set) var accessibilityGranted = false
    /// 本次运行中用户已经发起过屏幕录制授权
    @Published private(set) var didRequestScreenRecording = false

    /// 屏幕录制权限在系统设置里打开后，往往要重启 App 才能生效
    var needsRelaunchHint: Bool { didRequestScreenRecording && !screenRecordingGranted }

    var microphoneGranted: Bool { microphoneStatus == .authorized }

    private static let promptedKey = "didPromptScreenRecording"

    private init() {
        refresh()
    }

    /// 重新读取权限状态。两个查询都很轻量，而且只在值变化时才发布，避免界面无谓刷新。
    func refresh() {
        let screen = CGPreflightScreenCaptureAccess()
        if screen != screenRecordingGranted { screenRecordingGranted = screen }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphoneStatus { microphoneStatus = mic }
        let accessibility = CGPreflightPostEventAccess()
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
    }

    /// 请求辅助功能权限：第一次会弹出系统提示；之后打开 系统设置 › 隐私与安全性 › 辅助功能
    func requestAccessibility() {
        if !CGRequestPostEventAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    /// 截图 / 录屏开始前调用：有权限返回 true；没有则弹出权限引导并返回 false（不会崩溃或静默失败）
    func ensureScreenRecording() -> Bool {
        refresh()
        if screenRecordingGranted { return true }
        OnboardingWindowController.show()
        return false
    }

    // MARK: - 请求权限

    func requestScreenRecording() {
        didRequestScreenRecording = true
        let promptedBefore = UserDefaults.standard.bool(forKey: Self.promptedKey)
        UserDefaults.standard.set(true, forKey: Self.promptedKey)

        // 第一次调用会弹出系统授权对话框（同时把 Velos 加进系统设置的列表）。
        // 系统对话框只会出现一次，之后再调用不会有任何提示，只能请用户去系统设置里手动打开。
        let granted = CGRequestScreenCaptureAccess()
        if !granted && promptedBefore {
            openSystemSettings(.screenRecording)
        }
        refresh()
    }

    func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                // 回调不在主线程，切回主线程更新状态
                Task { @MainActor in PermissionManager.shared.refresh() }
            }
        case .denied, .restricted:
            // 被拒绝过的权限系统不会再弹窗，只能到系统设置里打开
            openSystemSettings(.microphone)
        default:
            break
        }
    }

    // MARK: - 系统设置与重启

    enum SettingsPane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case microphone = "Privacy_Microphone"
    }

    /// 直接跳到「系统设置 › 隐私与安全性」中对应的页面
    func openSystemSettings(_ pane: SettingsPane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 重新启动 Velos：先由一个短命的 shell 进程等待本进程退出，再用 open 重新打开
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 路径作为 $0 传入，避免路径里的空格等字符出问题
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }
}
