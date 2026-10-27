import SwiftUI

/// 通用：开机自启、菜单栏图标、保存位置、权限状态
/// 注意：只装了命令行工具时没有 SwiftUI 的宏插件，不能用 @State，界面状态一律放在 ObservableObject 里。
struct GeneralSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared

    var body: some View {
        SettingsPane {
            LabeledContent("启动：") {
                OptionStack {
                    Toggle("登录时自动启动 Snap", isOn: launchAtLoginBinding)
                    if launchAtLogin.requiresApproval {
                        HStack(spacing: 6) {
                            Text("需要在系统设置中允许 Snap 作为登录项。").settingsCaption()
                            Button("打开") { launchAtLogin.openSystemSettings() }
                                .controlSize(.small)
                        }
                    } else if let error = launchAtLogin.lastError {
                        Text(error).settingsCaption()
                    }
                }
            }

            LabeledContent("菜单栏：") {
                OptionStack {
                    Toggle("显示菜单栏图标", isOn: $prefs.showMenuBarIcon)
                    Text("隐藏后通过快捷键使用；再次打开 Snap 应用即可回到这里。")
                        .settingsCaption()
                }
            }

            LabeledContent("截图保存到：") {
                FolderPicker(kind: .screenshot, path: $prefs.screenshotDirectoryPath,
                             example: SaveLocation.fileName(prefix: "截图", fileExtension: prefs.imageFormat.fileExtension))
            }

            LabeledContent("录屏保存到：") {
                FolderPicker(kind: .recording, path: $prefs.recordingDirectoryPath,
                             example: SaveLocation.fileName(prefix: "录屏", fileExtension: "mp4"))
            }

            LabeledContent("系统权限：") {
                OptionStack {
                    PermissionStatus(title: "屏幕与系统录音", granted: permissions.screenRecordingGranted)
                    PermissionStatus(title: "麦克风（可选）", granted: permissions.microphoneGranted)
                    Button("权限设置…") { OnboardingWindowController.show() }
                }
            }
        }
        .onAppear {
            permissions.refresh()
            launchAtLogin.refresh()
        }
    }

    /// 开关以系统里的真实状态为准：注册失败时开关会自动弹回原位，并显示原因
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

}

/// 保存文件夹：路径 + 选择 / 在访达中打开 / 恢复默认 + 文件名示例
private struct FolderPicker: View {
    let kind: SaveLocation.Kind
    @Binding var path: String
    let example: String

    var body: some View {
        OptionStack {
            Text((path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 300, alignment: .leading)
                .help(path)
            HStack {
                Button("选择…", action: choose)
                Button("在访达中打开") { SaveLocation.revealInFinder(kind) }
                if path != SaveLocation.defaultDirectory(for: kind).path {
                    Button("恢复默认") { path = SaveLocation.defaultDirectory(for: kind).path }
                }
            }
            Text("文件名示例：\(example)")
                .settingsCaption()
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择\(kind.title)的保存位置"
        panel.directoryURL = URL(fileURLWithPath: path)
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

/// 权限状态：绿色对勾 / 灰色叉号
private struct PermissionStatus: View {
    let title: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .secondary)
            Text(title)
            Text(granted ? "已授权" : "未授权")
                .foregroundStyle(.secondary)
        }
    }
}
