import AppKit
import Carbon.HIToolbox

/// 长截图：在截图界面框选区域、点工具栏的「长截图」后开始。
///
/// - 截图界面关闭，焦点还给原来的 App；选区外变暗、选区加边框（都不拦截鼠标），你在选区里滚动页面，Velos 边滚边拼接
/// - 控制条：自动滚动、取消、编辑、钉图、保存、完成；旁边有拼接结果的实时预览（跟着滚动的位置走）
/// - 不碰滚动：不拦截、不限速、不读取滚轮事件，鼠标、触控板和装的任何滚动工具都照常工作；
///   拼接只看截到的画面（每秒最多 60 帧），滚得太快跟丢时自动从当前画面接回
/// - 自动滚动（可选）：点控制条上的按钮，Velos 替你匀速、慢慢地往下滚；要「辅助功能」权限，只在用它时请求
/// - 完成后和普通截图一样：复制到剪贴板、显示缩略图（可以继续标注、保存、钉图）
@MainActor
final class LongCaptureSession {
    var onFinish: (() -> Void)?

    private let region: CGRect
    private let screen: NSScreen
    private let scale: CGFloat
    private var engine: LongCaptureEngine
    private let overlay: LongCaptureOverlay
    private let bar = LongCaptureBar()
    private let preview = LongCapturePreview()
    private var isFinished = false
    /// 拼好的长度（像素）
    private var length = 0
    private var hasScrolled = false
    private let autoScroll: LongCaptureAutoScroll

    /// 长截图期间的 Esc（焦点在被截的 App 里，只能注册成全局快捷键）
    private var escapeKey: UInt32?

    init(region: CGRect, screen: NSScreen) {
        // 对齐到整点：Retina 屏上选区常落在半点上（例如 y = 353.5），ScreenCaptureKit 会把它扩成整点再缩放，
        // 截到的画面被重新采样，滚动前后的像素对不齐，拼接就会接不上
        self.region = CGRect(x: region.minX.rounded(), y: region.minY.rounded(),
                             width: region.width.rounded(), height: region.height.rounded())
        self.screen = screen
        scale = screen.backingScaleFactor
        engine = LongCaptureEngine()
        overlay = LongCaptureOverlay(screen: screen, region: region)
        autoScroll = LongCaptureAutoScroll(region: self.region)
    }

    func start() {
        connectControls()
        bar.onCancel = { [weak self] in self?.cancel() }
        bar.onSave = { [weak self] in self?.complete(.save) }
        bar.onDone = { [weak self] in self?.complete(.done) }
        bar.onEdit = { [weak self] in self?.complete(.edit) }
        bar.onPin = { [weak self] in self?.complete(.pin) }
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

    /// 自动滚动按钮和它的状态变化
    private func connectControls() {
        bar.onAutoScroll = { [weak self] in self?.toggleAutoScroll() }
        autoScroll.onChange = { [weak self] state in self?.autoScrollChanged(state) }
    }

    private func connect(_ engine: LongCaptureEngine) {
        engine.onUpdate = { [weak self] update in self?.handle(update) }
        engine.onError = { [weak self] message in
            self?.overlay.message = "截取中断：\(message)"
        }
    }

    /// 开始时唯一的一条提示（之后滚动的过程中都不再出提示，界面保持干净）
    private var hint: String {
        "请缓慢向下滚动页面，或点「自动滚动」"
    }

    // MARK: - 拼接进度

    private func handle(_ update: LongCaptureEngine.Update) {
        guard !isFinished else { return }
        length = update.length
        if let image = update.preview { preview.show(image) }
        bar.setLength(update.length)
        if let motion = update.motion { autoScroll.noteMotion(motion) }
        switch update.event {
        case .appended:
            if !hasScrolled { hasScrolled = true }
            if !autoScroll.isActive { overlay.message = nil }
        case .moved:
            break
        case .limitReached:
            if autoScroll.isActive { autoScroll.stop(.limit) }
        case .lost, .started, .unchanged:
            break   // 过程中不出提示：往回滚一点就能接上
        }
    }

    // MARK: - 自动滚动

    private func toggleAutoScroll() {
        if autoScroll.isActive {
            autoScroll.stop()
        } else {
            autoScroll.start()
        }
    }

    private func autoScrollChanged(_ state: LongCaptureAutoScroll.State) {
        bar.setAutoScrolling(autoScroll.isActive)
        switch state {
        case .running:
            overlay.message = nil
        case .paused:
            overlay.message = "把鼠标移回选区里，自动滚动会接着滚"
        case .stopped(.noPermission):
            overlay.message = "自动滚动需要「辅助功能」权限：在 系统设置 › 隐私与安全性 › 辅助功能 里打开 Velos，再点一次「自动滚动」"
        case .stopped(.reachedEnd):
            overlay.message = "已经滚到底了"
        case .stopped(.limit):
            overlay.message = "长图已到长度上限"
        case .stopped(.user):
            overlay.message = nil
        }
    }

    // MARK: - 结束

    /// 结束方式：完成（复制、缩略图）、保存到文件、打开编辑窗口继续标注、钉在屏幕上
    enum Finish { case done, save, edit, pin }

    private func complete(_ finish: Finish) {
        guard !isFinished else { return }
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
        isFinished = true
        Log.capture.notice("长截图已取消")
        Task {
            await engine.stop()
            close()
        }
    }

    private func close() {
        autoScroll.stop()
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
    /// 预览：放选区右边，放不下放左边，都放不下就不显示
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
        let previewSize = CGSize(width: 150, height: min(max(region.height, 160), 420))
        let right = CGRect(x: region.maxX + gap, y: region.maxY - previewSize.height, width: previewSize.width, height: previewSize.height)
        let left = CGRect(x: region.minX - gap - previewSize.width, y: right.minY, width: previewSize.width, height: previewSize.height)
        if let frame = [right, left].first(where: { visible.contains($0) }) {
            preview.setFrame(frame, display: true)
            preview.orderFrontRegardless()
            let size = preview.imagePixelSize
            engine.setPreviewSize(width: size.width, height: size.height)
        } else {
            preview.orderOut(nil)
        }
    }

    #if DEBUG
    /// 自测：显示界面但不开始截屏，画面由 debugFeed 提供
    func debugStartWithoutCapture() {
        connectControls()
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
    var debugAutoScroll: LongCaptureAutoScroll { autoScroll }
    #endif
}
