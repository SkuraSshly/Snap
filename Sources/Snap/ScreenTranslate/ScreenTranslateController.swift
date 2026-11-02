import AppKit
import SnapOCRKit

/// 截屏翻译的总调度：选区界面关闭后接手，识别文字、显示加载动画和结果。
///
/// - 松开鼠标立即在选区旁边弹出结果窗口（TranslationWindow），识别结果、译文随后填进来（不用转圈动画）
/// - 识别不到文字：窗口里提示「未识别到文字」，1.5 秒后自己关闭
/// - 识别完成立刻用 Apple 系统翻译翻译
/// 所有窗口都是 Snap 自己的窗口，下次冻屏时会被排除，不会出现在被识别的截图里（见 ScreenFreezer.ownWindows）。
@MainActor
final class ScreenTranslateController {
    static let shared = ScreenTranslateController()

    private var hud: RecognitionHUD?   // 预留：识别失败等全局提示
    /// 正在识别的任务（新的截屏翻译开始时取消上一个）
    private var task: Task<Void, Never>?
    /// 没钉住的结果窗口（同一时间只有一个；新的截屏翻译会替换它）
    private var preview: TranslationWindow?
    /// 钉住的结果窗口（可以有多个，新的截屏翻译不影响它们）
    private var pinned: [TranslationWindow] = []
    /// 正在识别的那个窗口（它被关掉时停止识别）
    private weak var recognizingWindow: TranslationWindow?

    private init() {}

