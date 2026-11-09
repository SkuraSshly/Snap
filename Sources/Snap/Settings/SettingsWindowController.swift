import AppKit
import SwiftUI

/// 设置窗口左侧的栏目
enum SettingsTab: String, CaseIterable {
    case general, screenshot, recording, translate, hotkeys

    var title: String {
        switch self {
        case .general: "通用"
        case .screenshot: "截图"
        case .recording: "录屏"
        case .translate: "截屏翻译"
        case .hotkeys: "快捷键"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .screenshot: "camera.viewfinder"
        case .recording: "record.circle"
        case .translate: "character.bubble.fill"
        case .hotkeys: "keyboard.fill"
        }
    }

    /// 侧栏图标小方块的颜色
    var tint: Color {
        switch self {
        case .general: .chipCocoa
        case .screenshot: .chipSky
        case .recording: .coral
        case .translate: .chipSage
        case .hotkeys: .chipLavender
        }
    }
}

/// 当前选中的栏目、鼠标悬停的栏目（侧栏和内容共享）
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
    @Published var hovered: SettingsTab?
}

/// 设置窗口：温暖磨砂风格（与截图工具栏一致）。左侧是栏目，杏色选中块在栏目之间弹性滑动；右侧是对应的设置。
/// 窗口大小固定，切换栏目时窗口不变（内容多的页面在右侧滚动），不会跳动。
/// 窗口按需创建，关闭后整个控制器释放，不常驻内存。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static var current: SettingsWindowController?
    static let size = CGSize(width: 800, height: 600)

    private let window: NSWindow
    private let selection = SettingsSelection()

    static func show(_ tab: SettingsTab? = nil) {
        if let controller = current {
            if let tab { controller.select(tab) }
            controller.present()
            return
        }
        let controller = SettingsWindowController(tab: tab ?? .general)
        current = controller
        controller.present()
    }

    private init(tab: SettingsTab) {
        window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.size),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        super.init()

        // 标题栏透明、不显示标题（窗口标题仍按栏目设置，供辅助功能和「窗口」菜单使用）
        window.identifier = ScreenFreezer.capturableIdentifier   // 设置窗口和其他窗口一样能被截图
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false

        selection.tab = tab
        let root = SettingsRootView(selection: selection) { [weak self] tab in self?.select(tab) }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []   // 窗口大小固定，不随内容变化
        window.contentViewController = host
        window.setContentSize(Self.size)

        window.isReleasedWhenClosed = false
        window.delegate = self
        // 第一次显示不要动画：否则窗口的第一次布局落在动画里，左上角的「Snap 设置」等会从角落飞进来
        window.title = tab.title
        window.centerOnScreen()
    }

    private func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func select(_ tab: SettingsTab) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) { selection.tab = tab }
        window.title = tab.title
    }

    func windowWillClose(_ notification: Notification) {
        // 二级窗口（权限设置等）跟着一起关
        window.childWindows?.forEach { $0.close() }
        Self.current = nil
    }

    /// 打开着的设置窗口（二级界面以表单形式挂在它上面）
    static var currentWindow: NSWindow? { current?.window }

    #if DEBUG
    var debugWindow: NSWindow { window }
    static var debugCurrent: SettingsWindowController? { current }
    #endif
}

/// 左侧栏目 + 右侧设置
private struct SettingsRootView: View {
    @ObservedObject var selection: SettingsSelection
    let onSelect: (SettingsTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: selection, onSelect: onSelect)
                .frame(width: 196)
            Rectangle().fill(Color.warmHairline).frame(width: 0.5)
            VStack(alignment: .leading, spacing: 0) {
                Text(selection.tab.title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.warmInk)
                    .padding(.leading, 28)
                    .padding(.top, 20)
                    .padding(.bottom, 10)
                    .transaction { $0.animation = nil }
                ScrollView {
                    page
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.automatic)
                .id(selection.tab)   // 换栏目时从顶部开始
                .transition(.opacity.animation(.easeOut(duration: 0.18)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: SettingsWindowController.size.width, height: SettingsWindowController.size.height)
        .fontDesign(.rounded)
        .tint(.apricot)
        .background(WarmWindowBackground())
        .ignoresSafeArea()
    }

    @ViewBuilder private var page: some View {
        switch selection.tab {
        case .general: GeneralSettingsView()
        case .screenshot: ScreenshotSettingsView()
        case .recording: RecordingSettingsView()
        case .translate: TranslateSettingsView()
        case .hotkeys: HotkeySettingsView()
        }
    }
}

/// 左侧栏目：图标小方块 + 名称；选中的是杏色圆角块，切换时弹性滑过去
private struct SettingsSidebar: View {
    @ObservedObject var selection: SettingsSelection
    let onSelect: (SettingsTab) -> Void

    private let rowHeight: CGFloat = 38
    private let tabs = SettingsTab.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 让出左上角的红绿灯
            Spacer().frame(height: 52)
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Snap")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.warmInk)
                    Text("设置")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.warmSecondary)
                }
            }
            .padding(.leading, 18)
            .padding(.bottom, 14)

            let index = CGFloat(tabs.firstIndex(of: selection.tab) ?? 0)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [Color.apricot.opacity(0.88), .apricot], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color.apricot.opacity(0.4), radius: 5, y: 2)
                    .frame(height: rowHeight - 4)
                    .offset(y: index * rowHeight + 2)
                VStack(spacing: 0) {
                    ForEach(tabs, id: \.self) { tab in
                        row(tab)
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.warmCard.opacity(0.45))
    }

    private func row(_ tab: SettingsTab) -> some View {
        let selected = tab == selection.tab
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.white.opacity(0.25)) : AnyShapeStyle(tab.tint))
                .overlay(
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: selected)
                )
                .frame(width: 24, height: 24)
            Text(tab.title)
                .font(.system(size: 13, weight: selected ? .semibold : .medium, design: .rounded))
                .foregroundStyle(selected ? Color.white : Color.warmInk)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.warmTrack)
                .padding(.vertical, 2)
                .opacity(!selected && selection.hovered == tab ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { selection.hovered = tab } else if selection.hovered == tab { selection.hovered = nil }
        }
        .onTapGesture { onSelect(tab) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
