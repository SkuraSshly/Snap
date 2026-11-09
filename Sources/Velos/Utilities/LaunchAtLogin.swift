import ServiceManagement

/// 开机自启：使用 SMAppService（macOS 13+），不需要额外的辅助 App。
/// 状态以系统为准（系统设置 › 通用 › 登录项），不在 UserDefaults 里另存一份，避免两边不一致。
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var isEnabled = false
    /// 用户曾在系统设置里手动关掉过 Velos 的登录项时，需要到系统设置里重新允许
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

    /// 登录项按 bundle id 记录，系统记下的是「最近登记的那一份 App」的位置。
    /// 正式版启动时，如果登录项是开着的，就用当前这份重新登记一次，保证登录时启动的是正在用的这一份
    /// （例如 App 被移动、更新，或者开发时运行过别的副本）。调试版不做，避免把登录项指到编译目录。
    func reregisterIfEnabled() {
        #if !DEBUG
        guard SMAppService.mainApp.status == .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            Log.capture.error("重新登记登录项失败：\(error.localizedDescription, privacy: .public)")
        }
        refresh()
        #endif
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
