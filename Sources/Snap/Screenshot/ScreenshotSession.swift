import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

/// 一次截图操作，从按下快捷键到按 Enter 完成或按 Esc 取消。
///
/// 流程：
/// 1. 冻屏：记下窗口位置，并以原生分辨率截下所有屏幕（鼠标所在的那块优先），每块屏幕盖一个遮罩窗口显示冻结画面
/// 2. 遮罩出现并成为焦点窗口后，暂停全局快捷键，之后的 ⌥A 由遮罩窗口自己处理，避免重复触发
/// 3. 冻屏完成后再把 Snap 切到前台：macOS 只允许前台 App 改变鼠标指针（十字准星），
///    此时底图已经截好，当前 App 失去焦点（比如关掉弹出菜单）不会影响截图内容
/// 4. 区域模式：悬停识别窗口、拖拽 / 单击选取、控制点调整、方向键微调（见 RegionSelector），旁边有放大镜
/// 5. ⌥A（真正的按下，忽略按住不放的重复）在「区域 ↔ 全屏」之间切换，次数不限，选区保留
/// 6. Enter 从冻结的底图裁剪出结果；Esc 随时取消；结束后把焦点还给原来的 App
///
/// 截屏翻译（⌥D）也用这一套界面，区别是：没有标注工具栏和放大镜；松开鼠标（拖出选区或单击窗口）立即识别，
/// 全屏模式按 Enter 识别整块屏幕；结果交给 onTranslate。
@MainActor
final class ScreenshotSession: OverlayEventHandler {
    enum Purpose { case screenshot, translate }

    var onFinish: (() -> Void)?
    /// 截屏翻译：选好区域后回调（这时界面已经关闭）
    var onTranslate: ((FrozenDisplay.Crop) -> Void)?
    /// 长截图：点了工具栏的「长截图」（这时界面已经关闭），参数是选区（全局坐标）和所在屏幕
    var onLongCapture: ((CGRect, NSScreen) -> Void)?

    let purpose: Purpose
    private var isTranslating: Bool { purpose == .translate }
    private var hotkeyAction: HotkeyManager.Action { isTranslating ? .translate : .screenshot }
    private let hotkey: Hotkey
    private(set) var mode: CaptureMode = .region

    private var displays: [CGDirectDisplayID: FrozenDisplay] = [:]
    private var overlays: [CGDirectDisplayID: OverlayWindow] = [:]
    /// 鼠标所在的屏幕：全屏模式截取这一块，提示条也显示在这一块上
    private var activeDisplayID: CGDirectDisplayID = 0
    /// 最近一次鼠标位置（全局坐标）
    private var mousePoint = NSEvent.mouseLocation

    private let selector = RegionSelector()
    private let magnifier = MagnifierView()
    private let hint = HintBar()

    /// 标注：工具栏在选区旁（全屏模式在屏幕底部中央）；标注画在冻结底图上，选区只决定最后裁剪哪一块
    private let toolbar = AnnotationToolbar(showsLongCapture: true)
    private var annotator: AnnotationController?
    private var annotatorDisplayID: CGDirectDisplayID?

    /// 这次按下鼠标由谁处理（拖拽、松开时交给同一个对象）
    private enum MouseOwner { case none, selector, annotator }
    private var mouseOwner = MouseOwner.none

    private var isFinished = false
    private var startTime = ContinuousClock.now
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// 截图前正在使用的 App，结束后把焦点还给它
    private var previousApp: NSRunningApplication?
    private var isWatchingDeactivation = false

    init(hotkey: Hotkey, purpose: Purpose = .screenshot) {
        self.hotkey = hotkey
        self.purpose = purpose
        toolbar.onSelectTool = { [weak self] tool in self?.selectTool(tool) }
        toolbar.onSelectColor = { [weak self] color in self?.updateStyle { $0.color = color } }
        toolbar.onSelectSize = { [weak self] size in self?.updateStyle { $0.size = size } }
        toolbar.onSelectOpacity = { [weak self] opacity in self?.updateStyle { $0.opacity = opacity } }
        toolbar.onPickColor = { [weak self] color, opacity in
            self?.updateStyle {
                $0.color = color
                if let opacity { $0.opacity = min(max(opacity, 0.1), 1) }
            }
        }
        toolbar.onAction = { [weak self] action in self?.perform(action) }
    }

