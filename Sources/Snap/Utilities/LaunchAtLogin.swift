import ServiceManagement

/// 开机自启：使用 SMAppService（macOS 13+），不需要额外的辅助 App。
/// 状态以系统为准（系统设置 › 通用 › 登录项），不在 UserDefaults 里另存一份，避免两边不一致。
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var isEnabled = false
    /// 用户曾在系统设置里手动关掉过 Snap 的登录项时，需要到系统设置里重新允许
    @Published private(set) var requiresApproval = false
    @Published private(set) var lastError: String?

    private init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    /// 注册失败时开关会弹回真实状态，并记录原因供界面显示
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = "设置失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
