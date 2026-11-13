import CoreGraphics
import Foundation
@preconcurrency import Vision

/// 文字识别结果
public struct OCRResult: Sendable {
    /// 排版后的文字（段落之间空一行）
    public var text: String
    /// 识别语言；自动识别时是检测到的语言
    public var language: TranslateLanguage?
    /// 平均置信度（0~1，多候选择优时可能加上语言检测的置信度）
    public var confidence: Double
    /// 识别出的原始行（Vision 的顺序）
    public var lines: [OCRLine]

    public init(text: String, language: TranslateLanguage?, confidence: Double, lines: [OCRLine]) {
        self.text = text
        self.language = language
        self.confidence = confidence
        self.lines = lines
    }
}

public enum OCRError: LocalizedError {
    case noText

    public var errorDescription: String? { "未识别到文字" }
}

/// 截屏翻译的文字识别：基于 Apple Vision，完全离线。
///
/// 流程：
/// 1. Vision 逐行识别（同时可选识别二维码）
/// 2. 判断是否值得做智能排版：文字够长、或语言很明确时才做；否则逐行原样输出
/// 3. 智能排版：分带、分栏、排阅读顺序，再逐行判断换行 / 分段 / 接续（见 LayoutComposer、LineJoiner）
/// 4. 文字很短、语言又不明确时，可用多个候选语言分别识别，挑最可信的结果
public struct TextRecognizer: Sendable {
    public struct Options: Sendable {
        /// 指定识别语言；nil 为自动
        public var language: TranslateLanguage?
        /// 用户的优先语言（影响识别语言顺序和语言检测）
        public var preferredLanguages: [TranslateLanguage] = TranslateLanguage.systemPreferred
        /// 文字短且语言不明确时，用多个候选语言并发识别后择优（更准，但更慢）
        public var selectsBestCandidate = true
        /// 识别二维码（内容追加在文字后面）
        public var detectsQRCodes = false
        /// 智能排版；关闭时保留原始换行
        public var smartLayout = true

        public init() {}
    }

    public var options = Options()

    public init(options: Options = Options()) {
        self.options = options
    }

    private var detector: LanguageDetector { LanguageDetector(preferredLanguages: options.preferredLanguages) }

