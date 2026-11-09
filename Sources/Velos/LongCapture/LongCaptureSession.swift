import AppKit
import Carbon.HIToolbox

/// 长截图：在截图界面框选区域、点工具栏的「长截图」后开始。
///
/// - 截图界面关闭，焦点还给原来的 App；选区外变暗、选区加边框（都不拦截鼠标），你在选区里滚动页面，Velos 边滚边拼接
/// - 控制条：竖向 / 横向、自动滚动、取消、保存、完成；旁边有拼接结果的实时预览
/// - 自动滚动：替你发送滚动事件，需要「辅助功能」权限（第一次点时请求；不给的话手动滚动照常可用），滚到底自动停
/// - 完成后和普通截图一样：复制到剪贴板、显示缩略图（可以继续标注、保存、钉图）
@MainActor
final class LongCaptureSession {
    var onFinish: (() -> Void)?

    private let region: CGRect
    private let screen: NSScreen
    private let scale: CGFloat
    private var axis: ScrollAxis = .vertical
    private var engine: LongCaptureEngine
    private let overlay: LongCaptureOverlay
    private let bar = LongCaptureBar()
    private let preview = LongCapturePreview()
    private var isFinished = false
    /// 拼好的长度（像素）
    private var length = 0
    private var hasScrolled = false
    /// 换过几次方向（和采集那边的 generation 对应，旧一轮的结果不要）
    private var generation = 0

    /// 有「辅助功能」权限时：把猛甩拆成小段滚动，滚多快都接得上
    private var scrollTap: LongCaptureScrollTap?
    /// 看滚轮滚了多少（只看不改，不需要权限），告诉拼接大概滚了多少
    private var scrollMonitor: Any?
    /// 还没有权限时：每秒看一次，一给权限就装上限速
    private var permissionTimer: Timer?
    /// 长截图期间的 Esc（焦点在被截的 App 里，只能注册成全局快捷键）
    private var escapeKey: UInt32?

    // 自动滚动
    private var autoTimer: Timer?
    private var autoStarted = ContinuousClock.now
    private var lastProgress = ContinuousClock.now
    private var autoAppended = false
    /// 滚动方向的正负：合成的滚轮事件里负数是往下 / 往右；万一系统反过来，开始一秒没有进展就换一次方向
    private var autoSign: Int32 = -1
    private var flippedOnce = false
    /// 自动滚动的这次手势（开始 → 进行中… → 结束）
    private var autoGesture: ScrollGesture?
    /// 鼠标移出了选区，自动滚动暂停中
    private var autoPaused = false
    /// 自动滚动「滚一步、等画面稳定、再滚下一步」：上一步是什么时候发的（nil = 还没发）
    private var autoStepAt: ContinuousClock.Instant?
    /// 最近一次画面有变化（接上新内容 / 位置变了）的时间
    private var lastFrameChange = ContinuousClock.now
    /// 这一步之后接上了新内容
    private var stepAppended = false
    /// 最近一帧没对上（滚动中截到页面还没画完的一帧时常有，画面稳定后通常就能接上）
    private var lastFrameLost = false
    /// 连续几步都没接上新内容
    private var idleSteps = 0
    /// 判断一步结束前，等拼接把已截到的帧处理完
    private enum FlushState { case idle, waiting, done }
    private var flushState = FlushState.idle
    /// 等拼接处理完时读到的长度
    private var flushedLength = 0
    /// 这一步之后接上了多少像素
    private var stepAppendedPixels = 0
    /// 这一步开始时拼好的长度（像素）
    private var lengthAtStepStart = 0
    /// 每一步想让页面移动多少点、实际发出的滚动量（点）、实际移动 ÷ 发出（按测到的校准）
    private var autoStepTarget: CGFloat = 0
    private var autoStepRequested: CGFloat = 0
    private var autoStepRatio: CGFloat = 1
    /// 自动滚动为什么停下（自测用）
    enum AutoStopReason { case end, lost }
    private(set) var autoStopReason: AutoStopReason?

