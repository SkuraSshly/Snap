import Foundation

/// 识别出的一行文字。box 是归一化坐标（0~1），原点在左下角，y 越大越靠上（Vision 的约定）
public struct OCRLine: Sendable, Equatable {
    public let id: Int
    public let text: String
    public let box: CGRect
    public let confidence: Float
}

/// 排版判断的「把握程度」：数值越大，判断越保守
enum Strictness: Sendable {
    case strict, normal, loose
    case factor(Double)

    var value: Double {
        switch self {
        case .strict: 1.5
        case .normal: 1.0
        case .loose: 0.7
        case .factor(let value): value
        }
    }
}

/// 比较两行 x 坐标时用哪条边
enum HorizontalEdge: Sendable { case left, right, center }

/// 一个文字块（一栏）：保存这一栏的行、整体统计，以及基于统计的几何判断。
/// 所有「差了几个字」的换算都用图片的点尺寸（像素 ÷ 屏幕倍数）。
struct TextBlock: Sendable {
    let lines: [OCRLine]
    let language: TranslateLanguage?
    /// 图片尺寸（点）
    let imageSize: CGSize

    // 统计
    private(set) var minLineHeight = 1.0
    private(set) var averageLineHeight = 0.0
    private(set) var averageLineSpacing = 0.0
    private(set) var leftmost: OCRLine?
    private(set) var rightmost: OCRLine?
    private(set) var widest: OCRLine?
    private(set) var characterCount = 0
    private(set) var punctuationCount = 0
    private(set) var confidence: Float = 0
    /// 这一栏是不是诗歌（逐行断开）
    var isPoetry = false

    init(lines: [OCRLine], language: TranslateLanguage?, imageSize: CGSize) {
        self.lines = lines
        self.language = language
        self.imageSize = imageSize
        guard !lines.isEmpty else { return }

        var totalHeight = 0.0
        var mostCharacters: OCRLine?
        for line in lines {
            let height = Double(line.box.height)
            totalHeight += height
            minLineHeight = min(minLineHeight, height)
            if line.box.minX < leftmost?.box.minX ?? .greatestFiniteMagnitude { leftmost = line }
            if line.box.width > widest?.box.width ?? 0 { widest = line }
            if line.box.maxX > rightmost?.box.maxX ?? 0 { rightmost = line }
            if line.text.count > mostCharacters?.text.count ?? -1 { mostCharacters = line }
            let punctuation = TextTraits.punctuationCount(line.text)
            punctuationCount += punctuation
            characterCount += line.text.count - punctuation
        }
        averageLineHeight = totalHeight / Double(lines.count)

        // 行距：只算上下相邻、间隙为正的；过大的间隙按「平均行高 × 1.2」封顶
        var spacingTotal = 0.0, spacingCount = 0
        for index in 1..<lines.count {
            let gap = Self.verticalGap(upper: lines[index - 1], lower: lines[index])
            if gap > 0 {
                spacingTotal += min(gap, averageLineHeight * 1.2)
                spacingCount += 1
            }
        }
        if spacingCount > 0 { averageLineSpacing = spacingTotal / Double(spacingCount) }
        confidence = lines.map(\.confidence).reduce(0, +) / Float(lines.count)
    }

    var isChinese: Bool { language?.isChinese ?? false }
    var needsWordSpacing: Bool { language?.needsWordSpacing ?? true }
    var charactersPerLine: Double { Double(characterCount) / Double(max(lines.count, 1)) }
    var punctuationPerLine: Double { Double(punctuationCount) / Double(max(lines.count, 1)) }
    var widestLineWidth: Double { Double(widest?.box.width ?? 0) }

    /// 超过这个间隙就算「行距大」
    var bigSpacingThreshold: Double {
        max(min(averageLineHeight, minLineHeight * 1.1), averageLineSpacing * 1.2)
    }

    // MARK: - 几何判断

    /// 上一行底边到下一行顶边的距离（正数表示有空隙）
    static func verticalGap(upper: OCRLine, lower: OCRLine) -> Double {
        Double(upper.box.minY - lower.box.maxY)
    }

    /// 是否换到了新的一行（不是左右并排在同一行）
    func isNewLine(_ upper: OCRLine, _ lower: OCRLine) -> Bool {
        let gap = Self.verticalGap(upper: upper, lower: lower)
        let pairHeight = Double(upper.box.height + lower.box.height) / 2
        let threshold = max(pairHeight, averageLineHeight) * 0.4
        return gap > 0 || abs(gap) <= threshold
    }

    /// 一行的平均字宽（点）；行尾是标点时少算半个字
    func characterWidth(of line: OCRLine) -> Double {
        let width = Double(line.box.width * imageSize.width)
        var count = Double(line.text.count)
        if let last = line.text.last, last.isPunctuation { count -= 0.5 }
        return width / max(1, count)
    }

