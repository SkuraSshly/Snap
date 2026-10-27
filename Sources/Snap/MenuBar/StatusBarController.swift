import AppKit
import Combine

/// 菜单栏图标与菜单。
/// 图标可以在设置里隐藏：隐藏时直接移除 NSStatusItem，而不是只把它设为不可见。
/// 录制中图标变成红点 + 计时，暂停时变成杏色暂停图标（图标被隐藏时不显示，录制控制交给浮动控制条）。
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var observers: Set<AnyCancellable> = []
    /// 录制计时，只在录制期间运行（空闲时没有任何定时器）
    private var recordingTimer: Timer?

    #if DEBUG
    nonisolated(unsafe) static weak var debugCurrent: StatusBarController?
    var debugHasStatusItem: Bool { statusItem != nil }
    var debugMenuTitles: [String] { rebuildMenu(); return menu.items.map(\.title) }
    #endif

    override init() {
        super.init()
        #if DEBUG
        Self.debugCurrent = self
        #endif
        menu.delegate = self
        menu.autoenablesItems = false

        // 订阅「显示菜单栏图标」设置；订阅时会立即收到当前值，从而完成首次创建
        Preferences.shared.$showMenuBarIcon
            .removeDuplicates()
            .sink { [weak self] visible in self?.setIconVisible(visible) }
            .store(in: &observers)
        RecordingManager.shared.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.recordingStateChanged(state) }
            .store(in: &observers)
    }

    private func setIconVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.toolTip = "Snap"
            item.menu = menu
            statusItem = item
            updateIcon()
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - 录制状态

    private func recordingStateChanged(_ state: RecordingManager.State) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        if state == .recording || state == .paused {
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateIcon() }
            }
        }
        updateIcon()
    }

    private func updateIcon() {
        guard let item = statusItem, let button = item.button else { return }
        let manager = RecordingManager.shared
        if manager.isRecording {
            // 红色圆点（暂停时是杏色暂停图标）+ 已录制时长（不含暂停）
            item.length = NSStatusItem.variableLength
            let paused = manager.isPaused
            let config = NSImage.SymbolConfiguration(paletteColors: [paused ? WarmPalette.apricot : OverlayAccent.recording])
            button.image = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "record.circle.fill",
                                   accessibilityDescription: paused ? "录制已暂停" : "正在录制")?
                .withSymbolConfiguration(config)
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: " " + Self.format(manager.elapsed), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            ])
            button.toolTip = (paused ? "录制已暂停" : "正在录制") + " · \(CaptureCoordinator.shared.recordingHotkey.displayString) 停止"
        } else {
            item.length = NSStatusItem.squareLength
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snap")
            image?.isTemplate = true   // 模板图：自动适配浅色 / 深色菜单栏
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "Snap"
        }
    }

    /// 时长：mm:ss，超过一小时为 h:mm:ss
    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - 菜单

    /// 每次打开菜单前重建，确保权限状态等信息是最新的（菜单不打开时不做任何事，空闲 CPU 为 0）
    func menuNeedsUpdate(_ menu: NSMenu) {
        PermissionManager.shared.refresh()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if !PermissionManager.shared.screenRecordingGranted {
            let warning = addItem("授予屏幕录制权限…", action: #selector(showPermissions))
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(.separator())
        }

        // 菜单里的快捷键只做显示，真正的全局快捷键由 HotkeyManager 注册
        let shotKey = CaptureCoordinator.shared.screenshotHotkey
        let recordKey = CaptureCoordinator.shared.recordingHotkey
        let recordingState = RecordingManager.shared.state

        if recordingState == .recording || recordingState == .paused {
            let stop = addItem("停止录制", action: #selector(stopRecording),
                               key: recordKey.menuKeyEquivalent, modifiers: recordKey.cocoaModifiers)
            stop.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: nil)
            let paused = recordingState == .paused
            let pause = addItem(paused ? "继续录制" : "暂停录制", action: #selector(togglePause))
            pause.image = NSImage(systemSymbolName: paused ? "play.circle" : "pause.circle", accessibilityDescription: nil)
            menu.addItem(.separator())
        }

        addItem("截图", action: #selector(takeScreenshot), key: shotKey.menuKeyEquivalent, modifiers: shotKey.cocoaModifiers)
        let record = addItem("录屏", action: #selector(startRecording),
                             key: recordKey.menuKeyEquivalent, modifiers: recordKey.cocoaModifiers)
        record.isEnabled = recordingState == .idle

        for (action, key) in [(HotkeyManager.Action.screenshot, shotKey), (.recording, recordKey)]
        where HotkeyManager.shared.failedActions.contains(action) {
            let warning = addItem("快捷键 \(key.displayString) 已被其他程序占用", action: nil)
            warning.isEnabled = false
        }

        addItem("将录屏转为 GIF…", action: #selector(convertToGIF))

        menu.addItem(.separator())
        addItem("打开截图文件夹", action: #selector(openScreenshotFolder))
        addItem("打开录屏文件夹", action: #selector(openRecordingFolder))
        addItem("设置…", action: #selector(openSettings), key: ",")
        menu.addItem(.separator())

        let quit = addItem("退出 Snap", action: #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector?, key: String = "",
                         modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func takeScreenshot() {
        // 等菜单淡出后再冻屏，避免把菜单截进去
        CaptureCoordinator.shared.beginScreenshot(delay: .milliseconds(250))
    }

    @objc private func startRecording() {
        CaptureCoordinator.shared.beginRecording(delay: .milliseconds(150))
    }

    @objc private func stopRecording() {
        Task { await RecordingManager.shared.stop() }
    }

    @objc private func togglePause() {
        RecordingManager.shared.togglePause()
    }

    /// 选一个视频文件，在屏幕角落显示它的缩略图并开始导出 GIF（进度显示在缩略图上）
    @objc private func convertToGIF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.prompt = "转为 GIF"
        panel.message = "选择要转为 GIF 的录屏（GIF 会保存在视频旁边）"
        panel.directoryURL = SaveLocation.directory(for: .recording)
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await ThumbnailManager.shared.showRecording(url, on: nil, exportGIF: true) }
    }

    @objc private func showPermissions() {
        OnboardingWindowController.show()
    }

    @objc private func openScreenshotFolder() {
        SaveLocation.revealInFinder(.screenshot)
    }

    @objc private func openRecordingFolder() {
        SaveLocation.revealInFinder(.recording)
    }

    @objc private func openSettings() {
        SettingsWindowController.show()
    }
}