    init(region: CGRect, screen: NSScreen) {
        // 对齐到整点：Retina 屏上选区常落在半点上（例如 y = 353.5），ScreenCaptureKit 会把它扩成整点再缩放，
        // 截到的画面被重新采样，滚动前后的像素对不齐，拼接就会接不上
        self.region = CGRect(x: region.minX.rounded(), y: region.minY.rounded(),
                             width: region.width.rounded(), height: region.height.rounded())
        self.screen = screen
        scale = screen.backingScaleFactor
        engine = LongCaptureEngine(axis: .vertical)
        overlay = LongCaptureOverlay(screen: screen, region: region)
    }

    func start() {
        bar.onAxis = { [weak self] axis in self?.setAxis(axis) }
        bar.onAutoScroll = { [weak self] in self?.toggleAutoScroll() }
        bar.onCancel = { [weak self] in self?.cancel() }
        bar.onSave = { [weak self] in self?.complete(.save) }
        bar.onDone = { [weak self] in self?.complete(.done) }
        bar.onEdit = { [weak self] in self?.complete(.edit) }
        bar.onPin = { [weak self] in self?.complete(.pin) }
        installScrollWatchers()
        escapeKey = HotkeyManager.shared.addTemporary(keyCode: kVK_Escape) { [weak self] in self?.cancel() }
        overlay.message = hint
        overlay.orderFrontRegardless()
        placeChrome()
        bar.orderFrontRegardless()
        connect(engine)
        Task {
            do {
                try await engine.start(region: region, screen: screen)
                Log.capture.notice("长截图：开始，选区 \(Int(self.region.width))×\(Int(self.region.height)) 点")
            } catch {
                Log.capture.error("长截图：无法开始 \(error.localizedDescription, privacy: .public)")
                overlay.message = "无法开始长截图：\(error.localizedDescription)"
            }
        }
    }

    private func connect(_ engine: LongCaptureEngine) {
        engine.onUpdate = { [weak self] update in self?.handle(update) }
        engine.onError = { [weak self] message in
            self?.stopAutoScroll()
            self?.overlay.message = "截取中断：\(message)"
        }
    }

    /// 开始时唯一的一条提示（之后滚动、自动滚动的过程中都不再出提示，界面保持干净）
    private var hint: String {
        "请缓慢\(axis == .vertical ? "向下" : "向右")滚动页面，或点「自动滚动」开始截长图"
    }