    // MARK: - 开始与结束

    func start(after delay: Duration) {
        startTime = .now
        activeDisplayID = NSScreen.underMouse?.displayID ?? 0
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == .current ? nil : frontmost
        // 截图过程中如果显示器配置变了（插拔外接屏、改分辨率），底图就对不上了，直接取消
        observe(NSApplication.didChangeScreenParametersNotification) { $0.cancel() }
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            await freezeScreens()
        }
    }

    private func freezeScreens() async {
        guard let mouseScreen = NSScreen.underMouse else { return cancel() }
        activeDisplayID = mouseScreen.displayID
        mousePoint = NSEvent.mouseLocation

        #if DEBUG
        // 界面自测：用合成图代替真实屏幕，不读取用户屏幕内容
        if let synthetic = DebugUITest.syntheticScreen(for: mouseScreen) {
            selector.windows = synthetic.windows
            present(synthetic.frozen, isPrimary: true)
            return
        }
        #endif

        // 窗口位置和屏幕画面在同一时刻取得，悬停识别的窗口与冻结画面对得上
        selector.windows = WindowList.snapshot(includingOwn: ScreenFreezer.capturableOwnWindows)
        do {
            let content = try await ScreenFreezer.shareableContent()
            guard !isFinished else { return }
            let excluded = ScreenFreezer.ownWindows(in: content)
            let showsCursor = Preferences.shared.screenshotIncludesCursor

            // 所有屏幕同时开始截取，鼠标所在的那块排在最前，一截好就立即显示
            let screens = [mouseScreen] + NSScreen.screens.filter { $0.displayID != mouseScreen.displayID }
            let captures = screens.map { screen in
                Task { try await ScreenFreezer.capture(screen, content: content, excluding: excluded, showsCursor: showsCursor) }
            }
            let primary = try await captures[0].value
            guard !isFinished else { return }
            present(primary, isPrimary: true)

            // 其他屏幕截取失败不影响当前屏幕的截图，只是那块屏幕不显示遮罩
            for capture in captures.dropFirst() {
                do {
                    let frozen = try await capture.value
                    guard !isFinished else { return }
                    present(frozen, isPrimary: false)
                } catch {
                    Log.capture.error("副屏冻屏失败：\(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            guard !isFinished else { return }
            Log.capture.error("冻屏失败：\(error.localizedDescription, privacy: .public)")
            finish()
            showFailure(error)
        }
    }

    /// 为一块冻结好的屏幕创建遮罩窗口
    private func present(_ frozen: FrozenDisplay, isPrimary: Bool) {
        displays[frozen.displayID] = frozen
        selector.screens[frozen.displayID] = .init(frame: frozen.screen.frame, scale: frozen.scale)
        selector.mouseMoved(to: mousePoint)

        let window = OverlayWindow(screen: frozen.screen)
        let view = OverlayView(frame: NSRect(origin: .zero, size: frozen.screen.frame.size),
                               image: frozen.image, scale: frozen.scale,
                               accent: isTranslating ? OverlayAccent.translate : OverlayAccent.screenshot)
        view.handler = self
        window.handler = self
        window.contentView = view
        overlays[frozen.displayID] = window
        refresh()

        if isPrimary {
            window.makeKeyAndOrderFront(nil)
            // 遮罩已是焦点窗口，后面的 ⌥A（截屏翻译是 ⌥D）交给它自己处理
            HotkeyManager.shared.suspend(hotkeyAction)
            let elapsed = ContinuousClock.now - startTime
            Log.capture.notice("截图界面已出现，耗时 \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)，\(frozen.image.width)×\(frozen.image.height) 像素")
            activateForCursor()
            #if DEBUG
            // 调试：SNAP_AUTOCANCEL=秒数 时自动取消，用来验证退出后焦点是否回到原来的 App
            if let seconds = Double(ProcessInfo.processInfo.environment["SNAP_AUTOCANCEL"] ?? "") {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.cancel() }
            }
            #endif
        } else {
            window.orderFrontRegardless()
        }
    }

    private func cancel() {
        guard !isFinished else { return }
        Log.capture.notice("\(self.isTranslating ? "截屏翻译" : "截图", privacy: .public)已取消")
        finish()
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        hint.remove()
        magnifier.removeFromSuperview()
        toolbar.removeFromSuperview()
        annotator?.layer.removeFromSuperlayer()
        annotator = nil
        for window in overlays.values {
            window.handler = nil
            (window.contentView as? OverlayView)?.handler = nil
            window.orderOut(nil)
            window.close()
        }
        overlays.removeAll()
        displays.removeAll()   // 释放底图（每块屏幕十几到二十几 MB）
        NSCursor.arrow.set()
        HotkeyManager.shared.resume(hotkeyAction)
        restorePreviousApp()
        onFinish?()
    }

    private func showFailure(_ error: Error) {
        // 权限被收回时 ScreenCaptureKit 会报错：回到权限引导，而不是静默失败
        PermissionManager.shared.refresh()
        if !PermissionManager.shared.screenRecordingGranted {
            OnboardingWindowController.show()
            return
        }
        let alert = NSAlert()
        alert.messageText = "截图失败"
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }

    // MARK: - 前台切换

    /// Snap 是否真的是系统前台 App。
    /// 注意不能用 NSApp.isActive：不激活面板成为焦点窗口后它也会返回 true，但系统前台其实还是原来的 App。
    private var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication == .current
    }

    /// 把 Snap 切到前台，这样才能显示十字准星。
    /// 即使系统没有同意切换，遮罩仍是焦点窗口，键盘操作不受影响，只是指针保持箭头。
    private func activateForCursor() {
        observeWorkspace { session, app in
            if app == .current {
                session.didBecomeFrontmost()
            } else if session.isWatchingDeactivation {
                // 用户 ⌘Tab 切走或别的程序抢到前台后，键盘就到不了截图界面了，取消截图，避免遮罩卡在屏幕上
                Log.capture.notice("其他 App 切到前台（\(app.localizedName ?? "?", privacy: .public)），自动取消截图")
                session.cancel()
            }
        }
        // 由快捷键触发时系统会同意切换（macOS 14 起是「协作式激活」，没有用户操作时可能被拒绝）
        NSApp.activate()
    }

    private func didBecomeFrontmost() {
        guard !isFinished, !isWatchingDeactivation else { return }
        isWatchingDeactivation = true
        overlayCursor(at: mousePoint).set()
        Log.capture.notice("Snap 已成为前台 App")
    }

    /// 注册通知，会话结束时统一移除
    private func observe(_ name: Notification.Name, _ action: @escaping (ScreenshotSession) -> Void) {
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isFinished else { return }
                action(self)
            }
        }
        observers.append((NotificationCenter.default, token))
    }

    /// 监听「哪个 App 成为了前台」（系统级通知，比 NSApp.isActive 可靠）
    private func observeWorkspace(_ action: @escaping (ScreenshotSession, NSRunningApplication) -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, !self.isFinished, let app else { return }
                action(self, app)
            }
        }
        observers.append((center, token))
    }

    /// 截图结束后把焦点还给截图前正在使用的 App
    private func restorePreviousApp() {
        guard isFrontmost, let previousApp, !previousApp.isTerminated else { return }
        NSApp.yieldActivation(to: previousApp)
        previousApp.activate(from: .current, options: [])
    }

    // MARK: - 模式切换与完成

    func toggleMode() {
        guard !isFinished else { return }
        annotator?.endTextEditing()
        mode.toggle()
        selector.cancelInteraction()   // 拖拽到一半切换模式：结束这次拖拽，已有选区保留
        Log.capture.notice("切换到\(self.mode == .region ? "区域" : "全屏", privacy: .public)模式")
        refresh()
        overlayCursor(at: mousePoint).set()
    }

    /// 完成截图。save 为 true 时无论设置如何都保存文件（⌘S）
    private func complete(save: Bool = false) {
        guard let result = makeResult() else { return }
        finish()
        if isTranslating {
            Log.capture.notice("截屏翻译：识别 \(result.image.width)×\(result.image.height) 像素")
            onTranslate?(result)
            return
        }
        Log.capture.notice("截图完成：\(result.image.width)×\(result.image.height) 像素")
        ScreenshotOutput.deliver(result.image, scale: result.scale, sourceRect: result.sourceRect, forceSave: save)
    }

    /// 长截图：关掉截图界面（焦点还给原来的 App），交给长截图会话。要在画标注之前开始
    private func beginLongCapture() {
        guard mode == .region, annotator?.document.isEmpty != false,
              let target = selector.target, let frozen = displays[target.displayID] else { return }
        let screen = frozen.screen
        finish()
        onLongCapture?(target.rect, screen)
    }

    /// 钉图：把结果（含标注）直接钉在原位，不复制、不保存
    private func pinResult() {
        guard let result = makeResult() else { return }
        finish()
        _ = PinManager.shared.pin(CapturedImage(image: result.image, scale: result.scale, sourceRect: result.sourceRect))
    }

    /// 截图结果：区域模式截选区（没有选区截高亮窗口），全屏模式截鼠标所在的屏幕；有标注时合成进去
    private func makeResult() -> FrozenDisplay.Crop? {
        annotator?.endTextEditing()   // 还在输入的文字也算进去
        let target: (rect: CGRect, displayID: CGDirectDisplayID)
        switch mode {
        case .region:
            // 两者都没有时按 Enter 不做任何操作
            guard let regionTarget = selector.target else { return nil }
            target = regionTarget
        case .fullscreen:
            guard let frozen = displays[activeDisplayID] else { return nil }
            target = (frozen.screen.frame, activeDisplayID)
        }
        guard let frozen = displays[target.displayID] else { return nil }

        let image: CGImage?
        if let annotator, annotatorDisplayID == target.displayID, !annotator.document.isEmpty {
            let origin = frozen.screen.frame.origin
            image = annotator.composite(cropping: target.rect.offsetBy(dx: -origin.x, dy: -origin.y))
        } else {
            // 没有标注：直接裁剪原图，像素原封不动
            image = target.rect == frozen.screen.frame ? frozen.image : frozen.crop(target.rect)
        }
        guard let image else { return nil }
        return FrozenDisplay.Crop(image: image, scale: frozen.scale, sourceRect: target.rect)
    }

    // MARK: - 标注

    private func perform(_ action: AnnotationToolbar.Action) {
        switch action {
        case .undo: annotator?.undo()
        case .redo: annotator?.redo()
        case .pin: pinResult()
        case .save: complete(save: true)
        case .longCapture: beginLongCapture()
        case .cancel: cancel()
        case .done: complete()
        }
        if !isFinished { refresh() }
    }

    private func selectTool(_ tool: AnnotationTool?) {
        guard let annotator = prepareAnnotator() else { return }
        annotator.tool = tool
        refresh()
        overlayCursor(at: mousePoint).set()
    }

    private func updateStyle(_ change: (inout AnnotationStyle) -> Void) {
        // 从属性栏当前显示的样式改起（选中标注时显示的是它的样式）
        guard let annotator = prepareAnnotator() else { return }
        var style = annotator.displayedStyle
        change(&style)
        annotator.applyStyle(style)
        refresh()
    }

    /// 当前要标注的屏幕（区域模式是选区所在的屏幕，全屏模式是鼠标所在的屏幕）
    private var annotationTargetDisplayID: CGDirectDisplayID? {
        mode == .region ? selector.selectionDisplayID : activeDisplayID
    }

    /// 准备好目标屏幕的标注控制器。已经在另一块屏幕上画了标注时，不能换屏幕（返回那一块的）
    private func prepareAnnotator() -> AnnotationController? {
        guard let id = annotationTargetDisplayID, let frozen = displays[id],
              let view = overlays[id]?.contentView as? OverlayView else { return annotator }
        if let annotator, annotatorDisplayID == id || !annotator.document.isEmpty {
            return annotator
        }
        let previousTool = annotator?.tool
        annotator?.layer.removeFromSuperlayer()

        let controller = AnnotationController(base: BaseImage(image: frozen.image, scale: frozen.scale,
                                                              canvasHeight: frozen.screen.frame.height))
        controller.hostView = view
        controller.tool = previousTool
        controller.onChange = { [weak self] in self?.updateToolbar() }
        view.installAnnotationLayer(controller.layer)
        annotator = controller
        annotatorDisplayID = id
        updateCanvasBounds()
        return controller
    }

    /// 屏幕坐标 → 标注画布坐标（所在屏幕的局部坐标）
    private func canvasPoint(_ point: NSPoint) -> CGPoint? {
        guard let id = annotatorDisplayID, let frozen = displays[id] else { return nil }
        return CGPoint(x: point.x - frozen.screen.frame.minX, y: point.y - frozen.screen.frame.minY)
    }

    /// 工具栏位置：区域模式在选区下方右对齐（放不下就放上方，再不行放选区内）；全屏模式在屏幕底部中央
    private func updateToolbar() {
        // 截屏翻译没有标注工具栏
        if isTranslating {
            toolbar.removeFromSuperview()
            return
        }
        guard let id = annotationTargetDisplayID, let frozen = displays[id],
              let view = overlays[id]?.contentView,
              mode == .fullscreen || (selector.selection != nil && !selector.isInteracting) else {
            toolbar.removeFromSuperview()
            return
        }
        let annotator = prepareAnnotator()
        toolbar.update(tool: annotator?.tool, style: annotator?.displayedStyle ?? AnnotationStyle(),
                       canUndo: annotator?.document.canUndo ?? false, canRedo: annotator?.document.canRedo ?? false,
                       selectionTool: annotator?.selectedAnnotation?.tool,
                       canLongCapture: mode == .region && annotator?.document.isEmpty != false)
        if toolbar.superview !== view {
            toolbar.removeFromSuperview()
            view.addSubview(toolbar)
        }

        let bounds = view.bounds
        let size = toolbar.frame.size
        let origin = frozen.screen.frame.origin
        let margin: CGFloat = 8
        var frame: CGRect
        if mode == .region, let selection = selector.selection {
            let s = selection.offsetBy(dx: -origin.x, dy: -origin.y)
            frame = CGRect(x: s.maxX - size.width, y: s.minY - margin - size.height, width: size.width, height: size.height)
            if frame.minY < bounds.minY + 4 {
                // 下方放不下：放到选区上方（让出尺寸标签的位置）
                frame.origin.y = s.maxY + margin + 22
                if frame.maxY > bounds.maxY - 4 {
                    frame.origin.y = s.minY + margin   // 上下都放不下：放在选区内底部
                }
            }
        } else {
            frame = CGRect(x: (bounds.width - size.width) / 2, y: 28, width: size.width, height: size.height)
        }
        frame.origin.x = min(max(frame.minX, bounds.minX + 4), bounds.maxX - size.width - 4)
        toolbar.setFrameOrigin(CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded()))
    }

    /// 按 C：把放大镜中心像素的颜色值（sRGB 十六进制）复制到剪贴板
    private func copyColor() {
        guard isMagnifierVisible, let frozen = displays[activeDisplayID] else { return }
        let pixel = frozen.pixel(at: mousePoint)
        guard let color = frozen.color(atPixelX: pixel.x, y: pixel.y) else { return }
        var pasteboard = NSPasteboard.general
        #if DEBUG
        if ScreenshotOutput.dryRun { pasteboard = NSPasteboard(name: .init("local.snap.selftest")) }
        #endif
        pasteboard.clearContents()
        pasteboard.setString(color.hex, forType: .string)
        magnifier.showCopied()
        Log.capture.notice("已复制颜色 \(color.hex, privacy: .public)")
    }

    // MARK: - 界面刷新

    /// 放大镜只在需要对准像素时出现：还没有选区（悬停 / 准备拖拽），或正在拖出选区、拖动控制点（选着标注工具时也是）
    private var isMagnifierVisible: Bool {
        !isTranslating && mode == .region && displays[activeDisplayID] != nil
            && (annotator?.tool == nil || selector.isSizing)
            && (selector.selection == nil || selector.isSizing)
    }

    /// 标注的范围：区域模式是选区，全屏模式是整块屏幕。只能在这里面画，标注也只显示这里面的部分（和输出的图片一致）。
    /// 每次刷新都更新：拖选区的控制点时，标注随选区实时裁剪
    private func updateCanvasBounds() {
        guard let annotator, let id = annotatorDisplayID, let frozen = displays[id] else { return }
        let screen = frozen.screen.frame
        if mode == .fullscreen {
            annotator.canvasBounds = CGRect(origin: .zero, size: screen.size)
        } else if let selection = selector.selection {
            annotator.canvasBounds = selection.offsetBy(dx: -screen.minX, dy: -screen.minY)
        }
    }

    private func refresh() {
        updateCanvasBounds()
        for (id, window) in overlays {
            guard let view = window.contentView as? OverlayView, let frozen = displays[id] else { continue }
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
                    state.regionPixelSize = CGSize(width: region.width * frozen.scale, height: region.height * frozen.scale)
                    let origin = frozen.screen.frame.origin
                    state.region = region.offsetBy(dx: -origin.x, dy: -origin.y)
                }
            }
            view.apply(state)
        }
        updateMagnifier()
        updateToolbar()
        placeHint()
    }

    private func updateMagnifier() {
        guard isMagnifierVisible, let frozen = displays[activeDisplayID],
              let view = overlays[activeDisplayID]?.contentView else {
            magnifier.removeFromSuperview()
            return
        }
        if magnifier.superview !== view {
            magnifier.removeFromSuperview()
            view.addSubview(magnifier)
        }
        let pixel = frozen.pixel(at: mousePoint)
        magnifier.update(image: frozen.image, pixelX: pixel.x, pixelY: pixel.y, scale: frozen.scale,
                         color: frozen.color(atPixelX: pixel.x, y: pixel.y))
        let origin = frozen.screen.frame.origin
        magnifier.place(near: CGPoint(x: mousePoint.x - origin.x, y: mousePoint.y - origin.y), in: view.bounds)
    }

    private func placeHint() {
        guard let window = overlays[activeDisplayID], let view = window.contentView,
              let frozen = displays[activeDisplayID] else { return }
        let key = hotkey.displayString
        switch (mode, isTranslating) {
        case (.region, false):
            hint.setContent(title: "区域截图", items: ["\(key) 切换全屏", "Enter 完成", "Esc 取消"])
        case (.fullscreen, false):
            hint.setContent(title: "全屏截图", items: ["\(key) 切换区域", "Enter 完成", "Esc 取消"])
        case (.region, true):
            hint.setContent(title: "截屏翻译", items: ["框选文字或单击窗口", "\(key) 切换全屏", "Esc 取消"])
        case (.fullscreen, true):
            hint.setContent(title: "全屏翻译", items: ["Enter 识别整屏", "\(key) 切换区域", "Esc 取消"])
        }
        // 提示条避开选区、放大镜和鼠标
        let origin = frozen.screen.frame.origin
        var avoid: [CGRect] = []
        if mode == .region, let selection = selector.selection, selector.selectionDisplayID == activeDisplayID {
            avoid.append(selection.offsetBy(dx: -origin.x, dy: -origin.y))
        }
        if magnifier.superview === view {
            avoid.append(magnifier.frame)
        }
        if toolbar.superview === view {
            avoid.append(toolbar.frame)
        }
        avoid.append(CGRect(x: mousePoint.x - origin.x - 16, y: mousePoint.y - origin.y - 16, width: 32, height: 32))
        hint.place(in: view, screen: frozen.screen, avoiding: avoid)
    }

    /// 记录鼠标位置；换到另一块屏幕时更新全屏模式的目标和提示条位置
    private func track(_ point: NSPoint) {
        mousePoint = point
        if let id = NSScreen.screen(containing: point)?.displayID, displays[id] != nil {
            activeDisplayID = id
        }
    }

    // MARK: - OverlayEventHandler：键盘

    func overlayKeyDown(_ event: NSEvent) -> Bool {
        guard !isFinished else { return false }
        // 按住某个键不放产生的自动重复：切换模式、Enter、C 一律忽略（否则会疯狂来回切换）；
        // 只有方向键允许连续触发，按住不放可以持续移动选区
        let arrowKeys = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
        if event.isARepeat && !arrowKeys.contains(Int(event.keyCode)) { return true }

        if hotkey.matches(event) {
            toggleMode()
            return true
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape:
            // 调色盘开着时 Esc 先关调色盘；正在输入文字时只结束输入（保留文字）；选中了标注时先取消选中；再按一次才退出截图
            if toolbar.closeColorPicker() {
                refresh()
            } else if annotator?.isEditingText == true {
                annotator?.endTextEditing()
                refresh()
            } else if annotator?.deselect() == true {
                refresh()
            } else {
                cancel()
            }
        case kVK_Delete, kVK_ForwardDelete:
            // 删除选中的标注（⌘Z 可以恢复）
            guard annotator?.deleteSelection() == true else { return false }
            refresh()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            complete()
        case kVK_ANSI_S where modifiers == .command:
            // ⌘S：完成并保存到文件（同时按设置复制到剪贴板、显示缩略图）
            complete(save: true)
        case kVK_ANSI_Z where modifiers == .command:
            annotator?.undo()
            refresh()
        case kVK_ANSI_Z where modifiers == [.command, .shift]:
            annotator?.redo()
            refresh()
        case kVK_ANSI_C where modifiers.isEmpty:
            copyColor()
        case let key where arrowKeys.contains(key) && annotator?.hasSelection == true:
            // 选中了标注：方向键移动标注 1 点，Shift + 方向键 10 点
            guard modifiers.subtracting(.shift).isEmpty else { return false }
            let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
            let (dx, dy): (CGFloat, CGFloat) = switch key {
            case kVK_LeftArrow: (-step, 0)
            case kVK_RightArrow: (step, 0)
            case kVK_UpArrow: (0, step)
            default: (0, -step)
            }
            annotator?.moveSelection(dx: dx, dy: dy)
            refresh()
        case let key where arrowKeys.contains(key) && mode == .region:
            // 方向键微调 1 像素，Shift + 方向键 10 像素（只在截图界面内有效，不是全局快捷键）
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

    /// 输入文字时，⌥A 和 ⌘S 也要由截图界面处理（否则 ⌥A 会在输入框里打出 å）
    func overlayShouldIntercept(_ event: NSEvent) -> Bool {
        guard annotator?.isEditingText == true else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return hotkey.matches(event) || (Int(event.keyCode) == kVK_ANSI_S && modifiers == .command)
    }

    /// 遮罩失去焦点、且焦点没有转到 Snap 的另一个遮罩上（例如系统弹窗抢走焦点）时取消截图，避免遮罩卡在屏幕上
    func overlayDidResignKey() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isFinished else { return }
            let anyKey = self.overlays.values.contains { $0.isKeyWindow }
            if !anyKey {
                Log.capture.notice("截图界面失去焦点，自动取消")
                self.cancel()
            }
        }
    }

    // MARK: - OverlayEventHandler：鼠标

    func overlayCursor(at point: NSPoint) -> NSCursor {
        // 工具栏上是箭头
        if let view = toolbar.superview, let window = view.window,
           toolbar.frame.contains(view.convert(window.convertPoint(fromScreen: point), from: nil)) {
            return .arrow
        }
        // 调色盘开着时是箭头（点调色盘外面只是关掉它）
        if toolbar.isShowingColorPicker { return .arrow }
        // 选中标注的控制点上（或正在拖控制点）：调整大小的箭头
        if let annotator, let p = canvasPoint(point), let cursor = annotator.resizeCursor(at: p) { return cursor }
        // 选着标注工具时，选区的 8 个控制点上（或正在拖它们）：调整选区大小的箭头
        if isAnnotating, mode == .region, selector.isSizing || selector.cornerHandle(at: point) != nil {
            return selector.cursor(at: point)
        }
        // 鼠标正好在已有的标注上（或正在拖动标注）：四向移动光标，表示可以选中、拖动
        if let annotator, let p = canvasPoint(point),
           annotator.isMovingAnnotation || annotator.grabbableAnnotation(at: p) != nil {
            return .snapMove
        }
        // 选了标注工具：可画的范围内是十字（文字工具是 I 形），范围外是箭头
        if let annotator, let tool = annotator.tool {
            guard let p = canvasPoint(point), annotator.canvasBounds.contains(p) else { return .arrow }
            return tool == .text ? .iBeam : .crosshair
        }
        return mode == .region ? selector.cursor(at: point) : .arrow
    }

    /// 选了标注工具时，鼠标用来画标注；没选工具时用来选取 / 调整选区
    private var isAnnotating: Bool { annotator?.tool != nil }

    func overlayMouseMoved(to point: NSPoint) {
        track(point)
        if mode == .region && !isAnnotating { selector.mouseMoved(to: point) }
        refresh()
    }

    func overlayMouseDown(at point: NSPoint) {
        track(point)
        mouseOwner = .none
        // 选着标注工具时按在选区的控制点上：调整选区大小（选中标注自己的控制点优先）
        if isAnnotating, mode == .region, selector.cornerHandle(at: point) != nil,
           canvasPoint(point).flatMap({ annotator?.resizeHandle(at: $0) }) == nil {
            annotator?.endTextEditing()
            selector.mouseDown(at: point)
            mouseOwner = .selector
            refresh()
            return
        }
        // 点中已有的标注（任何时候都可以选中、拖动），或选着工具在画新的标注
        if let annotator, let p = canvasPoint(point),
           annotator.mouseDown(at: p, shift: NSEvent.modifierFlags.contains(.shift)) {
            mouseOwner = .annotator
            refresh()
            return
        }
        // 标注模式下点在可画范围外不做任何事（不会误触重新框选）
        if isAnnotating {
            refresh()
            return
        }
        guard mode == .region else { return }
        selector.mouseDown(at: point)
        mouseOwner = .selector
        refresh()
    }

    func overlayMouseDragged(to point: NSPoint) {
        track(point)
        switch mouseOwner {
        case .annotator:
            if let p = canvasPoint(point) {
                annotator?.mouseDragged(to: p, shift: NSEvent.modifierFlags.contains(.shift))
            }
        case .selector:
            selector.mouseDragged(to: point)
            refresh()
        case .none:
            break
        }
    }

    func overlayMouseUp(at point: NSPoint) {
        track(point)
        switch mouseOwner {
        case .annotator:
            if let p = canvasPoint(point) {
                annotator?.mouseUp(at: p, shift: NSEvent.modifierFlags.contains(.shift))
            }
        case .selector:
            selector.mouseUp(at: point)
            // 截屏翻译：松开鼠标立即识别（拖出的选区，或单击选中的窗口）
            if isTranslating, selector.target != nil {
                mouseOwner = .none
                complete()
                return
            }
        case .none:
            break
        }
        mouseOwner = .none
        refresh()
    }

    /// 右键：选了标注工具时取消工具；有选区时清除选区；都没有时退出（与微信、Snipaste 的习惯一致）
    func overlayRightMouseDown(at point: NSPoint) {
        track(point)
        if isAnnotating {
            annotator?.tool = nil
            refresh()
        } else if mode == .region, selector.selection != nil {
            selector.clearSelection(at: point)
            refresh()
        } else {
            cancel()
        }
    }

    // MARK: - 调试

    #if DEBUG
    var debugSelector: RegionSelector { selector }
    var debugMagnifierVisible: Bool { magnifier.superview != nil }
    var debugActiveOverlay: NSView? { overlays[activeDisplayID]?.contentView }
    var debugScale: CGFloat { displays[activeDisplayID]?.scale ?? 1 }
    /// 顶部提示条在屏幕上的位置
    var debugHintFrame: CGRect? {
        guard let host = hint.view.superview, let window = host.window else { return nil }
        return window.convertToScreen(host.convert(hint.view.frame, to: nil))
    }
    var debugMagnifierFrame: CGRect? {
        guard magnifier.superview != nil, let origin = displays[activeDisplayID]?.screen.frame.origin else { return nil }
        return magnifier.frame.offsetBy(dx: origin.x, dy: origin.y)
    }
    /// 遮罩视图图层里各子图层的先后顺序（越靠后越在上层）
    var debugLayerOrder: String {
        guard let view = overlays[activeDisplayID]?.contentView, let sublayers = view.layer?.sublayers else { return "无" }
        return sublayers.enumerated().map { index, layer in
            let owner = (layer.delegate as? NSView).map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
            return "\(index):\(owner)\(layer.isHidden ? "(隐藏)" : "")"
        }.joined(separator: " ")
    }
    func debugComplete() { complete() }
    var debugAnnotator: AnnotationController? { annotator }
    var debugOverlayLevel: Int { overlays[activeDisplayID]?.level.rawValue ?? -1 }
    var debugToolbar: AnnotationToolbar { toolbar }
    func debugToolbarRefresh() { updateToolbar() }
    func debugSelectTool(_ tool: AnnotationTool?) { selectTool(tool) }
    func debugPerform(_ action: AnnotationToolbar.Action) { perform(action) }
    /// 自测用：所有工具都设成这个样式
    /// 所有工具设成同一个颜色 / 不透明度，大小用各自的第 level 档（0 小、1 中、2 大）
    func debugSetStyle(_ style: AnnotationStyle, level: Int = 1) {
        ToolStyleMemory.debugSetAll(style, level: level)
        var current = style
        current.size = (annotator?.tool ?? .rectangle).presetSizes[level]
        updateStyle { $0 = current }
    }
    #endif
}

extension FrozenDisplay {
    /// 截图结果：原生像素图像 + 缩放倍数 + 截取的位置（全局坐标）
    struct Crop {
        let image: CGImage
        let scale: CGFloat
        let sourceRect: CGRect
    }
}
