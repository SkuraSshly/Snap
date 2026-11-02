import Foundation
import NaturalLanguage

/// 语言检测：在系统 NaturalLanguage 的结果上做几项修正，让短文本、中英混排、繁简中文更准。
///
/// 1. 只在支持的语言里选，并给常用语言加先验权重（英文、中文最常见）
/// 2. 用户的优先语言再加分：排得越靠前加得越多
/// 3. 检测为中文时，按简体字比例区分简体 / 繁体
/// 4. 中英混排被判成英文时，看英文是否真的占多数；不是就检测剩下的文字
/// 5. 很短的文本、以数字为主的文本，偏向英文或用户的优先语言
public struct LanguageDetector: Sendable {
    /// 用户的优先语言（设置里的「OCR 优先语言」，默认取系统语言）
    public var preferredLanguages: [TranslateLanguage]

    public init(preferredLanguages: [TranslateLanguage]) {
        self.preferredLanguages = preferredLanguages
    }

    public struct Result: Sendable {
        public let language: TranslateLanguage?
        /// 系统给出的原始概率（未加权）
        public let probabilities: [TranslateLanguage: Double]
    }

    /// 常用语言的先验权重
    private static let hints: [TranslateLanguage: Double] = [
        .english: 2.0, .simplifiedChinese: 1.5, .traditionalChinese: 1.0, .japanese: 0.8, .korean: 0.7,
        .french: 0.8, .spanish: 0.8, .italian: 0.6, .portuguese: 0.7, .german: 0.6, .dutch: 0.4,
        .russian: 0.8, .polish: 0.4, .czech: 0.3, .turkish: 0.08, .catalan: 0.1,
        .arabic: 0.3, .persian: 0.2, .thai: 0.3,
    ]

    public func detect(_ text: String) -> TranslateLanguage? {
        detectWithProbabilities(text).language
    }

    public func detectWithProbabilities(_ text: String, checkMixedScripts: Bool = true) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(language: nil, probabilities: [:]) }

        let raw = Self.rawProbabilities(text)
        guard !raw.isEmpty else { return Result(language: .english, probabilities: raw) }

        // 用户优先语言加分（只给系统真的认为可能的语言加）
        var weighted = raw
        let userFirstIsChinese = preferredLanguages.first?.isChinese ?? false
        for (index, language) in preferredLanguages.enumerated() {
            guard let probability = raw[language] else { continue }
            var boost = max(0.4 - Double(index) * 0.1, 0.1)
            if language == .english { boost += userFirstIsChinese ? 0.1 : 0.2 }
            weighted[language] = probability + boost
        }
        if !preferredLanguages.contains(.english), let english = raw[.english] {
            weighted[.english] = english + 0.2
        }

        guard let best = weighted.max(by: { $0.value < $1.value }) else {
            return Result(language: .english, probabilities: raw)
        }
        let language = correct(best.key, confidence: best.value, text: trimmed,
                               probabilities: weighted, checkMixedScripts: checkMixedScripts)
        return Result(language: language, probabilities: raw)
    }

    static func rawProbabilities(_ text: String) -> [TranslateLanguage: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = TranslateLanguage.allCases.map(\.nlLanguage)
        var hintTable: [NLLanguage: Double] = [:]
        for language in TranslateLanguage.allCases { hintTable[language.nlLanguage] = hints[language] ?? 0.05 }
        recognizer.languageHints = hintTable
        recognizer.processString(text)
        var result: [TranslateLanguage: Double] = [:]
        for (nl, probability) in recognizer.languageHypotheses(withMaximum: 5) {
            if let language = TranslateLanguage(nlLanguage: nl) { result[language] = probability }
        }
        return result
    }

    // MARK: - 修正

    private func correct(_ detected: TranslateLanguage, confidence: Double, text: String,
                         probabilities: [TranslateLanguage: Double], checkMixedScripts: Bool) -> TranslateLanguage {
        // 中文：按简体字比例分简繁
        if detected.isChinese {
            return Self.chineseVariant(of: text)
        }
        // 中英混排被判成英文
        if checkMixedScripts, detected == .english, Self.scriptCount(of: text) >= 2 {
            let englishWords = TextTraits.wordComponents(text).filter { TextTraits.isASCIIWord($0) }.count
            let rest = Self.removingASCIILetters(text)
            let restLetters = rest.filter(\.isLetter)
            if englishWords > restLetters.count || restLetters.isEmpty {
                return .english
            }
            if let other = detectWithProbabilities(String(restLetters), checkMixedScripts: false).language,
               other != .english {
                return other
            }
        }
        // 数字为主、或很短的文本
        let digits = text.filter(\.isNumber).count
        if Double(digits) / Double(text.count) > 0.7 { return .english }
        if confidence < 0.5, text.count <= 10, TextTraits.isLatin(text), (probabilities[.english] ?? 0) > 0.1 {
            return .english
        }
        if text.count <= 3 {
            if preferredLanguages.contains(detected), confidence > 0.3 { return detected }
            if TextTraits.isLatin(text) { return .english }
        }
        return detected
    }

    /// 一个汉字转成简体后不变，就算简体字；简体字占九成以上为简体中文
    static func chineseVariant(of text: String) -> TranslateLanguage {
        let hanCharacters = text.filter { TextTraits.isHan($0) }
        guard !hanCharacters.isEmpty else { return .simplifiedChinese }
        let traditional = hanCharacters.filter { character in
            let original = String(character)
            return original.applyingTransform(StringTransform("Hant-Hans"), reverse: false) != original
        }.count
        let simplifiedRatio = Double(hanCharacters.count - traditional) / Double(hanCharacters.count)
        return simplifiedRatio >= 0.9 ? .simplifiedChinese : .traditionalChinese
    }

    /// 文本里出现了几种文字（拉丁字母、汉字、其他字母）
    private static func scriptCount(of text: String) -> Int {
        var latin = false, han = false, other = false
        for character in text {
            if TextTraits.isHan(character) { han = true }
            else if TextTraits.isLatinLetter(character) { latin = true }
            else if character.isLetter { other = true }
        }
        return [latin, han, other].filter { $0 }.count
    }

    private static func removingASCIILetters(_ text: String) -> String {
        String(text.filter { !($0.isASCII && $0.isLetter) })
    }
}
