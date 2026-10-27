import SwiftUI
import AVFoundation
import Combine

/// 权限引导界面
struct OnboardingView: View {
    @ObservedObject private var permissions = PermissionManager.shared
    let onDone: () -> Void

    /// 窗口打开期间每秒刷新一次权限状态，用户在系统设置里打开开关后这里能立即反映出来。
    /// 计时器属于这个视图，窗口关闭、视图释放后自动停止。
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(spacing: 0) {
                PermissionRow(
                    symbol: "rectangle.dashed.badge.record",
                    title: "屏幕与系统录音",
                    detail: "必需 · 用于截图、录屏和录制系统声音",
                    state: permissions.screenRecordingGranted ? .granted : .actionable("授权…"),
                    action: permissions.requestScreenRecording
                )
                Divider().padding(.leading, 54)
                PermissionRow(
                    symbol: "mic",
                    title: "麦克风",
                    detail: "可选 · 只有录屏时录制麦克风声音才需要",
                    state: microphoneRowState,
                    action: permissions.requestMicrophone
                )
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            if permissions.needsRelaunchHint {
                relaunchHint
            }

            HStack {
                Text("快捷键：\(Preferences.shared.screenshotHotkey.displayString) 截图　\(Preferences.shared.recordingHotkey.displayString) 录屏")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize()
        .onReceive(poll) { _ in permissions.refresh() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text("欢迎使用 Snap")
                    .font(.title2.weight(.semibold))
                Text("截图和录屏需要以下系统权限。所有处理都在本机完成，Snap 不联网，也不收集任何数据。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var relaunchHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text("在「系统设置 › 隐私与安全性 › 录屏与系统录音」中打开 Snap 的开关后，需要重新启动 Snap 才能生效。")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("重新启动 Snap") { permissions.relaunch() }
        }
        .font(.callout)
    }

    private var microphoneRowState: PermissionRow.State {
        switch permissions.microphoneStatus {
        case .authorized: .granted
        case .notDetermined: .actionable("授权…")
        case .denied: .actionable("打开系统设置")
        case .restricted: .unavailable("受系统限制")
        @unknown default: .actionable("授权…")
        }
    }
}

/// 一行权限：图标、名称、说明，右侧是状态或授权按钮
private struct PermissionRow: View {
    enum State {
        case granted
        case actionable(String)
        case unavailable(String)
    }

    let symbol: String
    let title: String
    let detail: String
    let state: State
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 30)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            switch state {
            case .granted:
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .actionable(let title):
                Button(title, action: action)
            case .unavailable(let reason):
                Text(reason).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}
