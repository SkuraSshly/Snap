import SwiftUI
import Carbon.HIToolbox

/// 快捷键：点击录制框后按下新的组合键；设置前检查冲突，有冲突时保留原来的快捷键并说明原因
struct HotkeySettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var model = HotkeySettingsModel.shared

    var body: some View {
        SettingsPane {
            row(.screenshot, hotkey: prefs.screenshotHotkey, defaultHotkey: .defaultScreenshot)
            row(.recording, hotkey: prefs.recordingHotkey, defaultHotkey: .defaultRecording)
            LabeledContent("") {
                Text("点击快捷键框，然后按下新的组合键；按 Esc 取消。需要包含 ⌘、⌥ 或 ⌃ 之一（F1–F20 可以单独使用）。\n已被 macOS 占用的组合键（如 ⇧⌘3、⌘空格）按下时由系统直接处理，Snap 收不到，不能设置。\n选区界面里再按一次同一个快捷键（按住修饰键连按或松开后再按都行），可在「区域 ↔ 全屏」之间切换；录制中按录屏快捷键停止录制。")
                    .settingsCaption()
            }
        }
        .onDisappear { model.messages.removeAll() }
    }

    @ViewBuilder
    private func row(_ action: HotkeyManager.Action, hotkey: Hotkey, defaultHotkey: Hotkey) -> some View {
        LabeledContent("\(action.title)：") {
            OptionStack {
                HStack(spacing: 10) {
                    HotkeyRecorder(action: action, hotkey: hotkey)
                        .frame(width: 150, height: 26)
                        // 与左边「截图：」文字的基线对齐（文字在框里垂直居中）
                        .alignmentGuide(.firstTextBaseline) { $0.height / 2 + 4.5 }
                    if hotkey != defaultHotkey {
                        Button("恢复默认") { model.record(defaultHotkey, for: action) }
                    }
                }
                if let message = model.messages[action] {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320, alignment: .leading)
                }
            }
        }
    }
}

/// 快捷键设置的界面状态（命令行工具没有宏插件，不能用 @State）
@MainActor
final class HotkeySettingsModel: ObservableObject {
    static let shared = HotkeySettingsModel()
    /// 每个快捷键最近一次设置失败的原因
    @Published var messages: [HotkeyManager.Action: String] = [:]

    func record(_ hotkey: Hotkey, for action: HotkeyManager.Action) {
        messages[action] = CaptureCoordinator.shared.setHotkey(hotkey, for: action)
    }

    /// 按住修饰键按了键，但按键没有传到 Snap（被 macOS 系统快捷键或其他程序直接处理了）
    func swallowed(modifiers: NSEvent.ModifierFlags, for action: HotkeyManager.Action) {
        let symbols = Hotkey.modifierSymbols(modifiers)
        let taken = HotkeyConflicts.systemShortcuts(with: modifiers)
        var text = "没有收到按键：\(symbols) 加某个键的组合如果已被 macOS 系统快捷键（或其他程序）占用，按下时会被系统直接处理（例如 ⇧⌘3 会直接截屏），Snap 收不到，所以无法设置。"
        if !taken.isEmpty {
            let list = taken.prefix(6).map { item in item.name.map { "\(item.hotkey.displayString)（\($0)）" } ?? item.hotkey.displayString }
            text += "系统已占用的 \(symbols) 组合：" + list.joined(separator: "、") + (taken.count > 6 ? " 等" : "") + "。"
        }
        messages[action] = text
    }
}

/// SwiftUI 包装
private struct HotkeyRecorder: NSViewRepresentable {
    let action: HotkeyManager.Action
    let hotkey: Hotkey

    func makeNSView(context: Context) -> HotkeyRecorderField {
        let field = HotkeyRecorderField(hotkey: hotkey)
        field.onRecorded = { [action] hotkey in HotkeySettingsModel.shared.record(hotkey, for: action) }
        field.onSwallowed = { [action] modifiers in HotkeySettingsModel.shared.swallowed(modifiers: modifiers, for: action) }
        field.onStart = { [action] in HotkeySettingsModel.shared.messages[action] = nil }
        return field
    }

    func updateNSView(_ field: HotkeyRecorderField, context: Context) {
        field.hotkey = hotkey
    }
}