    /// 两行的平均字宽；字号明显不同且不允许时只用第一行
    func characterWidth(_ line: OCRLine, with other: OCRLine, allowDifferentSize: Bool = false) -> Double {
        let own = characterWidth(of: line)
        if !allowDifferentSize, fontSizeDifference(line, other) > 1.5 { return own }
        return (own + characterWidth(of: other)) / 2
    }

    /// 两行在 x 方向相差几个字（正数表示 line 更靠右）
    func horizontalOffsetInCharacters(_ line: OCRLine, from reference: OCRLine, edge: HorizontalEdge = .left) -> Double {
        let dx: CGFloat = switch edge {
        case .left: line.box.minX - reference.box.minX
        case .right: line.box.maxX - reference.box.maxX
        case .center: line.box.midX - reference.box.midX
        }
        return Double(dx * imageSize.width) / characterWidth(line, with: reference, allowDifferentSize: true)
    }

    /// 相对参考行有没有缩进（默认和这一栏最左的行比）
    func isIndented(_ line: OCRLine, from reference: OCRLine? = nil, strictness: Strictness = .normal) -> Bool {
        guard let reference = reference ?? leftmost else { return false }
        return horizontalOffsetInCharacters(line, from: reference) > 1.8 * strictness.value
    }

    /// 两行某条边是否对齐（差不超过 1.8 个字）
    func isAligned(_ line: OCRLine, _ reference: OCRLine, edge: HorizontalEdge = .left, strictness: Strictness = .normal) -> Bool {
        abs(horizontalOffsetInCharacters(line, from: reference, edge: edge)) <= 1.8 * strictness.value
    }

    /// 是否长行：行尾到参考行右端剩下的空间放不下下一行的开头（说明这行是被自动折行的）
    func isLongLine(_ line: OCRLine, next: OCRLine, reference: OCRLine? = nil, strictness: Strictness = .normal) -> Bool {
        guard let reference = reference ?? rightmost else { return false }
        let gap = Double((reference.box.maxX - line.box.maxX) * imageSize.width)
        let remaining = gap / characterWidth(line, with: reference)
        return remaining < minimumRemaining(line: line, next: next) / strictness.value
    }

    /// 长行判断的阈值：剩余空间少于多少个字就算长行
    private func minimumRemaining(line: OCRLine, next: OCRLine) -> Double {
        if needsWordSpacing {
            let nextText = next.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nextText.isEmpty else { return 12 }
            let firstWord = TextTraits.wordComponents(nextText).first ?? nextText
            return Double(firstWord.count) + 3
        }
        var minimum = 1.6
        if isChinese {
            // 中文行尾没有句末标点，多给一点余量，免得把段落误拼
            if !TextTraits.endsSentence(line.text) { minimum += 0.7 }
            // 下一行第二个字是标点（如「性，对于…」），说明上一行其实已经写满
            let nextCharacters = Array(next.text)
            let firstIsPunctuation = nextCharacters.first.map(TextTraits.isPunctuation) ?? false
            if !firstIsPunctuation, nextCharacters.count > 1, nextCharacters[1].isPunctuation { minimum += 0.8 }
        }
        return minimum
    }

    /// 是否短行：不到最宽那行的一半
    func isShortLine(_ line: OCRLine) -> Bool {
        guard let widest else { return false }
        return line.box.width < widest.box.width * 0.5
    }

    /// 行距是否偏大
    func hasBigSpacing(_ upper: OCRLine, _ lower: OCRLine, strictness: Strictness = .normal) -> Bool {
        Self.verticalGap(upper: upper, lower: lower) / bigSpacingThreshold > strictness.value
    }

    /// 两行估计字号之差
    func fontSizeDifference(_ a: OCRLine, _ b: OCRLine) -> Double {
        abs(fontSize(of: a) - fontSize(of: b))
    }

    private func fontSize(of line: OCRLine) -> Double {
        TextTraits.estimatedFontSize(line.text, width: Double(line.box.width * imageSize.width))
    }

    /// 字号是否不同（太短的文字估不准，不判断）
    func hasDifferentFontSize(_ a: OCRLine, _ b: OCRLine, strictness: Strictness = .normal) -> Bool {
        let lettersA = a.text.filter(\.isLetter).count, lettersB = b.text.filter(\.isLetter).count
        guard lettersA >= 3, lettersB >= 3 else { return false }
        let base = isChinese ? 4.0 : 5.5
        return fontSizeDifference(a, b) >= base * strictness.value
    }

    /// 中文对仗行：结构相同、两端对齐、都以句末标点结尾（诗词常见）
    func isMatchingChineseCouplet(_ upper: OCRLine, _ lower: OCRLine) -> Bool {
        guard isChinese else { return false }
        let similarity = TextTraits.structuralSimilarity(upper.text, lower.text)
        let sameStructure = similarity >= 0.9 || (similarity >= 0.7 && upper.text.count == lower.text.count)
        let aligned = isAligned(lower, upper, edge: .left) && isAligned(lower, upper, edge: .right)
        return sameStructure && aligned && TextTraits.endsSentence(upper.text) && TextTraits.endsSentence(lower.text)
    }
}