    /// 监听滚轮（给拼接提示滚动量），有权限时再装上限速
    private func installScrollWatchers() {
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.region.contains(NSEvent.mouseLocation) else { return }
                let delta = self.axis == .vertical ? event.scrollingDeltaY : event.scrollingDeltaX
                self.engine.addScrollHint(delta, precise: event.hasPreciseScrollingDeltas)
            }
        }
        // 限速要「辅助功能」权限：没有时请求一次（系统只在第一次弹出提示），之后一给权限就装上
        if Preferences.shared.longCaptureThrottle, !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, CGPreflightPostEventAccess() else { return }
                    timer.invalidate()
                    self.permissionTimer = nil
                    self.installThrottle()
                }
            }
        }
        installThrottle()
    }

    /// 限速：只有给了「辅助功能」权限才装得上
    private func installThrottle() {
        scrollTap?.stop()
        scrollTap = nil
        guard Preferences.shared.longCaptureThrottle, CGPreflightPostEventAccess() else { return }
        let extent = axis == .vertical ? region.height : region.width
        scrollTap = LongCaptureScrollTap(region: cgRegion, axis: axis, extent: extent,
                                         framesPerSecond: screen.maximumFramesPerSecond,
                                         speed: Preferences.shared.longCaptureThrottleSpeed.factor)
        Log.capture.notice("长截图：滚动限速\(self.scrollTap == nil ? "不可用" : "已开启", privacy: .public)")
    }

    private func removeScrollWatchers() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        scrollTap?.stop()
        scrollTap = nil
    }

    /// 选区（Quartz 全局坐标：原点在主屏左上角）
    private var cgRegion: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGRect(x: region.minX, y: primaryHeight - region.maxY, width: region.width, height: region.height)
    }

    // MARK: - 拼接进度

    private func handle(_ update: LongCaptureEngine.Update) {
        guard !isFinished, update.generation == generation else { return }
        length = update.length
        if let parts = update.preview { preview.show(parts, axis: axis) }
        bar.setLength(update.length, axis: axis, scale: scale)
        if update.event != .lost { lastFrameLost = false }
        switch update.event {
        case .appended(let pixels):
            stepAppendedPixels += pixels
            lastProgress = .now
            lastFrameChange = .now
            autoAppended = true
            stepAppended = true
            if !hasScrolled { hasScrolled = true }
            overlay.message = nil
        case .moved:
            lastProgress = .now
            lastFrameChange = .now
        case .lost:
            // 自动滚动时一帧没对上不算失败：等这一步滚完、画面稳定后再判断（见 autoTick）
            if autoTimer != nil {
                lastFrameLost = true
                lastFrameChange = .now
                return
            }
            break   // 过程中不出提示：往回滚一点就能接上
        case .limitReached:
            stopAutoScroll()
        case .started, .unchanged:
            break
        }
    }

    // MARK: - 方向

    private func setAxis(_ newAxis: ScrollAxis) {
        guard newAxis != axis else { return }
        stopAutoScroll()
        axis = newAxis
        engine.reset(axis: newAxis)
        generation += 1
        hasScrolled = false
        length = 0
        bar.setLength(0, axis: newAxis, scale: scale)
        preview.show([], axis: newAxis)
        if scrollTap != nil { installThrottle() }   // 限速按新方向重新装
        overlay.message = nil
        placeChrome()
    }

    // MARK: - 自动滚动

    private func toggleAutoScroll() {
        if autoTimer != nil {
            stopAutoScroll()
            return
        }
        // 替别的 App 滚动页面需要「辅助功能」权限：没有时请求一次（系统会提示去设置里打开），手动滚动照常可用
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            overlay.message = "自动滚动需要权限：请在 系统设置 › 隐私与安全性 › 辅助功能 里打开 Velos，再点一次「自动滚动」。也可以直接手动滚动"
            Log.capture.notice("长截图：自动滚动缺少辅助功能权限，已请求")
            return
        }
        // 刚给了权限：顺便装上限速
        if scrollTap == nil { installThrottle() }
        // 不移动用户的鼠标：macOS 只把滚动事件交给指针下面的窗口（实测过：能让页面滚动的发法都会把指针拉过去，
        // 不拉指针的发法页面都不动），所以指针在选区里时才滚，移出去就暂停，移回来接着滚
        Log.capture.notice("长截图：开始自动滚动")
        autoStarted = .now
        lastProgress = .now
        autoAppended = false
        autoPaused = false
        autoStepAt = nil
        idleSteps = 0
        autoStepRatio = 1
        autoStopReason = nil
        lastFrameLost = false
        bar.isAutoScrolling = true
        overlay.message = nil
        autoTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoTick() }
        }
    }


    private func autoTick() {
        let now = ContinuousClock.now
        // 鼠标不在选区里：暂停（结束这次手势），计时也不算，等鼠标回来
        // 选区很大时控制条会摆在选区里面：指针停在控制条上也要暂停，不然滚动事件会发给控制条自己
        let onBar = bar.isVisible && bar.frame.contains(NSEvent.mouseLocation)
        guard let location = currentMouseLocation, cgRegion.contains(location), !onBar else {
            // 和 QQ 一样：鼠标在页面上才滚，移开就停，不出提示
            if !autoPaused {
                autoPaused = true
                autoGesture?.end(at: currentMouseLocation ?? .zero)
                autoGesture = nil
            }
            autoStarted = now
            lastProgress = now
            autoStepAt = nil
            return
        }
        autoPaused = false
        // 滚一步、等画面稳定、再滚下一步（和 BetterShot 等工具一样）：
        // 滚动途中截到的帧可能是页面还没画完的样子，对不上；等画面停下来再拼，就稳稳接得上
        if let stepAt = autoStepAt {
            let elapsed = now - stepAt
            let settled = elapsed >= .milliseconds(90) && now - lastFrameChange >= .milliseconds(90) && !lastFrameLost
            if lastFrameLost, elapsed > .milliseconds(1200) {
                // 画面停下来了还是对不上：页面变化太大（例如内容在动、或一下跳得太远）
                autoStopReason = .lost
                stopAutoScroll()
                return
            }
            guard settled || (!lastFrameLost && elapsed >= .milliseconds(700)) else { return }
            // 画面看起来停了：先等已经截到的帧全部拼完（拼接慢时结果会晚到），确认这期间没有新变化再算这一步结束
            if flushState == .idle {
                flushState = .waiting
                let requested = now
                Task { [weak self] in
                    guard let flushed = await self?.engine.flush(), let self else { return }
                    self.flushedLength = flushed
                    // 刷完时这期间没有新变化：这一步确实结束了
                    self.flushState = self.lastFrameChange <= requested ? .done : .idle
                }
                return
            }
            guard flushState == .done else { return }
            flushState = .idle
            // 这一步真正往前接上了多少（点）：只接上几个像素是页面到底后回弹，不算前进
            // 用画面稳定后的长度算（滚过头拉出的空白在弹回后不算长度）
            let movedPoints = CGFloat(flushedLength - lengthAtStepStart) / scale
            let progressed = movedPoints >= max(4, autoStepTarget * 0.25)
            // 按实际移动距离校准下一步（各 App 对同样的滚动量移动得不一样多）
            if progressed, autoStepRequested > 0, idleSteps == 0, movedPoints < autoStepTarget * 3 {
                let measured = min(max(movedPoints / autoStepRequested, 0.25), 4)
                autoStepRatio = autoStepRatio * 0.5 + measured * 0.5
            }
            idleSteps = progressed ? 0 : idleSteps + 1
            if !autoAppended {
                // 刚开始还没接上过新内容：先往下试两步（第一下偶尔会被系统吞掉），再反方向试两步，都不动才算到头
                if idleSteps == 2, !flippedOnce {
                    flippedOnce = true
                    autoSign = -autoSign
                    idleSteps = 0
                } else if idleSteps >= 2 {
                    autoStopReason = .end
                    stopAutoScroll()
                    return
                }
            } else if idleSteps >= 2 {
                // 连着两步都没有新内容：到底了
                autoStopReason = .end
                stopAutoScroll()
                return
            }
        }
        let extent = axis == .vertical ? region.height : region.width
        // 每步约选区的 30%（慢 18%、快 48%）：相邻两次稳定的画面重叠一大半，比对稳
        autoStepTarget = min(extent * 0.5, extent * 0.3 * Preferences.shared.longCaptureAutoSpeed.factor)
        autoStepRequested = max(12, (autoStepTarget / autoStepRatio).rounded())
        let amount = Int32(autoStepRequested) * autoSign
        // 每一步是一次完整的手势（开始 → 结束）：到底时的回弹马上弹回去，下一步从稳定的画面开始
        let gesture = ScrollGesture(axis: axis)
        stepAppended = false
        stepAppendedPixels = 0
        flushState = .idle
        lengthAtStepStart = flushedLength > 0 ? flushedLength : length
        autoStepAt = now
        // 就发在指针现在的位置：指针不会被移动
        gesture.scroll(amount, at: location)
        gesture.end(at: location)
    }

    private func stopAutoScroll() {
        if autoTimer != nil { Log.capture.notice("长截图：停止自动滚动") }
        autoTimer?.invalidate()
        autoTimer = nil
        if let location = currentMouseLocation { autoGesture?.end(at: location) }
        autoGesture = nil
        autoPaused = false
        bar.isAutoScrolling = false
    }

    /// 鼠标指针现在的位置（Quartz 全局坐标：原点在主屏左上角）
    private var currentMouseLocation: CGPoint? { CGEvent(source: nil)?.location }

    // MARK: - 结束

    /// 结束方式：完成（复制、缩略图）、保存到文件、打开编辑窗口继续标注、钉在屏幕上
    enum Finish { case done, save, edit, pin }

    private func complete(_ finish: Finish) {
        guard !isFinished else { return }
        stopAutoScroll()
        isFinished = true
        bar.setBusy()
        Task {
            await engine.stop()
            let image = await engine.makeImage()
            close()
            guard let image else { return }
            Log.capture.notice("长截图完成：\(image.width)×\(image.height) 像素")
            let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            // 位置用截取时选区在屏幕上的位置（只取开头那一屏的高度）：
            // 缩略图、编辑窗口、钉图按它找所在的屏幕。按整张长图算的话中心点会落到屏幕下面很远，
            // 多屏时可能落进另一块屏幕，缩略图就跑到别的屏幕上去了
            let shownHeight = min(size.height, region.height), shownWidth = min(size.width, region.width)
            let sourceRect = CGRect(x: region.minX, y: region.maxY - shownHeight, width: shownWidth, height: shownHeight)
            switch finish {
            case .edit:
                // 直接打开编辑窗口（按原像素宽度显示、可滚动、可标注），完成后再复制 / 保存
                AnnotationEditorWindowController.open(CapturedImage(image: image, scale: scale, sourceRect: sourceRect))
            case .pin:
                // 钉在屏幕上：长图在钉图窗口里滚动查看，⌥ + 滚轮缩放
                _ = PinManager.shared.pin(CapturedImage(image: image, scale: scale, sourceRect: sourceRect))
            case .done, .save:
                ScreenshotOutput.deliver(image, scale: scale, sourceRect: sourceRect, forceSave: finish == .save)
            }
        }
    }

    private func cancel() {
        guard !isFinished else { return }
        stopAutoScroll()
        isFinished = true
        Log.capture.notice("长截图已取消")
        Task {
            await engine.stop()
            close()
        }
    }

    private func close() {
        removeScrollWatchers()
        if let escapeKey { HotkeyManager.shared.removeTemporary(escapeKey) }
        escapeKey = nil
        engine.onUpdate = nil
        engine.onError = nil
        overlay.orderOut(nil)
        overlay.close()
        bar.orderOut(nil)
        bar.close()
        preview.orderOut(nil)
        preview.close()
        onFinish?()
    }

    // MARK: - 布局

    /// 控制条：选区下方右对齐，放不下放上方，再不行放选区里面底部。
    /// 预览：竖向放选区右边（放不下放左边），横向放选区上方（放不下放下方），都放不下就不显示
    private func placeChrome() {
        let visible = screen.visibleFrame
        let size = bar.barFrame.size
        var origin = CGPoint(x: region.maxX - size.width, y: region.minY - 8 - size.height)
        if origin.y < visible.minY + 4 {
            origin.y = region.maxY + 8
            if origin.y + size.height > visible.maxY - 4 { origin.y = region.minY + 8 }
        }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        bar.place(at: origin)

        let gap: CGFloat = 12
        var frame: CGRect?
        switch axis {
        case .vertical:
            let previewSize = CGSize(width: 150, height: min(max(region.height, 160), 420))
            let right = CGRect(x: region.maxX + gap, y: region.maxY - previewSize.height, width: previewSize.width, height: previewSize.height)
            let left = CGRect(x: region.minX - gap - previewSize.width, y: right.minY, width: previewSize.width, height: previewSize.height)
            frame = [right, left].first { visible.contains($0) }
        case .horizontal:
            let previewSize = CGSize(width: min(max(region.width, 200), 420), height: 110)
            let above = CGRect(x: region.minX, y: region.maxY + gap, width: previewSize.width, height: previewSize.height)
            let below = CGRect(x: region.minX, y: min(region.minY, bar.barFrame.minY) - gap - previewSize.height,
                               width: previewSize.width, height: previewSize.height)
            frame = [above, below].first { visible.contains($0) && !$0.intersects(bar.barFrame) }
        }
        if let frame {
            preview.setFrame(frame, display: true)
            preview.orderFrontRegardless()
        } else {
            preview.orderOut(nil)
        }
    }

    #if DEBUG
    /// 自测：显示界面但不开始截屏，画面由 debugFeed 提供
    func debugStartWithoutCapture() {
        bar.onAxis = { [weak self] axis in self?.setAxis(axis) }
        bar.onCancel = { [weak self] in self?.cancel() }
        bar.onEdit = { [weak self] in self?.complete(.edit) }
        bar.onPin = { [weak self] in self?.complete(.pin) }
        overlay.message = hint
        overlay.orderFrontRegardless()
        placeChrome()
        bar.orderFrontRegardless()
        connect(engine)
    }
    func debugFeed(_ frame: PixelFrame) { engine.debugFeed(frame) }
    func debugImage() async -> CGImage? { await engine.makeImage() }
    func debugSetAxis(_ axis: ScrollAxis) { setAxis(axis) }
    func debugCancel() { cancel() }
    /// 自测：注册 Esc，并返回编号（可以模拟按下）
    func debugInstallEscape() -> UInt32? {
        escapeKey = HotkeyManager.shared.addTemporary(keyCode: kVK_Escape) { [weak self] in self?.cancel() }
        return escapeKey
    }
    var debugBar: LongCaptureBar { bar }
    var debugOverlay: LongCaptureOverlay { overlay }
    var debugPreview: LongCapturePreview { preview }
    var debugLength: Int { length }
    var debugIsAutoScrolling: Bool { autoTimer != nil }
    func debugToggleAutoScroll() { toggleAutoScroll() }
    #endif
}

