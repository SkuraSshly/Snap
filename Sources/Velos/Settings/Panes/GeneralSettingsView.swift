import SwiftUI

/// 通用：开机自启、菜单栏图标、权限状态（保存位置在「截图」「录屏」里）
struct GeneralSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var launchAtLogin = LaunchAtLogin.shared

    var body: some View {
        SettingsPane {
            SettingsSection(title: "启动") {
                SettingsRow(icon: "power", tint: .apricot, title: "登录时自动启动 Velos", caption: launchCaption, isFirst: true) {
                    HStack(spacing: 8) {
                        if launchAtLogin.requiresApproval {
                            Button("去允许") { launchAtLogin.openSystemSettings() }
                                .buttonStyle(WarmButtonStyle())
                        }
                        Toggle("", isOn: launchAtLoginBinding).toggleStyle(WarmSwitchStyle()).labelsHidden()
                    }
                }
                SwitchRow(icon: "menubar.rectangle", tint: .chipCocoa, title: "显示菜单栏图标",
                          caption: "隐藏后通过快捷键使用；再次打开 Velos 应用即可回到这里。", isOn: $prefs.showMenuBarIcon)
            }

            SettingsSection(title: "系统权限") {
                SettingsRow(icon: "rectangle.dashed.badge.record", tint: .chipLavender, title: "屏幕与系统录音",
                            caption: "截图、录屏都需要", isFirst: true) {
                    StatusBadge(ok: permissions.screenRecordingGranted,
                                text: permissions.screenRecordingGranted ? "已授权" : "未授权")
                }
                SettingsRow(icon: "mic.fill", tint: .chipRose, title: "麦克风", caption: "可选，只在录制麦克风时使用") {
                    StatusBadge(ok: permissions.microphoneGranted, text: permissions.microphoneGranted ? "已授权" : "未授权")
                }
                SettingsRow(icon: "hand.raised.fill", tint: .chipHoney, title: "辅助功能",
                            caption: "可选，长截图的自动滚动、滚动限速需要") {
                    HStack(spacing: 8) {
                        if !permissions.accessibilityGranted {
                            Button("去允许") { permissions.requestAccessibility() }
                                .buttonStyle(WarmButtonStyle())
                        }
                        StatusBadge(ok: permissions.accessibilityGranted,
                                    text: permissions.accessibilityGranted ? "已授权" : "未授权")
                    }
                }
                SettingsRow(icon: "lock.shield", tint: .chipSage, title: "权限设置", caption: "查看授权步骤，或重新授权") {
                    Button("打开…") { OnboardingWindowController.show(over: SettingsWindowController.currentWindow) }
                        .buttonStyle(WarmButtonStyle())
                }
            }

            AboutFooter()
        }
        .onAppear {
            permissions.refresh()
            launchAtLogin.refresh()
        }
        // 从系统设置授权回来：重新读取权限状态
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private var launchCaption: String? {
        if launchAtLogin.requiresApproval { return "需要在系统设置中允许 Velos 作为登录项。" }
        return launchAtLogin.lastError
    }

    /// 开关以系统里的真实状态为准：注册失败时开关会自动弹回原位，并显示原因
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

}

/// 保存文件夹：路径 + 更改 / 在访达中打开 / 恢复默认
struct FolderRow: View {
    let kind: SaveLocation.Kind
    let icon: String
    let tint: Color
    let title: String
    @Binding var path: String
    var isFirst = false

    var body: some View {
        SettingsRow(icon: icon, tint: tint, title: title, isFirst: isFirst, titleDetail: AnyView(pathTag)) {
            HStack(spacing: 6) {
                if path != SaveLocation.defaultDirectory(for: kind).path {
                    Button("恢复默认") { path = SaveLocation.defaultDirectory(for: kind).path }
                        .buttonStyle(WarmButtonStyle())
                }
                Button("打开") { SaveLocation.revealInFinder(kind) }
                    .buttonStyle(WarmButtonStyle())
                    .help("在访达中打开\(kind.title)文件夹")
                Button("更改…", action: choose)
                    .buttonStyle(WarmButtonStyle())
            }
        }
    }

    /// 路径做成可点的小标签：点一下在访达中打开
    private var pathTag: some View {
        Button { SaveLocation.revealInFinder(kind) } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill").font(.system(size: 10))
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color.warmSecondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Color.warmTrack))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 230, alignment: .leading)
        .help("在访达中打开 \(path)")
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
        // 作为设置窗口的二级窗口：放在设置窗口正中间
        if let parent = SettingsWindowController.currentWindow {
            panel.begin { response in
                parent.removeChildWindow(panel)
                if response == .OK, let url = panel.url { path = url.path }
            }
            panel.center(over: parent)
        } else if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

/// 页面底部的落款：App 图标 + 版本 + 一句话
private struct AboutFooter: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
            Text("Velos \(version) · 安静地待在菜单栏，按下快捷键就来")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color.warmSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }
}
