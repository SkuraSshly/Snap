import AppKit
import Combine
import SnapOCRKit
import SwiftUI

/// 截屏翻译的结果窗口：放在选区旁边（优先右侧，其次下方、左侧、上方），不挡住选区、不超出屏幕。
///
/// - 用带标题栏（但隐藏）的面板：系统的「下载语言包」提示需要能挂在窗口上
/// - 不激活 Snap 也能成为焦点窗口：可以直接编辑原文、按 Esc
/// - 内容变高时（译文出来、原文变长）保持顶边不动，向下长，不跳动
/// - 没钉住：点窗口外面或按 Esc 关闭（下载提示显示时不关闭）
/// - 钉住（图钉按钮或 ⌘P）：置顶，点别处不关闭，可以拖到任何地方、拖边缘调整大小；关闭按钮或 Esc 关闭。
///   可以同时钉住多个窗口，每次截屏翻译都会生成新窗口
/// - 快捷键（窗口是焦点时）：⌘C 复制译文（选中了文字时复制选中的文字）、⇧⌘C 复制原文、⌘R 重新翻译、⌘P 钉住 / 取消钉住、Esc 关闭
@MainActor
final class TranslationWindow: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    /// 钉住 / 取消钉住时通知（截屏翻译的总调度据此管理多个窗口）
    var onPinChange: ((Bool) -> Void)?

    let model: TranslationModel
    private let window: KeyablePanel
    private let host: NSHostingController<TranslationView>
    private let anchor: CGRect
    private var monitors: [Any] = []
    private var changes: AnyCancellable?
    private var isClosed = false
    private var hud: RecognitionHUD?

    /// 复制用的剪贴板（自测时换成私有剪贴板）
    nonisolated(unsafe) static var pasteboard = NSPasteboard.general

    var text: String { model.sourceText }
    var frame: CGRect { window.frame }
    var isVisible: Bool { window.isVisible }
    var hidesOnDeactivate: Bool { window.hidesOnDeactivate }

    /// - Parameter model: 已经开始翻译的模型（识别一结束就开始翻译，窗口出现时译文多半已经好了）
    init(model: TranslationModel, near rect: CGRect) {
        anchor = rect
        self.model = model
        window = KeyablePanel(contentRect: CGRect(x: 0, y: 0, width: TranslationView.width, height: 200),
                              styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        var close: () -> Void = {}
        var copy: (String, String) -> Void = { _, _ in }
        var togglePin: () -> Void = {}
        host = NSHostingController(rootView: TranslationView(model: model, onClose: { close() }, onCopy: { copy($0, $1) },
                                                             onTogglePin: { togglePin() }))
        super.init()
        close = { [weak self] in self?.close(reason: "关闭按钮") }
        copy = { [weak self] text, hint in self?.copy(text, hint: hint) }
        togglePin = { [weak self] in self.map { $0.setPinned(!$0.model.isPinned) } }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        hideStandardButtons()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        // NSPanel 默认在 App 失去前台时隐藏；截屏翻译结束时焦点已经还给原来的 App，必须关掉
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.onCancel = { [weak self] in self?.close(reason: "Esc") }

        host.sizingOptions = []   // 窗口大小由这里控制（顶边不动），不让 AppKit 自动改
        window.contentViewController = host
        let size = fittingSize()
        window.setFrame(Self.placement(for: size, near: rect), display: false)
        window.minSize = CGSize(width: 340, height: 220)
        if Preferences.shared.translateWindowPinnedByDefault { applyPinned(true) }
        // 内容变化（译文出来、原文变长）时调整高度
        changes = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitHeight() }
        }
    }

    func show() {
        window.orderFrontRegardless()
        window.makeKey()
        Log.capture.notice("截屏翻译：结果窗口显示 \(Int(self.window.frame.width))×\(Int(self.window.frame.height))，译文\(self.model.status == .done ? "已就绪" : "还在翻译", privacy: .public)")
        if model.status == .idle, !model.isRecognizing, model.recognitionFailure == nil { model.translate() }
        installMonitors()
    }

    // MARK: - 钉住

    func setPinned(_ pinned: Bool) {
        guard pinned != model.isPinned, !isClosed else { return }
        applyPinned(pinned)
        Log.capture.notice("截屏翻译：结果窗口\(pinned ? "钉住" : "取消钉住", privacy: .public)")
        onPinChange?(pinned)
    }

    /// 隐藏左上角的红绿灯（窗口自己有关闭按钮）；改 styleMask 后系统会把它们重新显示出来，要再隐藏一次
    private func hideStandardButtons() {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
    }

    private func applyPinned(_ pinned: Bool) {
        model.isPinned = pinned
        defer { hideStandardButtons() }
        if pinned {
            window.styleMask.insert(.resizable)
        } else {
            // 取消钉住：回到默认宽度、高度随内容
            window.styleMask.remove(.resizable)
            model.isFreeSized = false
            var frame = window.frame
            frame.size.width = TranslationView.width
            window.setFrame(frame, display: true)
            DispatchQueue.main.async { [weak self] in self?.fitHeight() }
        }
    }

    /// 用户开始拖边缘调整大小：内容改成填满窗口
    func windowWillStartLiveResize(_ notification: Notification) {
        model.isFreeSized = true
    }

    // MARK: - 尺寸与位置

    /// 内容在固定宽度下的理想高度
    private func fittingSize() -> CGSize {
        let fit = host.sizeThatFits(in: CGSize(width: TranslationView.width, height: 10_000))
        // 内容忽略了（隐藏的）标题栏区域，但测出的高度里仍算了它，要扣掉
        let titlebar = window.frame.height - window.contentLayoutRect.height
        return CGSize(width: TranslationView.width, height: max(ceil(fit.height - titlebar), 120))
    }

    /// 高度跟着内容变，顶边不动；超出屏幕底部时整体上移
    private func fitHeight() {
        guard !isClosed, !model.isFreeSized else { return }
        let size = fittingSize()
        var frame = window.frame
        guard abs(frame.height - size.height) > 0.5 else { return }
        frame.origin.y = frame.maxY - size.height
        frame.size.height = size.height
        if let visible = window.screen?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        window.setFrame(frame.integral, display: true, animate: false)
    }

    /// 优先放在选区右侧（顶端对齐），其次下方、左侧、上方；不挡住选区，不超出屏幕
    static func placement(for size: CGSize, near anchor: CGRect) -> CGRect {
        let gap: CGFloat = 10
        let screen = NSScreen.screen(containing: CGPoint(x: anchor.midX, y: anchor.midY)) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        let candidates = [
            CGRect(x: anchor.maxX + gap, y: anchor.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: anchor.minX, y: anchor.minY - gap - size.height, width: size.width, height: size.height),
            CGRect(x: anchor.minX - gap - size.width, y: anchor.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: anchor.minX, y: anchor.maxY + gap, width: size.width, height: size.height),
        ]
        func clamped(_ frame: CGRect) -> CGRect {
            var f = frame
            f.origin.x = min(max(f.minX, visible.minX + 4), visible.maxX - f.width - 4)
            f.origin.y = min(max(f.minY, visible.minY + 4), visible.maxY - f.height - 4)
            return f
        }
        let fitting = candidates.first { visible.contains($0) }
        return clamped(fitting ?? candidates[0]).integral
    }

    // MARK: - 复制

    private func copy(_ text: String, hint: String) {
        guard !text.isEmpty else { return }
        let pasteboard = Self.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        hud?.close()
        let hud = RecognitionHUD(around: window.frame)
        hud.showMessage(hint, symbol: "checkmark.circle.fill")
        self.hud = hud
    }

    // MARK: - 关闭

    private func installMonitors() {
        // 点击窗口外面（其他 App 或 Snap 的其他窗口）就关闭；正在显示下载提示时不关
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside(reason: "点击了其他 App") }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocal(event) ?? event }
        }) { monitors.append(local) }
    }

    /// Snap 自己收到的事件：点别的窗口关闭；在结果窗口里按 Esc 关闭、编辑快捷键（Snap 没有「编辑」菜单）
    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        guard !isClosed else { return event }
        if event.type != .keyDown {
            if event.window !== window, event.window?.sheetParent !== window {
                clickedOutside(reason: "点击了 Snap 的其他窗口")
            }
            return event
        }
        guard event.window === window else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 53, modifiers.isEmpty {
            // 输入法正在组字时 Esc 交给输入法；钉住的窗口按 Esc 也关闭
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            close(reason: "Esc")
            return nil
        }
        guard modifiers == .command || modifiers == [.command, .shift] else { return event }
        let key = event.charactersIgnoringModifiers?.lowercased()
        // 结果窗口自己的快捷键
        switch (key, modifiers) {
        case ("c", .command):
            // 选中了文字时复制选中的文字（标准行为），否则复制译文
            if let editor = window.firstResponder as? NSTextView, editor.selectedRange().length > 0 { break }
            copy(model.translation, hint: "已复制译文")
            return nil
        case ("c", [.command, .shift]):
            copy(model.sourceText, hint: "已复制原文")
            return nil
        case ("r", .command):
            model.translate()
            return nil
        case ("p", .command):
            setPinned(!model.isPinned)
            return nil
        default:
            break
        }
        let action: Selector? = switch (key, modifiers) {
        case ("c", .command): #selector(NSText.copy(_:))
        case ("v", .command): #selector(NSText.paste(_:))
        case ("x", .command): #selector(NSText.cut(_:))
        case ("a", .command): #selector(NSText.selectAll(_:))
        case ("z", .command): Selector(("undo:"))
        case ("z", [.command, .shift]): Selector(("redo:"))
        default: nil
        }
        guard let action else { return event }
        return NSApp.sendAction(action, to: nil, from: window) ? nil : event
    }

    /// 点了窗口外面：没钉住就关闭（显示下载提示时不关）；钉住的不动
    private func clickedOutside(reason: String) {
        guard !isClosed, !model.isPinned, window.attachedSheet == nil else { return }
        close(reason: reason)
    }

    func close(reason: String = "新的识别结果") {
        guard !isClosed else { return }
        isClosed = true
        Log.capture.notice("截屏翻译：结果窗口关闭（\(reason, privacy: .public)）")
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        changes = nil
        Speaker.shared.stop()
        window.orderOut(nil)
        window.contentViewController = nil
        onClose?()
    }

    #if DEBUG
    func debugPressEscape() {
        _ = handleLocal(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                         charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
    }
    /// 自测：模拟按下快捷键（例如 "p", [.command]）
    @discardableResult
    func debugPress(_ key: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: key,
                                     charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)!
        return handleLocal(event) == nil
    }
    func debugClickOutside() { clickedOutside(reason: "自测") }
    func debugCopyBoth() { copy(model.sourceText + "\n\n" + model.translation, hint: "已复制原文和译文") }
    var debugCopyHUD: RecognitionHUD? { hud }
    var debugWindow: NSWindow { window }
    #endif
}