// MARK: - 选区外变暗 + 边框 + 提示（不拦截鼠标）

@MainActor
final class LongCaptureOverlay: NSPanel {
    var message: String? { didSet { (contentView as? OverlayContent)?.message = message } }

    init(screen: NSScreen, region: CGRect) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true   // 鼠标、滚轮都穿过去，交给下面的 App
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        let local = region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        contentView = OverlayContent(frame: CGRect(origin: .zero, size: screen.frame.size), region: local)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class OverlayContent: NSView {
        let region: CGRect
        var message: String? { didSet { needsDisplay = true } }

        init(frame: CGRect, region: CGRect) {
            self.region = region
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func draw(_ dirtyRect: NSRect) {
            // 选区外变暗
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: region))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.32).setFill()
            dim.fill()
            // 选区边框画在外侧，不挡住内容
            OverlayAccent.screenshot.setStroke()
            let border = NSBezierPath(rect: region.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.stroke()
            guard let message else { return }
            // 提示：选区中间偏上的深色胶囊
            let text = NSAttributedString(string: message, attributes: [
                .font: roundedFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
            let maxWidth = max(160, min(region.width - 24, 520))
            let textSize = text.boundingRect(with: CGSize(width: maxWidth, height: 200), options: [.usesLineFragmentOrigin]).size
            let pill = CGRect(x: region.midX - textSize.width / 2 - 18, y: region.midY - textSize.height / 2 - 11,
                              width: ceil(textSize.width) + 36, height: ceil(textSize.height) + 22)
            NSColor(srgbRed: 0.18, green: 0.13, blue: 0.10, alpha: 0.82).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
            text.draw(with: CGRect(x: pill.minX + 18, y: pill.minY + 11, width: maxWidth, height: textSize.height),
                      options: [.usesLineFragmentOrigin])
        }
    }
}

// MARK: - 控制条

/// [竖向 | 横向] [自动滚动] | 长度 | [取消] [保存] [完成]
@MainActor
final class LongCaptureBar: NSPanel {
    var onAxis: ((ScrollAxis) -> Void)?
    var onAutoScroll: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSave: (() -> Void)?
    var onDone: (() -> Void)?
    var onEdit: (() -> Void)?
    var onPin: (() -> Void)?

