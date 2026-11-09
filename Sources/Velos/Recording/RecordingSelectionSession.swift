import AppKit
import Carbon.HIToolbox

/// 录屏的目标区域
struct RecordingTarget {
    let displayID: CGDirectDisplayID
    /// 全局坐标（点），已对齐像素
    let rect: CGRect
    let screen: NSScreen
    let scale: CGFloat
}

/// 录屏选区：交互与截图一致（窗口识别、拖拽、控制点、方向键微调、⌥S 切换区域 / 全屏），区别是：
/// - 不冻屏，选区阶段下面是实时画面
/// - 选区用红色，以区别于截图
/// - 选区旁是录制选项条（系统声音、麦克风、指针、帧率）
@MainActor
final class RecordingSelectionSession: OverlayEventHandler {
    /// 按 Enter（或点「开始录制」）时回调
    var onConfirm: ((RecordingTarget) -> Void)?
    var onFinish: (() -> Void)?

    private let hotkey: Hotkey
    private(set) var mode: CaptureMode = .region

    private var overlays: [CGDirectDisplayID: OverlayWindow] = [:]
    private var screens: [CGDirectDisplayID: NSScreen] = [:]
    private var activeDisplayID: CGDirectDisplayID = 0
    private var mousePoint = NSEvent.mouseLocation

    private let selector = RegionSelector()
    private let hint = HintBar(blending: .behindWindow)   // 下面是实时画面
    private let optionsBar = RecordingOptionsBar()

