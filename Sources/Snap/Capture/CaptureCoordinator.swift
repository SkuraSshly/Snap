import AppKit

/// 截图 / 录屏的总调度：接收全局快捷键，决定是开始新的会话、交给当前会话处理，还是停止录制。
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var screenshotSession: ScreenshotSession?
    private var recordingSession: RecordingSelectionSession?

    private init() {}

    var screenshotHotkey: Hotkey { Preferences.shared.screenshotHotkey }
    var recordingHotkey: Hotkey { Preferences.shared.recordingHotkey }

    func hotkey(for action: HotkeyManager.Action) -> Hotkey {
        action == .screenshot ? screenshotHotkey : recordingHotkey
    }

    func start() {
        HotkeyManager.shared.onPress = { [weak self] action in
            self?.handleHotkey(action)
        }
        HotkeyManager.shared.bind(.screenshot, to: screenshotHotkey)
        HotkeyManager.shared.bind(.recording, to: recordingHotkey)
    }

    /// 更换快捷键：先检查冲突，通过后注册并保存。返回问题描述，nil 表示设置成功。
    func setHotkey(_ hotkey: Hotkey, for action: HotkeyManager.Action) -> String? {
        if let problem = HotkeyConflicts.problem(with: hotkey, for: action) { return problem }
        let old = self.hotkey(for: action)
        guard HotkeyManager.shared.bind(action, to: hotkey) else {
            HotkeyManager.shared.bind(action, to: old)
            return "\(hotkey.displayString) 已被其他程序占用。"
        }
        if action == .screenshot {
            Preferences.shared.screenshotHotkey = hotkey
        } else {
            Preferences.shared.recordingHotkey = hotkey
        }
        Log.hotkey.notice("\(action.title, privacy: .public)快捷键改为 \(hotkey.displayString, privacy: .public)")
        return nil
    }

    func handleHotkey(_ action: HotkeyManager.Action) {
        switch action {
        case .screenshot:
            if let session = screenshotSession {
                // 截图界面还没来得及出现时（正在冻屏），全局快捷键仍然有效，由这里转给会话切换模式
                session.toggleMode()
            } else if recordingSession == nil {
                // 录屏选区进行中不截图；录制过程中可以截图
                beginScreenshot()
            }
        case .recording:
            if let session = recordingSession {
                session.toggleMode()
            } else if screenshotSession == nil {
                switch RecordingManager.shared.state {
                case .idle: beginRecording()
                case .recording, .paused: Task { await RecordingManager.shared.stop() }   // 录制中（包括暂停时）按录屏快捷键 = 停止
                case .countingDown: RecordingManager.shared.cancelCountdown()
                case .starting, .stopping: break
                }
            }
        }
    }

    /// 开始截图。从菜单启动时传入一点延迟，等菜单淡出后再冻屏，避免把菜单截进去
    func beginScreenshot(delay: Duration = .zero) {
        guard screenshotSession == nil, recordingSession == nil else { return }
        guard PermissionManager.shared.ensureScreenRecording() else { return }

        let session = ScreenshotSession(hotkey: screenshotHotkey)
        session.onFinish = { [weak self] in
            self?.screenshotSession = nil
        }
        screenshotSession = session
        session.start(after: delay)
    }

    /// 开始录屏选区（录制中则不处理）
    func beginRecording(delay: Duration = .zero) {
        guard screenshotSession == nil, recordingSession == nil, RecordingManager.shared.state == .idle else { return }
        guard PermissionManager.shared.ensureScreenRecording() else { return }

        let session = RecordingSelectionSession(hotkey: recordingHotkey)
        session.onConfirm = { [weak session] target in
            guard let session else { return }
            RecordingManager.shared.start(target, from: session)
        }
        session.onFinish = { [weak self] in
            self?.recordingSession = nil
        }
        recordingSession = session
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            session.start()
        }
    }

    #if DEBUG
    var debugSession: ScreenshotSession? { screenshotSession }
    var debugRecordingSession: RecordingSelectionSession? { recordingSession }
    #endif
}
