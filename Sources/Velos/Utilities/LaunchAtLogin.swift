import ServiceManagement

/// 开机自启：使用 SMAppService（macOS 13+），不需要额外的辅助 App。
/// 状态以系统为准（系统设置 › 通用 › 登录项）。
///
/// 设置窗口在 VelosSettings 里：系统的登录项只能由 App 自己登记（VelosSettings 登记的会是它自己），
/// 所以开关交给 Velos 去做；Velos 把系统的状态抄一份到设置文件里，VelosSettings 从那里读来显示。
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
        if AppIdentity.isSettingsApp {
            let defaults = AppIdentity.defaults
            isEnabled = defaults.string(forKey: Self.statusKey) == "enabled"
            requiresApproval = defaults.string(forKey: Self.statusKey) == "requiresApproval"
            lastError = defaults.string(forKey: Self.errorKey)
            return
        }
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
        // 给 VelosSettings 看的：系统状态抄一份到设置文件
        AppIdentity.defaults.set(isEnabled ? "enabled" : requiresApproval ? "requiresApproval" : "off", forKey: Self.statusKey)
        if let lastError { AppIdentity.defaults.set(lastError, forKey: Self.errorKey) } else { AppIdentity.defaults.removeObject(forKey: Self.errorKey) }
    }

    private static let statusKey = "launchAtLoginStatus", errorKey = "launchAtLoginError"

    /// 注册失败时开关会弹回真实状态，并记录原因供界面显示
    func setEnabled(_ enabled: Bool) {
        if AppIdentity.isSettingsApp {
            // 请 Velos 去登记；它做完后发来「设置改了」，这里再 refresh 显示结果
            SettingsProcess.post(.setLaunchAtLogin, userInfo: ["enabled": enabled ? "1" : "0"])
            return
        }
        defer { SettingsProcess.notePreferencesChanged() }   // 结果告诉开着的设置窗口
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
