import AppKit
import VelosOCRKit
import SwiftUI
import Translation

/// 结果窗口的状态：原文、语言、译文。翻译用 Apple 系统翻译（离线、免费、不联网）。
///
/// Apple 翻译只能通过 SwiftUI 的 .translationTask 拿到翻译会话（见 TranslationView）：
/// 这里每次需要翻译时更新 configuration，界面就会调用 perform(session:)。
/// 语言包没下载时，系统会在结果窗口上弹出下载提示；下载完成后断网也能用。
@MainActor
final class TranslationModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        /// 第一次使用这对语言：需要下载离线语言包（系统会弹出下载提示）
        case needsDownload
        case translating
        case done
        case failed(String)
    }

    /// 原文（可编辑；编辑后停顿 0.6 秒自动重新翻译）
    @Published var sourceText: String {
        didSet {
            guard sourceText != oldValue, !isLoading else { return }
            detected = detector.detect(sourceText) ?? detected
            scheduleTranslation()
            if !DictionaryLookup.shouldLookUp(sourceText) { dictionaryEntry = nil }
        }
    }
    /// 用户选的原文语言；nil 表示自动检测
    @Published var sourceChoice: TranslateLanguage? { didSet { if sourceChoice != oldValue, !isLoading { translate() } } }
    /// 用户选的目标语言；nil 表示按规则自动（中文 → 英文，其他 → 简体中文）
    @Published var targetChoice: TranslateLanguage? { didSet { if targetChoice != oldValue, !isLoading { translate() } } }
    @Published private(set) var detected: TranslateLanguage?
    @Published private(set) var translation = ""
    /// 译文正在逐段出来（已经显示的部分是新的，不是上一次的旧译文）
    @Published private(set) var isPartial = false
    @Published private(set) var status = Status.idle {
        didSet { if status == .done, oldValue != .done { didFinishTranslation() } }
    }
    /// 交给 .translationTask 的配置；变化时界面开始翻译
    @Published var configuration: TranslationSession.Configuration?

    /// 识别耗时（识别完成前为 nil）
    @Published private(set) var recognitionTime: Duration?
    /// 正在识别文字（窗口在松开鼠标时就出现，识别结果随后填进来）
    @Published private(set) var isRecognizing = false
    /// 识别失败或没有文字时的提示
    @Published private(set) var recognitionFailure: String?
    /// 当前使用的翻译引擎（默认引擎来自设置；结果窗口里可以切换）
    @Published private(set) var engine: EngineID = EngineRouting.preferred
    /// 默认引擎失败、自动换了别的引擎时的说明（例如「DeepL 失败（额度用完了），已切换到 Apple 翻译」）
    @Published private(set) var engineNotice: String?
    /// 单个单词或短语时的词典结果（macOS 自带词典，离线）
    @Published private(set) var dictionaryEntry: DictionaryEntry?
    /// 钉住：置顶、点别处不关闭、可以拖动和调整大小
    @Published var isPinned = false
    /// 用户拖过窗口边缘调整了大小：之后内容自适应窗口，而不是窗口随内容变高
    @Published var isFreeSized = false
    /// 识别超过 2 秒（多半是系统第一次编译这种文字的识别模型）
    @Published private(set) var isSlowRecognition = false
    private let detector = LanguageDetector(preferredLanguages: TranslateLanguage.systemPreferred)
    private var debounce: Task<Void, Never>?
    private var isLoading = true
    /// 这次翻译请求的原文（翻译期间原文又改了，就丢弃旧结果）
    private var requestedText = ""

    /// 实际使用的原文语言
    var sourceLanguage: TranslateLanguage { sourceChoice ?? detected ?? .english }
    /// 实际使用的目标语言：窗口里选的 > 设置里的默认目标语言 > 自动规则；与原文相同时自动换成另一种
    var targetLanguage: TranslateLanguage {
        let preferred = targetChoice ?? TranslateLanguage(rawValue: Preferences.shared.defaultTargetLanguage)
        return LanguageRules.resolvedTarget(preferred ?? LanguageRules.defaultTarget(for: sourceLanguage), source: sourceLanguage)
    }

    init(result: OCRResult, recognitionTime: Duration) {
        sourceText = result.text
        detected = result.language ?? LanguageDetector(preferredLanguages: TranslateLanguage.systemPreferred).detect(result.text)
        self.recognitionTime = recognitionTime
        isLoading = false
        lookUpDictionary()
    }

    /// 还在识别：窗口先出现，显示占位，识别结果出来后调用 didRecognize
    init(recognizing: Void) {
        sourceText = ""
        isRecognizing = true
        isLoading = false
    }

    /// 识别完成：填入原文，立即开始翻译
    func didRecognize(_ result: OCRResult, elapsed: Duration) {
        isLoading = true
        sourceText = result.text
        detected = result.language ?? detector.detect(result.text)
        recognitionTime = elapsed
        isRecognizing = false
        isLoading = false
        translate()
        lookUpDictionary()
    }

    /// 单个单词或短语：查系统词典（在后台查，查完时原文没变才显示）
    private func lookUpDictionary() {
        let text = sourceText
        guard DictionaryLookup.shouldLookUp(text) else {
            dictionaryEntry = nil
            return
        }
        Task { @MainActor in
            let entry = await Task.detached(priority: .userInitiated) { DictionaryLookup.lookUp(text) }.value
            guard text == sourceText else { return }
            dictionaryEntry = entry
        }
    }

    func markSlowRecognition() { isSlowRecognition = true }

    /// 识别失败或没有文字
    func didFailRecognition(_ message: String) {
        isRecognizing = false
        recognitionFailure = message
    }

    // MARK: - 翻译

    /// 原文编辑停顿后再翻译，避免每打一个字就翻译一次
    private func scheduleTranslation() {
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.translate()
            self?.lookUpDictionary()
        }
    }

    /// 立即翻译（换语言、⌘R 重新翻译时）
    func translate() {
        debounce?.cancel()
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            translation = ""
            status = .idle
            return
        }
        requestedText = sourceText
        let source = sourceLanguage, target = targetLanguage
        engineNotice = nil
        if engine != .apple {
            translateOnline(text: sourceText, source: source, target: target, chain: fallbackChain(startingWith: engine))
            return
        }
        translateWithApple(source: source, target: target)
    }

    /// 在结果窗口里换一个引擎重新翻译
    func use(_ engine: EngineID) {
        self.engine = engine
        translate()
    }

    /// 失败时依次尝试的引擎：先是选中的，再是其他已启用的在线引擎，最后是 Apple 翻译
    private func fallbackChain(startingWith first: EngineID) -> [EngineID] {
        let online = EngineRouting.available.filter { $0 != .apple && $0 != first }
        return [first] + online + (first == .apple ? [] : [.apple])
    }

    /// 在线引擎翻译；失败就换下一个，并在译文区小字说明（换到 Apple 时走 Apple 的流程）
    private func translateOnline(text: String, source: TranslateLanguage, target: TranslateLanguage, chain: [EngineID],
                                 failures: [String] = []) {
        guard let current = chain.first else { return }
        if current == .apple {
            engine = .apple
            engineNotice = failures.isEmpty ? nil : failures.joined(separator: "；") + "，已切换到 Apple 翻译"
            translateWithApple(source: source, target: target, keepNotice: true)
            return
        }
        status = .translating
        isPartial = false
        Task { @MainActor in
            let started = ContinuousClock.now
            do {
                // 大模型：译文一边生成一边显示
                // 外层任务已经持有 self，这里直接用（不再写 [weak self]：和外层的强引用矛盾，编译器会警告）
                let output = try await current.translate(text, from: source, to: target) { partial in
                    guard text == self.sourceText, source == self.sourceLanguage, target == self.targetLanguage,
                          self.status == .translating else { return }
                    self.translation = partial
                    self.isPartial = true
                }
                isPartial = false
                guard text == sourceText, source == sourceLanguage, target == targetLanguage else { return }
                translation = output
                if !failures.isEmpty {
                    engine = current
                    engineNotice = failures.joined(separator: "；") + "，已切换到 \(current.displayName)"
                }
                status = .done
                Log.capture.notice("截屏翻译：\(current.displayName, privacy: .public) 翻译完成，耗时 \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            } catch is CancellationError {
            } catch {
                guard text == sourceText else { return }
                let reason = "\(current.displayName) 失败（\(error.localizedDescription)）"
                Log.capture.error("截屏翻译：\(reason, privacy: .public)")
                translateOnline(text: text, source: source, target: target, chain: Array(chain.dropFirst()),
                                failures: failures + [reason])
            }
        }
    }

    /// Apple 翻译：语言包已下载时直接翻译（逐段显示），否则通过窗口的 .translationTask（必要时弹下载提示）
    private func translateWithApple(source: TranslateLanguage, target: TranslateLanguage, keepNotice: Bool = false) {
        #if DEBUG
        // 自测：用假的 Apple 翻译（自测机器上没有下载语言包，也不能弹下载提示）
        if let stub = Self.debugTranslator {
            status = .translating
            Task { @MainActor in
                do {
                    let output = try await stub(sourceText, source, target)
                    guard requestedText == sourceText else { return }
                    translation = output
                    status = .done
                } catch {
                    status = .failed(Self.describe(error))
                }
            }
            return
        }
        #endif
        status = .checking
        Task { @MainActor in
            let started = ContinuousClock.now
            let availability: LanguageAvailability.Status
            if #available(macOS 26.0, *) {
                availability = await AppleTranslator.shared.status(from: source, to: target)
            } else {
                availability = await LanguageAvailability().status(from: source.localeLanguage, to: target.localeLanguage)
            }
            guard requestedText == sourceText, source == sourceLanguage, target == targetLanguage else { return }
            // 快速通道：语言包已下载时直接翻译，不经过窗口（macOS 26 起）
            if #available(macOS 26.0, *), availability == .installed {
                status = .translating
                let text = sourceText
                do {
                    // 逐段显示：每翻好一段就更新，长文不用等整篇翻完
                    let output = try await AppleTranslator.shared.translateByParagraph(text, from: source, to: target) { partial in
                        guard text == sourceText, source == sourceLanguage, target == targetLanguage else { return }
                        translation = partial
                        isPartial = true
                    }
                    guard text == sourceText, source == sourceLanguage, target == targetLanguage else { return }
                    translation = output
                    isPartial = false
                    status = .done
                    Log.capture.notice("截屏翻译：Apple 翻译完成（直接），耗时 \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)，\(source.rawValue, privacy: .public) → \(target.rawValue, privacy: .public)")
                } catch is CancellationError {
                } catch {
                    Log.capture.error("截屏翻译：Apple 翻译失败 \(String(describing: error), privacy: .public)")
                    appleFailed(Self.describe(error), source: source, target: target, alreadyFellBack: keepNotice)
                }
                return
            }
            switch availability {
            case .unsupported:
                appleFailed("Apple 翻译暂不支持「\(source.displayName) → \(target.displayName)」", source: source, target: target,
                            alreadyFellBack: keepNotice)
                return
            case .supported:
                // 没下载语言包：开始翻译时系统会弹出下载提示；把 Velos 切到前台，提示才能点
                status = .needsDownload
                NSApp.activate()
            case .installed:
                status = .translating
            @unknown default:
                status = .translating
            }
            if let current = configuration, current.source == source.localeLanguage, current.target == target.localeLanguage {
                configuration?.invalidate()   // 同一对语言：让界面再执行一次翻译
            } else {
                configuration = TranslationSession.Configuration(source: source.localeLanguage, target: target.localeLanguage)
            }
        }
    }

    /// Apple 翻译失败：有启用的在线引擎就换过去，否则显示原因
    private func appleFailed(_ reason: String, source: TranslateLanguage, target: TranslateLanguage, alreadyFellBack: Bool) {
        let online = EngineRouting.available.filter { $0 != .apple }
        if !alreadyFellBack, !online.isEmpty {
            translateOnline(text: sourceText, source: source, target: target, chain: online,
                            failures: ["Apple 翻译失败（\(reason)）"])
        } else {
            status = .failed(reason)
        }
    }

    /// 由 .translationTask 调用：拿到系统的翻译会话后翻译当前原文
    func perform(session: TranslationSession) async {
        let text = sourceText
        let started = ContinuousClock.now
        do {
            if status == .needsDownload {
                // 先让系统完成下载（弹出提示；用户拒绝时会抛出错误）
                try await session.prepareTranslation()
                status = .translating
            }
            let response = try await session.translate(text)
            guard text == sourceText else { return }   // 翻译期间原文又改了：等下一次
            translation = LanguageRules.normalizedChinese(response.targetText, target: targetLanguage)
            status = .done
            Log.capture.notice("截屏翻译：Apple 翻译完成，耗时 \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public)，\(self.sourceLanguage.rawValue, privacy: .public) → \(self.targetLanguage.rawValue, privacy: .public)")
        } catch is CancellationError {
            // 窗口关闭或换了新的翻译请求
        } catch {
            status = .failed(Self.describe(error))
            Log.capture.error("截屏翻译：Apple 翻译失败 \(String(describing: error), privacy: .public)")
        }
    }

    /// 翻译完成：设置里打开了「自动复制译文」就复制
    private func didFinishTranslation() {
        guard !isPartial, !translation.isEmpty, Preferences.shared.translateAutoCopy else { return }
        let pasteboard = TranslationWindow.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(translation, forType: .string)
    }

    /// 正在准备或进行翻译（还没有结果）
    var isPending: Bool { status == .checking || status == .translating }

    /// 交换原文和目标语言（自动检测时用检测到的语言）
    func swapLanguages() {
        let source = sourceLanguage, target = targetLanguage
        isLoading = true
        sourceChoice = target
        targetChoice = source
        isLoading = false
        translate()
    }

    /// 简短的失败原因
    static func describe(_ error: Error) -> String {
        if let error = error as? TranslationError {
            switch error {
            case .unsupportedSourceLanguage: return "Apple 翻译不支持这种原文语言"
            case .unsupportedTargetLanguage: return "Apple 翻译不支持这种目标语言"
            case .unsupportedLanguagePairing: return "Apple 翻译不支持这对语言"
            case .nothingToTranslate: return "没有可翻译的文字"
            case .unableToIdentifyLanguage: return "无法判断原文语言，请手动选择"
            default: break
            }
            if String(describing: error).contains("notInstalled") {
                return "离线语言包没有下载。可以再试一次（会弹出下载提示），或到 系统设置 › 通用 › 语言与地区 › 翻译语言 里下载"
            }
        }
        if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSUserCancelledError {
            return "已取消下载语言包"
        }
        return "翻译失败：\(error.localizedDescription)"
    }

    #if DEBUG
    /// 自测：用假的翻译代替 Apple 翻译（自测机器上没有下载语言包，也不能弹下载提示）
    static var debugTranslator: ((String, TranslateLanguage, TranslateLanguage) async throws -> String)?
    #endif
}