/// 快捷键录制框：显示当前快捷键；点击后进入录制状态，实时显示正按着的修饰键，按下组合键即完成。
/// 录制期间暂停 Snap 的全部全局快捷键，免得按下去直接触发截图 / 录屏。
///
/// macOS 的系统快捷键（⇧⌘3、⌘空格等）在系统层面就被处理掉了，按键根本不会传给 App。
/// 系统虽然提供了临时停用系统快捷键的接口（PushSymbolicHotKeyMode），但要求 App 有「辅助功能」权限，
/// Snap 不申请这个权限，所以这类组合键无法录制。为了不让人以为「按了没反应」，这里检测按键被吞掉的情况并说明原因：
/// - 只收到了按键松开、没收到按下：说明按下被拦截了，按完整组合键处理（冲突检测会指出是哪个系统快捷键）
/// - 按住修饰键期间一个按键都没收到就全部松开了
/// - 按住修饰键时窗口失去焦点（例如 ⇧⌘5 会弹出系统截屏工具栏）
final class HotkeyRecorderField: NSView {
    var hotkey: Hotkey { didSet { needsDisplay = true } }
    var onRecorded: ((Hotkey) -> Void)?
    /// 按键被系统吞掉时回调：参数是当时按着的修饰键
    var onSwallowed: ((NSEvent.ModifierFlags) -> Void)?
    /// 开始录制时回调（清除上一次的提示）
    var onStart: (() -> Void)?

    /// 这一轮按住修饰键期间按过的修饰键（取并集）、有没有收到过按键
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var receivedKey = false
    private var resignObserver: NSObjectProtocol?
    private static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    private(set) var isRecording = false {
        didSet { needsDisplay = true }
    }
    private var liveModifiers: NSEvent.ModifierFlags = []

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
        super.init(frame: CGRect(x: 0, y: 0, width: 150, height: 26))
        toolTip = "点击后按下新的快捷键"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    /// 设置窗口不是焦点时，第一下点击也直接进入录制
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 26) }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard let window, window.makeFirstResponder(self) else { return }
        liveModifiers = []
        heldModifiers = []
        receivedKey = false
        isRecording = true
        onStart?()
        MainActor.assumeIsolated { HotkeyManager.shared.pauseAll() }
        // 按住修饰键时窗口失去焦点：多半是系统快捷键弹出了自己的界面（例如 ⇧⌘5）
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                let held = self.heldModifiers.union(self.liveModifiers).intersection(Self.relevantModifiers)
                self.stopRecording()
                if !self.receivedKey, Self.isStrong(held) { self.onSwallowed?(held) }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        liveModifiers = []
        heldModifiers = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        MainActor.assumeIsolated { HotkeyManager.shared.resumeAll() }
    }

    /// 带 ⌘ / ⌥ / ⌃ 之一（只按 ⇧ 不算组合键）
    private static func isStrong(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.intersection([.control, .option, .command]).isEmpty
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        guard !event.isARepeat else { return }
        receivedKey = true
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if Int(event.keyCode) == kVK_Escape && modifiers.isEmpty {
            stopRecording()
            return
        }
        let recorded = Hotkey(event: event)
        stopRecording()
        onRecorded?(recorded)
    }

    /// ⌘ 组合键会先走 performKeyEquivalent（例如 ⌘W 本来会关闭窗口），录制期间全部截下来
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    /// 只收到松开、没收到按下：按下被系统拦截了。按完整组合键交给冲突检测，由它说明被哪个系统快捷键占用
    override func keyUp(with event: NSEvent) {
        guard isRecording, !receivedKey else { return super.keyUp(with: event) }
        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        guard Self.isStrong(modifiers) || Hotkey(event: event).isFunctionKey else { return }
        receivedKey = true
        let recorded = Hotkey(event: event)
        stopRecording()
        onRecorded?(recorded)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        let modifiers = event.modifierFlags.intersection(Self.relevantModifiers)
        liveModifiers = modifiers
        if modifiers.isEmpty {
            // 修饰键全部松开：期间一个按键都没收到，说明按下的组合被系统吞掉了（或者只按了修饰键）
            if !receivedKey, Self.isStrong(heldModifiers) { onSwallowed?(heldModifiers) }
            heldModifiers = []
            receivedKey = false
        } else {
            heldModifiers.formUnion(modifiers)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        shape.fill()
        shape.lineWidth = isRecording ? 2 : 1
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        shape.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            let symbols = Hotkey.modifierSymbols(liveModifiers)
            text = symbols.isEmpty ? "请按下快捷键…" : symbols + " …"
            color = .secondaryLabelColor
        } else {
            text = hotkey.spacedDisplayString
            color = .labelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                withAttributes: attributes)
    }

    #if DEBUG
    func debugPress(_ event: NSEvent) { keyDown(with: event) }
    #endif
}
