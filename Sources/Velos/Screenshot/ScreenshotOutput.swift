import AppKit

/// 截图完成后的输出选项（默认取自设置；自测时可以传入单独的选项，不改动用户设置）
struct OutputOptions {
    var copyToClipboard: Bool
    var saveToFile: Bool
    var showThumbnail: Bool
    /// 截图被粘贴后自动收起缩略图
    var hideThumbnailAfterPaste: Bool
    var format: ImageFormat
    /// JPEG / HEIC 的压缩质量 0~1
    var quality: Double
    /// 按 1x 输出（缩小到「点」尺寸以减小体积）
    var downscaleTo1x: Bool
    var directory: URL
    var pasteboard: NSPasteboard

    @MainActor
    static func current() -> OutputOptions {
        let prefs = Preferences.shared
        return OutputOptions(
            copyToClipboard: prefs.screenshotCopyToClipboard,
            saveToFile: prefs.screenshotSaveToFile,
            showThumbnail: prefs.screenshotShowThumbnail,
            hideThumbnailAfterPaste: prefs.hideThumbnailAfterPaste,
            format: prefs.imageFormat,
            quality: prefs.jpegQuality,
            downscaleTo1x: prefs.screenshotSaveAs1x,
            directory: SaveLocation.directory(for: .screenshot),
            pasteboard: .general
        )
    }
}

/// 截图结果的输出：复制到剪贴板、保存到文件、屏幕角落显示缩略图。
///
/// 保存时机：默认按 Enter 只复制 + 显示缩略图，不自动存文件；
/// 用户在缩略图上点「保存」或在截图界面按 ⌘S 才保存（设置里可改为每次自动保存）。
///
/// 画质：
/// - 默认以原生像素输出，不缩放、不压缩（PNG 无损）
/// - 文件里写入色彩配置文件（Display P3 或 sRGB）和 DPI
/// - 剪贴板始终放 PNG（无损），格式设置只影响保存的文件
@MainActor
enum ScreenshotOutput {
    #if DEBUG
    /// 自测用：固定输出选项（复制 + 缩略图、不自动保存、PNG），写入私有剪贴板，不受也不影响用户设置
    static var dryRun = false
    /// 自测用：文件保存到这里，而不是用户的保存文件夹
    static var dryRunDirectory: URL?
    #endif

    /// 当前设置；forceSave 表示这次明确要求保存（⌘S、缩略图上的「保存」）
    private static func resolvedOptions(_ options: OutputOptions?, forceSave: Bool) -> OutputOptions {
        var options = options ?? .current()
        #if DEBUG
        if dryRun {
            options.pasteboard = NSPasteboard(name: .init("local.velos.selftest"))
            options.copyToClipboard = true
            options.showThumbnail = true
            options.hideThumbnailAfterPaste = true
            options.saveToFile = false
            options.format = .png
            options.downscaleTo1x = false
        }
        if let dryRunDirectory { options.directory = dryRunDirectory }
        #endif
        if forceSave { options.saveToFile = true }
        return options
    }

    /// 截图完成后的输出
    /// - Parameters:
    ///   - image: 原生像素截图
    ///   - scale: 每点像素数
    ///   - sourceRect: 截取的位置（全局坐标），钉图时钉在原位
    ///   - forceSave: 无论设置如何都保存文件（截图界面按 ⌘S）
    static func deliver(_ image: CGImage, scale: CGFloat, sourceRect: CGRect,
                        forceSave: Bool = false, options: OutputOptions? = nil) {
        let options = resolvedOptions(options, forceSave: forceSave)
        let capture = CapturedImage(image: image, scale: scale, sourceRect: sourceRect)

        // 缩略图先出现（不等编码），手感更快
        if options.showThumbnail {
            ThumbnailManager.shared.show(capture)
        }
        guard options.copyToClipboard || options.saveToFile else { return }

        // 截图一被粘贴（有程序来读剪贴板），对应的缩略图就完成了使命，自动收起。
        // 弱引用：剪贴板内容可能保留很久，不能因此一直占着这张截图的内存
        let onPaste: (() -> Void)? = options.showThumbnail && options.hideThumbnailAfterPaste
            ? { [weak capture] in
                guard let capture else { return }
                Log.capture.notice("截图已被粘贴，收起缩略图")
                ThumbnailManager.shared.dismiss(capture)
            }
            : nil

        // 文件名在主线程确定（与截图时间一致），编码和写文件放到后台
        let fileName = SaveLocation.fileName(prefix: "截图", fileExtension: options.format.fileExtension, date: capture.date)
        Task.detached(priority: .userInitiated) {
            let result = encodeAndSave(image, scale: scale, fileName: fileName, options: options)
            await MainActor.run {
                if let png = result.png {
                    ClipboardWriter.write(png: png, to: options.pasteboard, onFirstRead: onPaste)
                    Log.capture.notice("已复制到剪贴板（PNG，\(png.count / 1024) KB）")
                }
                // 有了原生分辨率的无损 PNG，缩略图就不必再保留十几 MB 的未压缩图像
                if let native = result.nativePNG {
                    capture.adoptNativePNG(native)
                }
                if let url = result.fileURL {
                    capture.fileURL = url
                    Log.capture.notice("已保存：\(url.lastPathComponent, privacy: .public)")
                }
                if let error = result.error {
                    showError(error)
                }
            }
        }
    }