    var isAutoScrolling = false {
        didSet {
            autoButton.title = isAutoScrolling ? "停止滚动" : "自动滚动"
            autoButton.symbol = isAutoScrolling ? "stop.fill" : "arrow.down.to.line"
        }
    }

    private let bar = FrostedPanel(blending: .behindWindow)
    private let direction = SegmentedPill(titles: ["竖向", "横向"], help: "滚动方向")
    private let autoButton = PillButton(title: "自动滚动", symbol: "arrow.down.to.line",
                                        color: NSColor(srgbRed: 0.62, green: 0.45, blue: 0.34, alpha: 1),   // 可可棕，和杏色的「完成」区分开
                                        help: "自动滚动页面（需要「辅助功能」权限）")
    private let lengthLabel = NSTextField(labelWithString: "")
    private let cancelButton = ToolbarButton(symbol: "xmark", help: "取消长截图（Esc）")
    private let editButton = ToolbarButton(symbol: "square.and.pencil", help: "编辑：结束长截图，打开编辑窗口继续标注")
    private let pinButton = ToolbarButton(symbol: "pin", help: "钉在屏幕上：结束长截图，把整张长图钉在屏幕上")
    private let saveButton = ToolbarButton(symbol: "square.and.arrow.down", help: "完成并保存到文件")
    private let doneButton = PillButton(title: "完成", symbol: "checkmark", color: WarmPalette.apricot,
                                        help: "完成：复制到剪贴板、显示缩略图")
    private static let height: CGFloat = 42
    private static let inset: CGFloat = 40   // 给投影留出空间

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let root = NSView()
        contentView = root
        root.addSubview(bar)
        lengthLabel.font = roundedFont(ofSize: 12, weight: .medium, monospacedDigits: true)
        lengthLabel.textColor = WarmPalette(for: bar).ink
        direction.onSelect = { [weak self] index in self?.onAxis?(index == 0 ? .vertical : .horizontal) }
        autoButton.action = { [weak self] in self?.onAutoScroll?() }
        cancelButton.action = { [weak self] in self?.onCancel?() }
        editButton.action = { [weak self] in self?.onEdit?() }
        pinButton.action = { [weak self] in self?.onPin?() }
        saveButton.action = { [weak self] in self?.onSave?() }
        doneButton.action = { [weak self] in self?.onDone?() }
        for view in [direction, autoButton, lengthLabel, cancelButton, editButton, pinButton, saveButton, doneButton] as [NSView] { bar.addSubview(view) }
        setLength(0, axis: .vertical, scale: 1)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 显示拼好的长度：「已拼接 2400 像素」
    func setLength(_ pixels: Int, axis: ScrollAxis, scale: CGFloat) {
        lengthLabel.stringValue = pixels == 0 ? "等待滚动…" : "已拼接 \(pixels) 像素"
        direction.selectedIndex = axis == .vertical ? 0 : 1
        relayout()
    }