    /// 预热：按下 ⌥D、选区界面出现时，用一张很小的内置图片先识别一次，让识别服务启动、加载识别模型，
    /// 用户还在框选时就准备好了。只在按下 ⌥D 后进行，空闲时不占 CPU 和内存（服务空闲 30 秒后自己退出）。
    /// （新安装或更新 Snap 后的第一次识别，系统要为新程序准备模型，可能需要十几秒；之后每次都很快。）
    func warmUp() {
        guard warmUpTask == nil else { return }
        warmUpTask = Task { @MainActor in
            defer { warmUpTask = nil }
            guard let image = Self.warmUpImage() else { return }
            var options = TextRecognizer.Options()
            options.selectsBestCandidate = false
            let started = ContinuousClock.now
            _ = try? await OCRClient.shared.recognize(image, pointSize: CGSize(width: 120, height: 40), options: options)
            let elapsed = ContinuousClock.now - started
            Log.capture.notice("截屏翻译：OCR 预热完成，耗时 \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        }
    }

    private var warmUpTask: Task<Void, Never>?

    /// 一次性完整预热：macOS 26 起，Vision 的文字识别模型没有预先编译好，每种识别配置（自动、指定某种语言）
    /// 第一次用到时系统要现场编译它的神经网络，一个要十几到二十几秒，编译结果缓存在本机。
    /// 第一次碰到某种文字时就会卡这么久（Easydict 用久了缓存已经齐全，所以感觉不到）。
    /// 这里在 Snap 启动一会儿后，用一张小图把可能用到的每种配置都识别一次，让系统提前编译好。
    /// 每个系统版本只做一次（缓存按系统版本区分）；有截屏翻译在进行时暂停让路。
    func warmUpAllIfNeeded() {
        #if !DEBUG
        let build = ProcessInfo.processInfo.operatingSystemVersionString
        let key = "ocrFullWarmUpBuild"
        guard UserDefaults.standard.string(forKey: key) != build else { return }
        Task(priority: .background) { @MainActor in
            try? await Task.sleep(for: .seconds(20))   // 不和启动抢资源
            guard let image = Self.warmUpImage() else { return }
            let started = ContinuousClock.now
            Log.capture.notice("截屏翻译：开始一次性完整预热（让系统预先编译识别模型）")
            for language in [nil] + TranslateLanguage.recognitionOrder.map(Optional.some) {
                // 用户正在截屏翻译：等它结束，不抢识别服务
                while preview != nil {
                    try? await Task.sleep(for: .seconds(2))
                }
                var options = TextRecognizer.Options()
                options.language = language
                options.selectsBestCandidate = false
                options.smartLayout = false
                let one = ContinuousClock.now
                _ = try? await OCRClient.shared.recognize(image, pointSize: CGSize(width: 120, height: 40), options: options)
                let cost = ContinuousClock.now - one
                if cost > .seconds(1) {
                    Log.capture.notice("截屏翻译：预热 \(language?.rawValue ?? "自动", privacy: .public) 编译了新模型，耗时 \(cost.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)")
                }
            }
            UserDefaults.standard.set(build, forKey: key)
            Log.capture.notice("截屏翻译：完整预热完成，共 \((ContinuousClock.now - started).formatted(.units(allowed: [.seconds])), privacy: .public)")
        }
        #endif
    }

    /// 按设置生成识别参数：智能排版、二维码、OCR 优先语言（排在系统语言前面）
    static var recognitionOptions: TextRecognizer.Options {
        let prefs = Preferences.shared
        var options = TextRecognizer.Options()
        options.smartLayout = prefs.ocrSmartLayout
        options.detectsQRCodes = prefs.ocrDetectsQRCodes
        if let preferred = TranslateLanguage(rawValue: prefs.ocrPreferredLanguage) {
            options.preferredLanguages = [preferred] + TranslateLanguage.systemPreferred.filter { $0 != preferred }
        }
        return options
    }

    /// 预热用的小图：白底黑字「Snap 截屏」
    private nonisolated static func warmUpImage() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 240, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 80))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Snap 截屏", attributes: [
            .font: CTFontCreateWithName("PingFangSC-Regular" as CFString, 36, nil),
            .foregroundColor: CGColor(gray: 0, alpha: 1),
        ]))
        ctx.textPosition = CGPoint(x: 16, y: 24)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    /// 松开鼠标后立即在选区旁边弹出结果窗口（与 Easydict 一样先出窗口），识别结果和译文随后填进去；
    /// 识别不到文字时窗口里显示「未识别到文字」，1.5 秒后自己关闭。
    func recognize(_ crop: FrozenDisplay.Crop) {
        task?.cancel()
        hud?.close()
        preview?.close()
        let started = ContinuousClock.now
        let pointSize = CGSize(width: CGFloat(crop.image.width) / crop.scale, height: CGFloat(crop.image.height) / crop.scale)

        let model = TranslationModel(recognizing: ())
        let window = TranslationWindow(model: model, near: crop.sourceRect)
        window.onClose = { [weak self, weak window] in
            guard let self, let window else { return }
            if self.preview === window { self.preview = nil }
            self.pinned.removeAll { $0 === window }
            if self.recognizingWindow === window { self.task?.cancel() }   // 识别中就关了窗口：不用再识别
        }
        window.onPinChange = { [weak self, weak window] isPinned in
            guard let self, let window else { return }
            if isPinned {
                if self.preview === window { self.preview = nil }
                if !self.pinned.contains(where: { $0 === window }) { self.pinned.append(window) }
            } else {
                // 取消钉住：它变回普通窗口；原来那个没钉住的窗口关掉（同一时间只留一个）
                self.pinned.removeAll { $0 === window }
                if let old = self.preview, old !== window { old.close(reason: "另一个窗口取消了钉住") }
                self.preview = window
            }
        }
        if model.isPinned { pinned.append(window) } else { preview = window }
        recognizingWindow = window
        window.show()
        Log.capture.notice("截屏翻译：结果窗口已出现，耗时 \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")

        // 识别超过 2 秒：多半是系统在第一次编译这种文字的识别模型，告诉用户在等什么
        let slowNotice = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, model.isRecognizing { model.markSlowRecognition() }
        }
        task = Task { @MainActor [weak window] in
            defer { slowNotice.cancel() }
            do {
                let result = try await OCRClient.shared.recognize(crop.image, pointSize: pointSize, options: Self.recognitionOptions)
                guard !Task.isCancelled else { return }
                let elapsed = ContinuousClock.now - started
                Log.capture.notice("截屏翻译：识别完成，耗时 \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)，\(result.text.count) 字，语言 \(result.language?.rawValue ?? "?", privacy: .public)")
                model.didRecognize(result, elapsed: elapsed)
                // 等译文出来，只为记一下总耗时（不影响界面）
                while model.isPending, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                Log.capture.notice("截屏翻译：从松开鼠标到显示译文共 \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            } catch is CancellationError {
            } catch OCRError.noText {
                guard !Task.isCancelled else { return }
                Log.capture.notice("截屏翻译：未识别到文字")
                model.didFailRecognition("未识别到文字")
                try? await Task.sleep(for: .milliseconds(1500))
                window?.close(reason: "未识别到文字")
            } catch {
                guard !Task.isCancelled else { return }
                Log.capture.error("截屏翻译：识别失败 \(error.localizedDescription, privacy: .public)")
                model.didFailRecognition("识别失败：\(error.localizedDescription)")
            }
        }
    }

    #if DEBUG
    var debugPreview: TranslationWindow? { preview ?? pinned.last }
    var debugPinned: [TranslationWindow] { pinned }
    /// 自测结束：关掉所有结果窗口
    func debugCloseAll() {
        preview?.close(reason: "自测")
        pinned.forEach { $0.close(reason: "自测") }
    }
    var debugHUD: RecognitionHUD? { hud }
    /// 等识别结束（自测用）
    func debugWait() async { await task?.value }
    #endif
}