    private(set) var isFinished = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var previousApp: NSRunningApplication?
    private var isWatchingDeactivation = false

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
        optionsBar.onStart = { [weak self] in self?.confirm() }
        optionsBar.onChange = { [weak self] in self?.refresh() }
    }

    // MARK: - 开始与结束

    func start() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == .current ? nil : frontmost
        mousePoint = NSEvent.mouseLocation
        activeDisplayID = NSScreen.underMouse?.displayID ?? 0
        observe(NSApplication.didChangeScreenParametersNotification) { $0.cancel() }

        // 不冻屏：直接在每块屏幕上盖透明遮罩
        selector.windows = WindowList.snapshot(includingOwn: ScreenFreezer.capturableOwnWindows)
        for screen in NSScreen.screens {
            let id = screen.displayID
            screens[id] = screen
            selector.screens[id] = .init(frame: screen.frame, scale: screen.backingScaleFactor)
            let window = OverlayWindow(screen: screen)
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                   image: nil, scale: screen.backingScaleFactor, accent: OverlayAccent.recording)
            view.handler = self
            window.handler = self
            window.contentView = view
            overlays[id] = window
        }
        selector.mouseMoved(to: mousePoint)
        refresh()
        for (id, window) in overlays where id != activeDisplayID { window.orderFrontRegardless() }
        overlays[activeDisplayID]?.makeKeyAndOrderFront(nil)
        HotkeyManager.shared.suspend(.recording)   // 之后的 ⌥S 由遮罩窗口自己处理
        activateForCursor()
        Log.capture.notice("录屏选区已出现")
    }

    func cancel() {
        guard !isFinished else { return }
        Log.capture.notice("录屏已取消")
        finish()
    }

    /// 先把遮罩藏起来（开始录制时画面里立刻看不到遮罩），稍后再由 finish() 真正关闭
    func hideOverlays() {
        isHandingOff = true   // 遮罩藏起来会失去焦点，这不是「被切走」，不能触发自动取消
        for window in overlays.values { window.orderOut(nil) }
    }

    /// 已确认开始录制、正在交给录制模块
    private var isHandingOff = false

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        hint.remove()
        optionsBar.removeFromSuperview()
        for window in overlays.values {
            window.handler = nil
            (window.contentView as? OverlayView)?.handler = nil
            window.orderOut(nil)
            window.close()
        }
        overlays.removeAll()
        NSCursor.arrow.set()
        HotkeyManager.shared.resume(.recording)
        restorePreviousApp()
        onFinish?()
    }

    // MARK: - 前台切换（与截图相同：前台 App 才能显示十字准星，结束后把焦点还回去）

    private var isFrontmost: Bool { NSWorkspace.shared.frontmostApplication == .current }

    private func activateForCursor() {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, !self.isFinished, !self.isHandingOff, let app else { return }
                if app == .current {
                    self.isWatchingDeactivation = true
                    self.overlayCursor(at: self.mousePoint).set()
                } else if self.isWatchingDeactivation {
                    Log.capture.notice("其他 App 切到前台，取消录屏选区")
                    self.cancel()
                }
            }
        }
        observers.append((center, token))
        NSApp.activate()
    }

    private func observe(_ name: Notification.Name, _ action: @escaping (RecordingSelectionSession) -> Void) {
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isFinished else { return }
                action(self)
            }
        }
        observers.append((NotificationCenter.default, token))
    }

    private func restorePreviousApp() {
        guard isFrontmost, let previousApp, !previousApp.isTerminated else { return }
        NSApp.yieldActivation(to: previousApp)
        previousApp.activate(from: .current, options: [])
    }

    // MARK: - 模式切换与确认

    func toggleMode() {
        guard !isFinished else { return }
        mode.toggle()
        selector.cancelInteraction()
        Log.capture.notice("录屏切换到\(self.mode == .region ? "区域" : "全屏", privacy: .public)模式")
        refresh()
        overlayCursor(at: mousePoint).set()
    }

    /// Enter / 「开始录制」：区域模式录选区（没有选区录高亮的窗口），全屏模式录鼠标所在的屏幕
    func confirm() {
        guard !isFinished else { return }
        let target: (rect: CGRect, displayID: CGDirectDisplayID)
        switch mode {
        case .region:
            guard let regionTarget = selector.target else { return }   // 什么都没选：不做任何事
            target = regionTarget
        case .fullscreen:
            guard let screen = screens[activeDisplayID] else { return }
            target = (screen.frame, activeDisplayID)
        }
        guard let screen = screens[target.displayID] else { return }
        onConfirm?(RecordingTarget(displayID: target.displayID, rect: target.rect, screen: screen,
                                   scale: screen.backingScaleFactor))
    }

    // MARK: - 界面刷新

    private func refresh() {
        for (id, window) in overlays {
            guard let view = window.contentView as? OverlayView, let screen = screens[id] else { continue }
            var state = OverlayState(mode: mode, isActiveScreen: id == activeDisplayID)
            if mode == .region {
                if let selection = selector.selection, selector.selectionDisplayID == id {
                    state.region = selection
                    state.regionStyle = .selection
                } else if selector.selection == nil, let window = selector.hoveredWindow, selector.hoveredDisplayID == id {
                    state.region = window
                    state.regionStyle = .window
                }
                if let region = state.region {
                    state.regionPixelSize = CGSize(width: region.width * screen.backingScaleFactor,
                                                   height: region.height * screen.backingScaleFactor)
                    state.region = region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                }
            }
            view.apply(state)
        }
        placeOptionsBar()
        placeHint()
    }

    /// 选项条：区域模式在选区下方右对齐（放不下放上方，再不行放选区内）；全屏模式在屏幕底部中央
    private func placeOptionsBar() {
        let targetID = mode == .region ? selector.selectionDisplayID : activeDisplayID
        guard let id = targetID, let screen = screens[id], let view = overlays[id]?.contentView,
              mode == .fullscreen || (selector.selection != nil && !selector.isInteracting) else {
            optionsBar.removeFromSuperview()
            return
        }
        optionsBar.refresh()
        if optionsBar.superview !== view {
            optionsBar.removeFromSuperview()
            view.addSubview(optionsBar)
        }
        let bounds = view.bounds
        let size = optionsBar.frame.size
        var frame: CGRect
        if mode == .region, let selection = selector.selection {
            let s = selection.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            frame = CGRect(x: s.maxX - size.width, y: s.minY - 8 - size.height, width: size.width, height: size.height)
            if frame.minY < bounds.minY + 4 {
                frame.origin.y = s.maxY + 30
                if frame.maxY > bounds.maxY - 4 { frame.origin.y = s.minY + 8 }
            }
        } else {
            frame = CGRect(x: (bounds.width - size.width) / 2, y: 28, width: size.width, height: size.height)
        }
        frame.origin.x = min(max(frame.minX, bounds.minX + 4), bounds.maxX - size.width - 4)
        optionsBar.setFrameOrigin(CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded()))
    }

    private func placeHint() {
        guard let view = overlays[activeDisplayID]?.contentView, let screen = screens[activeDisplayID] else { return }
        let key = hotkey.displayString
        switch mode {
        case .region:
            hint.setContent(title: "区域录屏", items: ["\(key) 切换全屏", "Enter 开始", "Esc 取消"])
        case .fullscreen:
            hint.setContent(title: "全屏录屏", items: ["\(key) 切换区域", "Enter 开始", "Esc 取消"])
        }
        let origin = screen.frame.origin
        var avoid: [CGRect] = []
        if mode == .region, let selection = selector.selection, selector.selectionDisplayID == activeDisplayID {
            avoid.append(selection.offsetBy(dx: -origin.x, dy: -origin.y))
        }
        if optionsBar.superview === view { avoid.append(optionsBar.frame) }
        avoid.append(CGRect(x: mousePoint.x - origin.x - 16, y: mousePoint.y - origin.y - 16, width: 32, height: 32))
        hint.place(in: view, screen: screen, avoiding: avoid)
    }

    private func track(_ point: NSPoint) {
        mousePoint = point
        if let id = NSScreen.screen(containing: point)?.displayID, screens[id] != nil {
            activeDisplayID = id
        }
    }

    // MARK: - OverlayEventHandler：键盘

    func overlayKeyDown(_ event: NSEvent) -> Bool {
        guard !isFinished else { return false }
        let arrowKeys = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
        // 按住不放的自动重复：除方向键外一律忽略
        if event.isARepeat && !arrowKeys.contains(Int(event.keyCode)) { return true }
        if hotkey.matches(event) {
            toggleMode()
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape:
            // 下拉菜单开着时 Esc 只关菜单
            if !optionsBar.closeMenu() { cancel() }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            confirm()
        case let key where arrowKeys.contains(key) && mode == .region:
            guard modifiers.subtracting(.shift).isEmpty else { return false }
            let step = modifiers.contains(.shift) ? 10 : 1
            let (dx, dy) = switch key {
            case kVK_LeftArrow: (-step, 0)
            case kVK_RightArrow: (step, 0)
            case kVK_UpArrow: (0, step)
            default: (0, -step)
            }
            if selector.nudge(dxPixels: dx, dyPixels: dy) { refresh() }
        default:
            return false
        }
        return true
    }

    func overlayShouldIntercept(_ event: NSEvent) -> Bool { false }

    func overlayDidResignKey() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isFinished, !self.isHandingOff else { return }
            if !self.overlays.values.contains(where: { $0.isKeyWindow }) {
                Log.capture.notice("录屏选区失去焦点，自动取消")
                self.cancel()
            }
        }
    }

    // MARK: - OverlayEventHandler：鼠标

    func overlayCursor(at point: NSPoint) -> NSCursor {
        if let view = optionsBar.superview, let window = view.window,
           optionsBar.frame.contains(view.convert(window.convertPoint(fromScreen: point), from: nil)) {
            return .arrow
        }
        return mode == .region ? selector.cursor(at: point) : .arrow
    }

    func overlayMouseMoved(to point: NSPoint) {
        track(point)
        if mode == .region { selector.mouseMoved(to: point) }
        refresh()
    }

    func overlayMouseDown(at point: NSPoint) {
        track(point)
        guard mode == .region else { return }
        selector.mouseDown(at: point)
        refresh()
    }

    func overlayMouseDragged(to point: NSPoint) {
        track(point)
        guard mode == .region else { return }
        selector.mouseDragged(to: point)
        refresh()
    }

    func overlayMouseUp(at point: NSPoint) {
        track(point)
        guard mode == .region else { return }
        selector.mouseUp(at: point)
        refresh()
    }

    func overlayRightMouseDown(at point: NSPoint) {
        track(point)
        if mode == .region, selector.selection != nil {
            selector.clearSelection(at: point)
            refresh()
        } else {
            cancel()
        }
    }

    #if DEBUG
    var debugSelector: RegionSelector { selector }
    var debugOptionsBar: RecordingOptionsBar { optionsBar }
    var debugHintText: String { hint.view.debugText }
    var debugOverlayCount: Int { overlays.count }
    #endif
}