    /// 正在生成结果：按钮不能再点
    func setBusy() {
        for control in [direction, autoButton, cancelButton, editButton, pinButton, saveButton, doneButton] as [WarmControl] { control.isEnabled = false }
        lengthLabel.stringValue = "正在生成…"
        relayout()
    }

    private func relayout() {
        let h = Self.height, button: CGFloat = 32, y = (h - button) / 2
        var x: CGFloat = 6
        func place(_ view: NSView, _ width: CGFloat) {
            view.frame = CGRect(x: x, y: y, width: width, height: button)
            x += width + 4
        }
        place(direction, 92)
        place(autoButton, max(autoButton.fittingWidth, 108))
        x += 6
        let labelSize = lengthLabel.fittingSize
        lengthLabel.frame = CGRect(x: x, y: ((h - labelSize.height) / 2).rounded(), width: max(ceil(labelSize.width), 118),
                                   height: labelSize.height)
        x += max(ceil(labelSize.width), 118) + 8
        place(cancelButton, button)
        place(editButton, button)
        place(pinButton, button)
        place(saveButton, button)
        place(doneButton, doneButton.fittingWidth)
        let width = x + 2
        let inset = Self.inset
        bar.frame = CGRect(x: inset, y: inset, width: width, height: h)
        let origin = frame.origin
        setFrame(CGRect(x: origin.x, y: origin.y, width: width + inset * 2, height: h + inset * 2), display: true)
    }

