import AppKit
import AVFoundation

/// 屏幕右下角的截图 / 录屏缩略图：从右侧滑入，几秒后自动淡出（鼠标停在上面时暂停计时），
/// 连续截图时向上堆叠。缩略图属于 Snap 的界面，再次截图 / 录屏时会被排除。
@MainActor
final class ThumbnailManager {
    static let shared = ThumbnailManager()

    /// 自动消失前停留的时间（录屏的缩略图停留久一点）
    private static let lifetime: TimeInterval = 6
    private static let recordingLifetime: TimeInterval = 10
    /// 缩略图的最大尺寸（点）
    private static let maxSize = CGSize(width: 240, height: 150)
    private static let margin: CGFloat = 16
    private static let spacing: CGFloat = 10

    @MainActor
    private final class Entry {
        let panel: NSPanel
        let view: ThumbnailView
        /// 截图缩略图对应的截图；录屏缩略图为 nil
        let capture: CapturedImage?
        /// 录屏缩略图对应的视频文件
        let videoURL: URL?
        let lifetime: TimeInterval
        var timer: Timer?
        /// 正在导出 GIF：不自动消失，关闭即取消
        var exportTask: Task<Void, Never>?
        init(panel: NSPanel, view: ThumbnailView, capture: CapturedImage?, videoURL: URL?, lifetime: TimeInterval) {
            self.panel = panel
            self.view = view
            self.capture = capture
            self.videoURL = videoURL
            self.lifetime = lifetime
        }
    }

    private var entries: [Entry] = []
    private var screen: NSScreen?
    /// 「拷贝文件」用的剪贴板（自测时换成私有剪贴板，不动用户的剪贴板）
    var pasteboard = NSPasteboard.general

    private init() {}

    var visibleCount: Int { entries.count }

    func show(_ capture: CapturedImage) {
        guard let image = capture.image else { return }
        let screen = NSScreen.screen(containing: CGPoint(x: capture.sourceRect.midX, y: capture.sourceRect.midY))
            ?? NSScreen.main ?? NSScreen.screens[0]
        self.screen = screen
        let scale = screen.backingScaleFactor

        // 按比例缩放到不超过最大尺寸；缩略图位图单独生成（高质量缩小），不把整张大图交给图层
        let size = Self.fittedSize(capture.pointSize)
        let pixelFactor = CGFloat(image.width) / (size.width * scale)
        let preview = ImageEncoder.downscaled(image, by: max(pixelFactor, 1)) ?? image

        let view = ThumbnailView(image: preview, size: size, scale: scale)
        let entry = Entry(panel: Self.makePanel(size: size, view: view), view: view, capture: capture,
                          videoURL: nil, lifetime: Self.lifetime)

        view.fileProvider = { [weak capture] in capture?.fileForSharing() }
        view.onOpen = { [weak self, weak entry] in
            // 单击缩略图：在 Snap 的编辑窗口里继续标注
            guard let entry, let capture = entry.capture else { return }
            AnnotationEditorWindowController.open(capture)
            self?.dismiss(entry)
        }
        view.onPin = { [weak self, weak entry] in
            guard let entry, let capture = entry.capture else { return }
            _ = PinManager.shared.pin(capture)
            self?.dismiss(entry)
        }
        view.onSave = { [weak entry] in
            // 保存到默认文件夹；保存完成后按钮变成「在访达中显示」，缩略图不收起
            guard let capture = entry?.capture else { return }
            ScreenshotOutput.save(capture)
        }
        view.onReveal = { [weak self, weak entry] in
            guard let entry, let url = entry.capture?.fileURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            self?.dismiss(entry)
        }
        view.isSaved = capture.fileURL != nil
        capture.onFileSaved = { [weak entry] in entry?.view.isSaved = true }
        present(entry)
    }

    /// 录屏完成后显示录屏缩略图（封面取视频第一帧）
    /// - Parameters:
    ///   - screen: 录制所在的屏幕
    ///   - exportGIF: 显示后立即开始导出 GIF（菜单「将录屏转为 GIF…」）
    func showRecording(_ url: URL, on screen: NSScreen?, exportGIF: Bool = false) async {
        let screen = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let scale = screen.backingScaleFactor
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let duration = try? await asset.load(.duration) else {
            Log.capture.error("录屏文件无法读取，不显示缩略图")
            return
        }
        // 视频按 1 像素 = 1/scale 点显示（1080p 录制的视频比例一样，只是更小）
        let videoSize = CGSize(width: naturalSize.width / scale, height: naturalSize.height / scale)
        let size = Self.fittedSize(videoSize)

        // 封面：只解码一帧，直接缩小到缩略图大小
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * scale, height: size.height * scale)
        let poster = (try? await generator.image(at: .zero).image) ?? Self.placeholderImage

        let seconds = CMTimeGetSeconds(duration)
        let view = ThumbnailView(image: poster, size: size, scale: scale, kind: .recording(duration: seconds))
        let entry = Entry(panel: Self.makePanel(size: size, view: view), view: view, capture: nil,
                          videoURL: url, lifetime: Self.recordingLifetime)
        self.screen = screen

