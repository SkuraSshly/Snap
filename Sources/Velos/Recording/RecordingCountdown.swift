import AppKit
import Carbon.HIToolbox

/// 开始录制前的 3 秒倒计时（温暖磨砂风格）：录制区域中央显示 3 → 2 → 1。
/// - Esc、录屏快捷键或点一下倒计时卡片：取消
/// - Enter / 空格：跳过倒计时立即开始
/// 倒计时窗口在开始录制前就关闭，而且属于 Velos，不会出现在视频里。
@MainActor
final class RecordingCountdown: NSPanel {
    enum Outcome { case finished, cancelled }

    private let card = FrostedPanel(cornerRadius: 34, blending: .behindWindow)
    private let numberLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "Esc 取消 · Enter 立即开始")
    private var remaining: Int
    private var timer: Timer?
    private var completion: ((Outcome) -> Void)?
    private let hotkey: Hotkey
    private static let cardSize = CGSize(width: 190, height: 150)
    /// 卡片周围留出画投影的空间：要比投影的范围大，否则投影被窗口边缘截断，会看到一圈淡淡的方框
    private static let shadowInset: CGFloat = 40

    init(seconds: Int, region: CGRect, hotkey: Hotkey, completion: @escaping (Outcome) -> Void) {
        remaining = seconds
        self.hotkey = hotkey
        self.completion = completion
        let size = Self.cardSize
        let inset = Self.shadowInset
        let frame = CGRect(x: (region.midX - size.width / 2 - inset).rounded(), y: (region.midY - size.height / 2 - inset).rounded(),
                           width: size.width + inset * 2, height: size.height + inset * 2)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let root = NSView(frame: CGRect(origin: .zero, size: frame.size))
        contentView = root
        card.frame = CGRect(x: inset, y: inset, width: size.width, height: size.height)
        root.addSubview(card)

        numberLabel.font = roundedFont(ofSize: 64, weight: .bold, monospacedDigits: true)
        numberLabel.alignment = .center
        numberLabel.wantsLayer = true
        numberLabel.frame = CGRect(x: 0, y: 46, width: size.width, height: 80)
        card.addSubview(numberLabel)
        hintLabel.font = roundedFont(ofSize: 11, weight: .medium)
        hintLabel.alignment = .center
        hintLabel.frame = CGRect(x: 0, y: 20, width: size.width, height: 16)
        card.addSubview(hintLabel)
        applyColors()
    }

    override var canBecomeKey: Bool { true }

    /// 显示并开始倒数
    func run() {
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        show(remaining)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            finish(.finished)
        } else {
            show(remaining)
        }
    }

    private func show(_ number: Int) {
        numberLabel.stringValue = "\(number)"
        // 每个数字淡入，节奏感更清楚
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.25
        fade.toValue = 1
        fade.duration = 0.25
        numberLabel.layer?.add(fade, forKey: "fade")
    }

    private func applyColors() {
        let palette = WarmPalette(for: card)
        numberLabel.textColor = palette.ink
        hintLabel.textColor = palette.secondaryInk
    }

    /// 结束倒计时（完成或取消），关闭窗口后回调
    func finish(_ outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        timer?.invalidate()
        timer = nil
        orderOut(nil)
        close()
        completion(outcome)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        switch Int(event.keyCode) {
        case kVK_Escape:
            finish(.cancelled)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            finish(.finished)
        case kVK_Space where modifiers.isEmpty:
            finish(.finished)
        default:
            if hotkey.matches(event), !event.isARepeat { finish(.cancelled) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        finish(.cancelled)
    }

    #if DEBUG
    var debugNumber: String { numberLabel.stringValue }
    #endif
}