    /// 控制条本身（不含给投影留的边距）在屏幕上的位置和大小
    var barFrame: CGRect { frame.insetBy(dx: Self.inset, dy: Self.inset) }

    /// 把控制条本身的左下角放到 origin
    func place(at origin: CGPoint) {
        setFrameOrigin(CGPoint(x: origin.x - Self.inset, y: origin.y - Self.inset))
    }

    #if DEBUG
    func debugTapAutoScroll() { onAutoScroll?() }
    var debugAutoTitle: String { autoButton.title }
    func debugTapEdit() { onEdit?() }
    func debugTapPin() { onPin?() }
    var debugLengthText: String { lengthLabel.stringValue }
    #endif
}

// MARK: - 预览

/// 拼接结果的实时预览：竖向时按宽度缩放、显示最新的一段；横向时按高度缩放、显示最右边的一段
@MainActor
final class LongCapturePreview: NSPanel {
    private let panel = FrostedPanel(cornerRadius: 12, blending: .behindWindow, shadowRadius: 8)
    private let canvas = PreviewCanvas()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        let root = NSView()
        contentView = root
        root.addSubview(panel)
        panel.addSubview(canvas)
    }

    override var canBecomeKey: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        panel.frame = CGRect(origin: .zero, size: frameRect.size)
        canvas.frame = panel.bounds.insetBy(dx: 6, dy: 6)
    }

    func show(_ parts: [CGImage], axis: ScrollAxis) {
        canvas.parts = parts
        canvas.axis = axis
    }

    #if DEBUG
    var debugPartCount: Int { canvas.parts.count }
    #endif

    private final class PreviewCanvas: NSView {
        var parts: [CGImage] = [] { didSet { needsDisplay = true } }
        var axis: ScrollAxis = .vertical { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext, let first = parts.first else { return }
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.clip()
            ctx.interpolationQuality = .medium
            switch axis {
            case .vertical:
                // 宽度撑满，从上往下排；超出高度时只显示最下面（最新）的部分
                let k = bounds.width / CGFloat(first.width)
                let total = parts.reduce(0) { $0 + CGFloat($1.height) * k }
                var top = bounds.maxY + max(0, total - bounds.height)
                for part in parts {
                    let h = CGFloat(part.height) * k
                    let rect = CGRect(x: bounds.minX, y: top - h, width: bounds.width, height: h)
                    if rect.maxY >= bounds.minY - 1, rect.minY <= bounds.maxY + 1 { ctx.draw(part, in: rect) }
                    top -= h
                }
            case .horizontal:
                // 高度撑满，从左往右排；超出宽度时只显示最右边（最新）的部分
                let k = bounds.height / CGFloat(first.height)
                let total = parts.reduce(0) { $0 + CGFloat($1.width) * k }
                var left = bounds.minX - max(0, total - bounds.width)
                for part in parts {
                    let w = CGFloat(part.width) * k
                    let rect = CGRect(x: left, y: bounds.minY, width: w, height: bounds.height)
                    if rect.maxX >= bounds.minX - 1, rect.minX <= bounds.maxX + 1 { ctx.draw(part, in: rect) }
                    left += w
                }
            }
            ctx.restoreGState()
        }
    }
}
