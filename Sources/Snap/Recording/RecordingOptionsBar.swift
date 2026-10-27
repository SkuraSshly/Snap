import AppKit
import AVFoundation

/// 录制选项条（温暖磨砂风格，见 WarmStyle）：
/// [系统声音][麦克风 ▾][指针] | [30 | 60] | [● 开始录制]
/// 选项直接读写设置，下次录屏沿用上次的选择，不需要每次重新设置。
final class RecordingOptionsBar: NSView {
    var onStart: (() -> Void)?
    var onChange: (() -> Void)?

    /// 录屏界面下面是实时画面：磨砂效果虚化窗口后面的屏幕
    private let blending: NSVisualEffectView.BlendingMode
    private let panel: FrostedPanel
    private let systemAudioButton = ToolbarButton(symbol: "speaker.wave.2.fill", help: "录制系统声音")
    private let microphoneButton = ToolbarButton(symbol: "mic.fill", help: "录制麦克风")
    private let deviceButton = ToolbarButton(symbol: "chevron.down", help: "选择麦克风")
    private let cursorButton = ToolbarButton(symbol: "cursorarrow", help: "录制鼠标指针")
    private let frameRate = SegmentedPill(titles: ["30", "60"], help: "帧率（帧 / 秒）")
    private let startButton = PillButton(title: "开始录制", symbol: "record.circle", color: WarmPalette.coral,
                                         help: "开始录制（Enter）")
    private var deviceMenu: WarmMenu?

    private static let buttonSize: CGFloat = 32
    private static let spacing: CGFloat = 2
    private static let padding: CGFloat = 5

    init(blending: NSVisualEffectView.BlendingMode = .behindWindow) {
        self.blending = blending
        panel = FrostedPanel(blending: blending)
        super.init(frame: .zero)
        addSubview(panel)

        systemAudioButton.action = { [weak self] in self?.toggleSystemAudio() }
        microphoneButton.action = { [weak self] in self?.toggleMicrophone() }
        deviceButton.action = { [weak self] in self?.showDeviceMenu() }
        cursorButton.action = { [weak self] in self?.toggleCursor() }
        frameRate.onSelect = { [weak self] index in self?.setFrameRate(index == 0 ? .fps30 : .fps60) }
        startButton.action = { [weak self] in self?.onStart?() }

        var x = Self.padding + 2
        func add(_ view: NSView, width: CGFloat) {
            view.frame = CGRect(x: x, y: Self.padding, width: width, height: Self.buttonSize)
            panel.addSubview(view)
            x += width + Self.spacing
        }
        func separator() {
            panel.addSubview(WarmSeparator(frame: CGRect(x: x + 5, y: Self.padding + 8, width: 1.5, height: Self.buttonSize - 16)))
            x += 13
        }
        add(systemAudioButton, width: Self.buttonSize)
        add(microphoneButton, width: Self.buttonSize)
        add(deviceButton, width: 20)
        add(cursorButton, width: Self.buttonSize)
        separator()
        add(frameRate, width: 76)
        separator()
        add(startButton, width: startButton.fittingWidth)
        let size = CGSize(width: x - Self.spacing + Self.padding + 2, height: Self.buttonSize + Self.padding * 2)
        setFrameSize(size)
        panel.frame = CGRect(origin: .zero, size: size)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 按设置刷新各按钮的状态
    @MainActor
    func refresh() {
        let prefs = Preferences.shared
        systemAudioButton.isSelected = prefs.recordSystemAudio
        systemAudioButton.setSymbol(prefs.recordSystemAudio ? "speaker.wave.2.fill" : "speaker.slash")
        microphoneButton.isSelected = prefs.recordMicrophone
        microphoneButton.setSymbol(prefs.recordMicrophone ? "mic.fill" : "mic.slash")
        microphoneButton.toolTip = "录制麦克风：\(AudioDevices.name(for: prefs.microphoneDeviceID))"
        cursorButton.isSelected = prefs.recordingShowsCursor
        cursorButton.setSymbol(prefs.recordingShowsCursor ? "cursorarrow" : "cursorarrow.slash")
        frameRate.selectedIndex = prefs.recordingFrameRate == .fps30 ? 0 : 1
    }

    /// 关闭下拉菜单；原本是打开的就返回 true（Esc 先关菜单，不退出录屏选区）
    @discardableResult
    func closeMenu() -> Bool {
        guard let deviceMenu, deviceMenu.isOpen else { return false }
        deviceMenu.close()
        self.deviceMenu = nil
        return true
    }

    override func removeFromSuperview() {
        closeMenu()
        super.removeFromSuperview()
    }

    // MARK: - 操作

    @MainActor
    private func toggleSystemAudio() {
        Preferences.shared.recordSystemAudio.toggle()
        changed()
    }

    @MainActor
    private func toggleMicrophone() {
        let prefs = Preferences.shared
        if prefs.recordMicrophone {
            prefs.recordMicrophone = false
        } else {
            enableMicrophone()
        }
        changed()
    }

    /// 打开麦克风：没有权限时先请求（被拒绝过则引导到系统设置，开关保持关闭）
    @MainActor
    private func enableMicrophone() {
        let permissions = PermissionManager.shared
        permissions.refresh()
        switch permissions.microphoneStatus {
        case .authorized:
            Preferences.shared.recordMicrophone = true
        case .notDetermined:
            Preferences.shared.recordMicrophone = true
            permissions.requestMicrophone()
        default:
            permissions.requestMicrophone()   // 跳到系统设置
        }
    }

    @MainActor
    private func toggleCursor() {
        Preferences.shared.recordingShowsCursor.toggle()
        changed()
    }

    @MainActor
    private func setFrameRate(_ rate: RecordingFrameRate) {
        Preferences.shared.recordingFrameRate = rate
        changed()
    }

    /// 麦克风设备菜单：系统默认 + 所有输入设备；选中后自动打开麦克风
    @MainActor
    private func showDeviceMenu() {
        if closeMenu() { return }
        guard let host = superview else { return }
        let current = Preferences.shared.microphoneDeviceID
        let devices = [("", "系统默认（\(AudioDevices.defaultDeviceName)）")]
            + AudioDevices.all().map { ($0.uniqueID, $0.localizedName) }
        let items = devices.map { WarmMenu.Item(id: $0.0, title: $0.1, isSelected: $0.0 == current) }
        let anchor = convert(deviceButton.frame, from: panel)
        deviceMenu = WarmMenu.show(items: items, in: host, anchor: convert(anchor, to: host), blending: blending) { [weak self] id in
            Preferences.shared.microphoneDeviceID = id
            self?.enableMicrophone()
            self?.changed()
        }
    }

    @MainActor
    private func changed() {
        refresh()
        onChange?()
    }

    #if DEBUG
    @MainActor func debugToggleCursor() { toggleCursor() }
    @MainActor func debugSetFrameRate(_ rate: RecordingFrameRate) { setFrameRate(rate) }
    @MainActor func debugShowDeviceMenu() { showDeviceMenu() }
    var debugMenuFrame: CGRect? { deviceMenu?.isOpen == true ? deviceMenu?.frame : nil }
    #endif
}

/// 麦克风输入设备
enum AudioDevices {
    static func all() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static var defaultDeviceName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "无"
    }

    static func name(for uniqueID: String) -> String {
        if uniqueID.isEmpty { return "系统默认" }
        return all().first { $0.uniqueID == uniqueID }?.localizedName ?? "系统默认"
    }
}
