import SwiftUI
import AVFoundation
import Combine

/// 权限引导界面（温暖磨砂风格，与设置窗口一致）
struct OnboardingView: View {
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var prefs = Preferences.shared
    let onDone: () -> Void

    /// 窗口打开期间每秒刷新一次权限状态，用户在系统设置里打开开关后这里能立即反映出来。
    /// 计时器属于这个视图，窗口关闭、视图释放后自动停止。
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            SettingsSection(title: "需要的系统权限") {
                SettingsRow(icon: "rectangle.dashed.badge.record", tint: .chipLavender, title: "屏幕与系统录音",
                            caption: "必需 · 用于截图、录屏、截屏翻译和录制系统声音", isFirst: true) {
                    permissionAccessory(granted: permissions.screenRecordingGranted, title: "授权…",
                                        action: permissions.requestScreenRecording)
                }
                SettingsRow(icon: "mic.fill", tint: .chipRose, title: "麦克风",
                            caption: "可选 · 只有录屏时录制麦克风声音才需要") {
                    microphoneAccessory
                }
            }

            if permissions.needsRelaunchHint {
                relaunchHint
            }

            HStack(spacing: 10) {
                shortcut(prefs.screenshotHotkey, "截图")
                shortcut(prefs.recordingHotkey, "录屏")
                shortcut(prefs.translateHotkey, "截屏翻译")
                Spacer()
                Button("完成", action: onDone)
                    .buttonStyle(WarmButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 34)   // 让出（透明的）标题栏
        .padding(.bottom, 22)
        .frame(width: 540)
        .fixedSize()
        .fontDesign(.rounded)
        .tint(.apricot)
        .background(WarmWindowBackground())
        .onReceive(poll) { _ in permissions.refresh() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text("欢迎使用 Snap")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.warmInk)
                Text("截图、录屏和截屏翻译需要以下系统权限。所有处理都在本机完成，Snap 不联网，也不收集任何数据。")
                    .settingsCaption()
            }
        }
    }

    /// 已授权：绿色徽章；未授权：授权按钮
    @ViewBuilder
    private func permissionAccessory(granted: Bool, title: String, action: @escaping () -> Void) -> some View {
        if granted {
            StatusBadge(ok: true, text: "已授权")
        } else {
            Button(title, action: action).buttonStyle(WarmButtonStyle(prominent: true))
        }
    }

    @ViewBuilder
    private var microphoneAccessory: some View {
        switch permissions.microphoneStatus {
        case .authorized: StatusBadge(ok: true, text: "已授权")
        case .denied: Button("打开系统设置", action: permissions.requestMicrophone).buttonStyle(WarmButtonStyle())
        case .restricted: StatusBadge(ok: false, text: "受系统限制")
        default: Button("授权…", action: permissions.requestMicrophone).buttonStyle(WarmButtonStyle())
        }
    }

    private var relaunchHint: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Color.apricot)
            Text("在「系统设置 › 隐私与安全性 › 录屏与系统录音」中打开 Snap 的开关后，需要重新启动 Snap 才能生效。")
                .settingsCaption()
            Spacer(minLength: 8)
            Button("重新启动 Snap") { permissions.relaunch() }.buttonStyle(WarmButtonStyle())
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.apricot.opacity(0.1)))
    }

    /// 快捷键提示：键帽 + 用途
    private func shortcut(_ hotkey: Hotkey, _ title: String) -> some View {
        HStack(spacing: 4) {
            Text(hotkey.displayString)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.warmInk)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.warmCard))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.warmHairline, lineWidth: 0.5))
            Text(title)
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Color.warmSecondary)
        }
    }
}