        view.onOpen = { [weak self, weak entry] in
            // 单击：预览播放
            guard let entry else { return }
            VideoPreviewWindowController.show(url, videoSize: videoSize, on: screen)
            self?.dismiss(entry)
        }
        view.onGIF = { [weak self, weak entry] in
            guard let self, let entry else { return }
            startGIFExport(entry, video: url, duration: seconds)
        }
        configureFileActions(entry, url: url)
        present(entry)
        if exportGIF { startGIFExport(entry, video: url, duration: seconds) }
    }

    // MARK: - GIF

    /// 在缩略图上导出 GIF：中间显示进度，完成后换成 GIF 缩略图
    private func startGIFExport(_ entry: Entry, video: URL, duration: TimeInterval) {
        guard entry.exportTask == nil else { return }
        entry.timer?.invalidate()
        entry.view.isBusy = true
        entry.view.setStatus("正在生成 GIF…")
        let prefs = Preferences.shared
        let options = GIFExporter.Options(fps: prefs.gifFrameRate.rawValue, maxWidth: prefs.gifMaxWidth.rawValue)
        let view = entry.view
        entry.exportTask = Task { [weak self, weak entry] in
            do {
                let gif = try await GIFExporter.export(video: video, options: options) { fraction in
                    Task { @MainActor in
                        if view.isBusy { view.setStatus("正在生成 GIF \(Int(fraction * 100))%") }
                    }
                }
                guard let self, let entry, entries.contains(where: { $0 === entry }) else { return }
                entry.exportTask = nil
                // 换成 GIF 缩略图（沿用视频的封面）
                showGIF(gif, poster: entry.view.image, size: entry.panel.frame.size, duration: duration, replacing: entry)
            } catch is CancellationError {
                Log.capture.notice("GIF 导出已取消")
            } catch {
                Log.capture.error("GIF 导出失败：\(error.localizedDescription, privacy: .public)")
                guard let self, let entry else { return }
                entry.exportTask = nil
                entry.view.isBusy = false
                entry.view.setStatus("GIF 导出失败")
                scheduleDismiss(entry)
            }
        }
    }

    private func showGIF(_ url: URL, poster: CGImage, size: CGSize, duration: TimeInterval, replacing old: Entry) {
        let scale = screen?.backingScaleFactor ?? 2
        let view = ThumbnailView(image: poster, size: size, scale: scale, kind: .gif(duration: duration))
        let entry = Entry(panel: Self.makePanel(size: size, view: view), view: view, capture: nil,
                          videoURL: url, lifetime: Self.recordingLifetime)
        view.onOpen = { [weak self, weak entry] in
            // 单击：用默认的看图 App 打开
            guard let entry else { return }
            NSWorkspace.shared.open(url)
            self?.dismiss(entry)
        }
        configureFileActions(entry, url: url)
        // 新缩略图放在原来的位置，不做滑入动画
        if let index = entries.firstIndex(where: { $0 === old }) {
            entries[index] = entry
            old.timer?.invalidate()
            entry.panel.setFrame(old.panel.frame, display: false)
            entry.panel.orderFrontRegardless()
            old.panel.orderOut(nil)
            old.panel.close()
            configureCommon(entry)
            scheduleDismiss(entry)
        } else {
            present(entry)
        }
    }

    /// 录屏 / GIF 缩略图共用：拖出文件、在访达中显示、拷贝文件、移到废纸篓
    private func configureFileActions(_ entry: Entry, url: URL) {
        let view = entry.view
        view.fileProvider = { url }
        view.onReveal = { [weak self, weak entry] in
            guard let entry else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            self?.dismiss(entry)
        }
        view.onCopy = { [weak self, weak entry] in
            // 拷贝文件本身：可以直接粘贴到访达、聊天、邮件里
            guard let self, let entry else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
            entry.view.showCopied()
        }
        view.onDelete = { [weak self, weak entry] in
            // 移到废纸篓（不是永久删除，可以从废纸篓里放回）
            guard let entry else { return }
            VideoPreviewWindowController.close(for: url)
            NSWorkspace.shared.recycle([url]) { _, error in
                if let error { Log.capture.error("移到废纸篓失败：\(error.localizedDescription, privacy: .public)") }
            }
            self?.dismiss(entry)
        }
    }

    // MARK: - 创建

    /// 按比例缩放到不超过最大尺寸。
    /// 长截图按比例缩下来会细成一条（例如 15 × 150），放不下关闭、保存、钉图三个按钮：
    /// 窄的一边至少 150 × 100 点（原图本来就小时除外），图片按比例填满、只显示中间一段
    static func fittedSize(_ full: CGSize) -> CGSize {
        let factor = min(maxSize.width / max(full.width, 1), maxSize.height / max(full.height, 1), 1)
        let width = max((full.width * factor).rounded(), min(150, full.width), 60)
        let height = max((full.height * factor).rounded(), min(100, full.height), 40)
        return CGSize(width: min(width, maxSize.width), height: min(height, maxSize.height))
    }

    private static func makePanel(size: CGSize, view: ThumbnailView) -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = view
        return panel
    }

    /// 视频封面读不出来时用的深灰底
    private static let placeholderImage: CGImage = {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.setFillColor(CGColor(gray: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()!
    }()

    /// 所有缩略图共用的行为：关闭、拖出后收起、悬停暂停计时，然后滑入
    private func present(_ entry: Entry) {
        configureCommon(entry)
        entries.append(entry)
        layout(newest: entry)
        scheduleDismiss(entry)
    }

    private func configureCommon(_ entry: Entry) {
        let view = entry.view
        view.onClose = { [weak self, weak entry] in
            guard let entry else { return }
            self?.dismiss(entry)
        }
        view.onDragFinished = { [weak self, weak entry] in
            guard let entry else { return }
            self?.dismiss(entry)
        }
        view.onHoverChanged = { [weak self, weak entry] hovering in
            guard let self, let entry else { return }
            // 鼠标停在缩略图上时不自动消失；导出 GIF 期间也不消失
            if hovering { entry.timer?.invalidate() } else if entry.exportTask == nil { self.scheduleDismiss(entry) }
        }
    }

    // MARK: - 布局与动画

    /// 从右下角往上堆叠；最新的在最下面，从右侧滑入
    private func layout(newest: Entry? = nil) {
        guard let screen else { return }
        let visible = screen.visibleFrame
        var y = visible.minY + Self.margin
        for entry in entries.reversed() {
            let size = entry.panel.frame.size
            let target = CGRect(x: visible.maxX - Self.margin - size.width, y: y, width: size.width, height: size.height)
            y += size.height + Self.spacing
            if entry === newest {
                entry.panel.setFrame(target.offsetBy(dx: size.width + Self.margin, dy: 0), display: false)
                entry.panel.alphaValue = 0
                entry.panel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                entry.panel.animator().setFrame(target, display: true)
                entry.panel.animator().alphaValue = 1
            }
        }
    }

    private func scheduleDismiss(_ entry: Entry) {
        entry.timer?.invalidate()
        entry.timer = Timer.scheduledTimer(withTimeInterval: entry.lifetime, repeats: false) { [weak self, weak entry] _ in
            MainActor.assumeIsolated {
                guard let self, let entry else { return }
                self.dismiss(entry)
            }
        }
    }

    /// 收起某张截图的缩略图（截图被粘贴后调用）
    func dismiss(_ capture: CapturedImage) {
        if let entry = entries.first(where: { $0.capture === capture }) {
            dismiss(entry)
        }
    }

    private func dismiss(_ entry: Entry) {
        guard let index = entries.firstIndex(where: { $0 === entry }) else { return }
        entries.remove(at: index)
        entry.timer?.invalidate()
        entry.exportTask?.cancel()   // 导出中关闭 = 取消导出
        entry.exportTask = nil
        let panel = entry.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.close()
        })
        layout()
    }

    #if DEBUG
    /// 自测用：钉住最新一张缩略图
    func debugPinNewest() -> PinWindow? {
        guard let entry = entries.last, let capture = entry.capture else { return nil }
        let window = PinManager.shared.pin(capture)
        dismiss(entry)
        return window
    }
    var debugNewestFileURL: URL? { entries.last?.capture?.fileURL }
    /// 自测用：单击最新一张缩略图（打开编辑窗口）
    func debugOpenNewest() -> AnnotationEditorWindowController? {
        guard let entry = entries.last, let capture = entry.capture else { return nil }
        let editor = AnnotationEditorWindowController.open(capture)
        dismiss(entry)
        return editor
    }
    /// 自测用：点最新一张缩略图的「保存」
    func debugSaveNewest() {
        entries.last?.view.onSave?()
    }
    var debugNewestFrame: CGRect? { entries.last?.panel.frame }
    func debugHoverNewest() { entries.last?.view.debugSetHovered(true) }
    var debugNewestView: ThumbnailView? { entries.last?.view }
    var debugNewestVideoURL: URL? { entries.last?.videoURL }
    func debugDismissAll() { for entry in entries { dismiss(entry) } }
    var debugNewestIsExporting: Bool { entries.last?.exportTask != nil }
    var debugFrames: [CGRect] { entries.map(\.panel.frame) }
    /// README 截图用：不需要视频文件的录屏缩略图
    func debugShowRecording(poster: CGImage, videoSize: CGSize, duration: TimeInterval, on screen: NSScreen) {
        let size = Self.fittedSize(videoSize)
        let view = ThumbnailView(image: poster, size: size, scale: screen.backingScaleFactor, kind: .recording(duration: duration))
        let entry = Entry(panel: Self.makePanel(size: size, view: view), view: view, capture: nil, videoURL: nil, lifetime: 600)
        self.screen = screen
        present(entry)
    }
    #endif
}
