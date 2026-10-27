import AppKit
import SwiftUI

/// 设置窗口的标签页
enum SettingsTab: String, CaseIterable {
    case general, screenshot, recording, hotkeys

    var title: String {
        switch self {
        case .general: "通用"
        case .screenshot: "截图"
        case .recording: "录屏"
        case .hotkeys: "快捷键"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .screenshot: "camera.viewfinder"
        case .recording: "record.circle"
        case .hotkeys: "keyboard"
        }
    }

    var toolbarID: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }
}

/// 当前选中的标签页（AppKit 工具栏和 SwiftUI 内容共享）
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// 设置窗口：原生「偏好设置」样式的工具栏标签 + SwiftUI 面板。
/// 窗口按需创建，关闭后整个控制器释放，不常驻内存。
/// 窗口尺寸由 SwiftUI 内容自动决定，切换标签或内容变化时窗口会自动贴合。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private static var current: SettingsWindowController?

    private let window: NSWindow
    private let selection = SettingsSelection()

    static func show(_ tab: SettingsTab? = nil) {
        if let controller = current {
            if let tab { controller.select(tab) }
            controller.present()
            return
        }
        // 第一次打开时直接显示要的标签页：窗口按这一页的内容定高
        //（先按「通用」建好再切换的话，窗口高度不会跟着变，内容多的页面会被截断）
        let controller = SettingsWindowController(tab: tab ?? .general)
        current = controller
        controller.present()
    }

    private init(tab: SettingsTab) {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                          backing: .buffered, defer: true)
        super.init()

        // 先选好标签页再创建内容：窗口按创建时内容的大小定高
        selection.tab = tab
        window.contentViewController = NSHostingController(rootView: SettingsRootView(selection: selection))

        let toolbar = NSToolbar(identifier: "SnapSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        window.isReleasedWhenClosed = false
        window.delegate = self
        select(tab)
        window.center()
    }

    private func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func select(_ tab: SettingsTab) {
        selection.tab = tab
        window.toolbar?.selectedItemIdentifier = tab.toolbarID
        window.title = tab.title
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        if let tab = SettingsTab(rawValue: sender.itemIdentifier.rawValue) {
            select(tab)
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarID)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarID)
    }

    /// 可选中的项：这样工具栏按钮会像系统设置那样保持高亮
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarID)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }
}

/// 根据选中的标签显示对应面板
private struct SettingsRootView: View {
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        switch selection.tab {
        case .general: GeneralSettingsView()
        case .screenshot: ScreenshotSettingsView()
        case .recording: RecordingSettingsView()
        case .hotkeys: HotkeySettingsView()
        }
    }
}