    /// 把一张已有的截图保存到文件（缩略图上的「保存」按钮）。
    /// 使用当前设置的格式、质量、1x 选项和保存文件夹；已经保存过则不重复保存。
    static func save(_ capture: CapturedImage) {
        guard capture.fileURL == nil, !capture.isSaving, let image = capture.image else { return }
        capture.isSaving = true
        var options = resolvedOptions(nil, forceSave: true)
        options.copyToClipboard = false
        let scale = capture.scale
        let fileName = SaveLocation.fileName(prefix: "截图", fileExtension: options.format.fileExtension, date: capture.date)
        Task.detached(priority: .userInitiated) {
            let result = encodeAndSave(image, scale: scale, fileName: fileName, options: options)
            await MainActor.run {
                capture.isSaving = false
                if let url = result.fileURL {
                    capture.fileURL = url
                    Log.capture.notice("已保存：\(url.lastPathComponent, privacy: .public)")
                }
                if let error = result.error {
                    showError(error)
                }
            }
        }
    }

    private struct EncodeResult {
        /// 放进剪贴板的 PNG（可能是 1x 的）
        var png: Data?
        /// 原生分辨率的无损 PNG（如果顺带编码出来了）
        var nativePNG: Data?
        var fileURL: URL?
        var error: String?
    }

    /// 后台执行：按需缩小到 1x，编码 PNG（剪贴板）和设置的格式（文件），写入文件
    nonisolated private static func encodeAndSave(_ image: CGImage, scale: CGFloat, fileName: String,
                                                  options: OutputOptions) -> EncodeResult {
        var result = EncodeResult()
        var output = image
        var outputScale = scale
        if options.downscaleTo1x, scale > 1, let small = ImageEncoder.downscaled(image, by: scale) {
            output = small
            outputScale = 1
        }

        let isNative = output === image
        if options.copyToClipboard {
            result.png = ImageEncoder.encode(output, format: .png, quality: 1, scale: outputScale)
            if result.png == nil { result.error = "PNG 编码失败，未能复制到剪贴板。" }
            if isNative { result.nativePNG = result.png }
        }

        if options.saveToFile {
            // 保存格式也是 PNG 时直接复用，不重复编码
            let data = (options.format == .png ? result.png : nil)
                ?? ImageEncoder.encode(output, format: options.format, quality: options.quality, scale: outputScale)
            guard let data else {
                result.error = "\(options.format.title) 编码失败，截图未保存。"
                return result
            }
            if isNative, options.format == .png { result.nativePNG = data }
            do {
                try FileManager.default.createDirectory(at: options.directory, withIntermediateDirectories: true)
                let url = SaveLocation.uniqueURL(in: options.directory, fileName: fileName)
                try data.write(to: url, options: .atomic)
                result.fileURL = url
            } catch {
                result.error = "无法保存到「\(options.directory.path)」：\(error.localizedDescription)"
            }
        }
        return result
    }

    /// 输出失败要明确告诉用户，不能静默失败
    private static func showError(_ message: String) {
        Log.capture.error("截图输出失败：\(message, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "截图输出失败"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "打开设置")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            SettingsLauncher.open(.general)
        }
    }
}