    /// 新的识别接口在 macOS 26 上效果稳定，更早的系统用旧接口
    private static var usesModernAPI: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 识别图片里的文字
    /// - Parameters:
    ///   - image: Retina 原生像素的截图
    ///   - pointSize: 截图的点尺寸（像素 ÷ 屏幕倍数），排版换算「差了几个字」时使用
    public func recognize(_ image: CGImage, pointSize: CGSize) async throws -> OCRResult {
        try Task.checkCancellation()
        let qrCodes = options.detectsQRCodes ? Self.detectQRCodes(in: image) : []

        let lines: [OCRLine]
        do {
            lines = try await recognizeLines(in: image, language: options.language)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !qrCodes.isEmpty else { throw error }
            return OCRResult(text: qrCodes.joined(separator: "\n\n"), language: options.language, confidence: 1, lines: [])
        }
        try Task.checkCancellation()
        guard !lines.isEmpty || !qrCodes.isEmpty else { throw OCRError.noText }

        // 粗合并文本：判断语言、决定是否智能排版
        let roughText = lines.map(\.text).joined(separator: "\n")
        let detection = detector.detectWithProbabilities(roughText)
        let confident = options.language != nil
            || roughText.count > 50
            || Self.hasDominantLanguage(detection.probabilities)
            || detection.probabilities.isEmpty

        var result: OCRResult
        if confident, options.smartLayout {
            let layout = LayoutComposer(imageSize: pointSize, language: options.language, detector: detector).compose(lines)
            result = OCRResult(text: layout.text, language: options.language ?? detection.language,
                               confidence: layout.confidence, lines: lines)
        } else {
            result = OCRResult(text: roughText, language: options.language ?? detection.language,
                               confidence: Self.averageConfidence(lines), lines: lines)
        }

        // 文字短、语言不明确：多个候选语言分别识别，挑最可信的
        if !confident, options.selectsBestCandidate, options.language == nil, !detection.probabilities.isEmpty {
            if let best = try await bestCandidate(image, pointSize: pointSize, candidates: detection.probabilities,
                                                  roughText: roughText) {
                result = best
            }
        }

        try Task.checkCancellation()
        Self.append(qrCodes, to: &result)
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OCRError.noText }
        return result
    }

    // MARK: - 语言是否明确

    /// 最高概率 > 0.95 且领先第二名 0.9 以上
    private static func hasDominantLanguage(_ probabilities: [TranslateLanguage: Double]) -> Bool {
        let sorted = probabilities.values.sorted(by: >)
        guard let top = sorted.first else { return false }
        guard sorted.count >= 2 else { return top > 0.95 }
        return top > 0.95 && top - sorted[1] > 0.9
    }

    private static func averageConfidence(_ lines: [OCRLine]) -> Double {
        lines.isEmpty ? 0 : Double(lines.map(\.confidence).reduce(0, +)) / Double(lines.count)
    }

    // MARK: - 多候选择优

    /// 每个候选语言各识别一次；结果的检测语言与识别语言一致才算可信，可信者里取置信度最高的。
    ///
    /// 与 Easydict 不同的一点：指定单一语言识别时，Vision 会把别的文字整行丢掉（例如指定英文时
    /// 「Velos translate test / 截屏翻译自测」只剩英文那行，而且置信度是 1.0，会胜出）。
    /// 所以候选结果的字数比自动识别少了一成以上的，不参加比较——宁可保留完整的自动识别结果。
    /// 还有一种：指定的语言用的是拉丁字母时，Vision 也可能不丢掉中文那行，而是把它认成一串拉丁字母乱码
    /// （例如指定德语时「截屏翻译自测」变成「ÄMì·áN」，字数差不多，乱码又恰好被判断成德语，就会胜出）。
    /// 所以候选结果还要保住自动识别里的非拉丁文字（汉字、假名、谚文、西里尔字母……），丢了一成以上的也不参加比较。
    private func bestCandidate(_ image: CGImage, pointSize: CGSize, candidates: [TranslateLanguage: Double],
                               roughText: String) async throws -> OCRResult? {
        let minimumLetters = Self.letterCount(roughText)
        let languages = candidates.sorted { $0.value > $1.value }.map(\.key)
        var single = self
        single.options.selectsBestCandidate = false
        single.options.detectsQRCodes = false
        let results = await withTaskGroup(of: OCRResult?.self) { group in
            for language in languages {
                var recognizer = single
                recognizer.options.language = language
                group.addTask { try? await recognizer.recognize(image, pointSize: pointSize) }
            }
            var collected: [OCRResult] = []
            for await result in group { if let result { collected.append(result) } }
            return collected
        }
        try Task.checkCancellation()
        let complete = results.filter {
            Double(Self.letterCount($0.text)) >= Double(minimumLetters) * 0.9 && Self.keepsScripts(of: roughText, in: $0.text)
        }
        guard !complete.isEmpty else { return nil }

        let detector = self.detector
        let trusted = complete.compactMap { candidate -> OCRResult? in
            let detection = detector.detectWithProbabilities(candidate.text)
            guard let language = detection.language, language == candidate.language else { return nil }
            var boosted = candidate
            if let probability = detection.probabilities[language], probability >= 0.9 {
                boosted.confidence += probability
            }
            return boosted
        }
        return (trusted.isEmpty ? complete : trusted).max { $0.confidence < $1.confidence }
    }

    /// 候选结果有没有保住原文（自动识别）里的非拉丁文字：每一种文字系统的字符数都不少于原文的九成
    static func keepsScripts(of original: String, in candidate: String) -> Bool {
        let before = scriptCounts(original), after = scriptCounts(candidate)
        return before.allSatisfy { script, count in Double(after[script] ?? 0) >= Double(count) * 0.9 }
    }

    /// 非拉丁文字系统的字符数（拉丁字母不数：乱码多出来的正是拉丁字母）
    private static func scriptCounts(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for scalar in text.unicodeScalars {
            let script: String? = switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2FA1F: "han"
            case 0x3040...0x30FF, 0x31F0...0x31FF: "kana"
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: "hangul"
            case 0x0400...0x052F: "cyrillic"
            case 0x0370...0x03FF: "greek"
            case 0x0600...0x06FF: "arabic"
            case 0x0590...0x05FF: "hebrew"
            case 0x0E00...0x0E7F: "thai"
            case 0x0900...0x097F: "devanagari"
            default: nil
            }
            if let script { counts[script, default: 0] += 1 }
        }
        return counts
    }

    /// 字母、汉字、数字的个数（不算空白和标点）
    private static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
    }

    // MARK: - Vision

    /// 识别语言顺序：默认顺序 → 用户优先语言提前 → 指定语言最先
    private func recognitionLanguages(for language: TranslateLanguage?, modern: Bool) -> [String] {
        var order = TranslateLanguage.recognitionOrder.filter { $0.visionCode(modernAPI: modern) != nil }
        func moveToFront(_ languages: [TranslateLanguage]) {
            for language in languages.reversed() {
                if let index = order.firstIndex(of: language) {
                    order.remove(at: index)
                    order.insert(language, at: 0)
                }
            }
        }
        moveToFront(options.preferredLanguages)
        if let language { moveToFront([language]) }
        return order.compactMap { $0.visionCode(modernAPI: modern) }
    }

    /// 识别所有行；自动语言下一个字都没识别到时用日语再试一次（某些日文标题只有指定日语才认得出）
    private func recognizeLines(in image: CGImage, language: TranslateLanguage?) async throws -> [OCRLine] {
        let lines = try await recognizeOnce(in: image, language: language)
        if lines.isEmpty, language == nil {
            return try await recognizeOnce(in: image, language: .japanese)
        }
        return lines
    }

    private func recognizeOnce(in image: CGImage, language: TranslateLanguage?) async throws -> [OCRLine] {
        let modern = Self.usesModernAPI
        let automatic = language?.visionCode(modernAPI: modern) == nil
        let languages = recognitionLanguages(for: language, modern: modern)
        if #available(macOS 26.0, *) {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = automatic
            request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
            let observations = try await request.perform(on: image)
            return observations.enumerated().compactMap { index, observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return OCRLine(id: index, text: candidate.string, box: Self.box(observation), confidence: candidate.confidence)
            }
        }
        return try await recognizeLegacy(in: image, languages: languages, automatic: automatic)
    }

    @available(macOS 26.0, *)
    private static func box(_ observation: RecognizedTextObservation) -> CGRect {
        // 左边缘取左下角，宽度取上边，高度取右边（文字基本水平时与旧接口的 boundingBox 一致）
        let topLeft = observation.topLeft.cgPoint, topRight = observation.topRight.cgPoint
        let bottomLeft = observation.bottomLeft.cgPoint, bottomRight = observation.bottomRight.cgPoint
        return CGRect(x: bottomLeft.x, y: bottomRight.y, width: topRight.x - topLeft.x, height: topRight.y - bottomRight.y)
    }

    private func recognizeLegacy(in image: CGImage, languages: [String], automatic: Bool) async throws -> [OCRLine] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = automatic
                request.recognitionLanguages = languages
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let lines = (request.results ?? []).enumerated().compactMap { index, observation -> OCRLine? in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        return OCRLine(id: index, text: candidate.string, box: observation.boundingBox, confidence: candidate.confidence)
                    }
                    continuation.resume(returning: lines)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 二维码

    private static func detectQRCodes(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        var seen = Set<String>()
        return (request.results ?? []).compactMap(\.payloadStringValue).filter {
            let key = normalized($0)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    private static func normalized(_ payload: String) -> String {
        payload.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 二维码内容去重后追加在文字之后
    private static func append(_ payloads: [String], to result: inout OCRResult) {
        let existing = Set(result.text.components(separatedBy: "\n").map(normalized))
        let new = payloads.filter { !existing.contains(normalized($0)) }
        guard !new.isEmpty else { return }
        result.text = ([result.text] + new).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
