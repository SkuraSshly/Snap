import Foundation

/// 两行之间的连接方式
enum LineJoin: Sendable, Equatable {
    /// 换行（同一段落里的另起一行，如诗句、列表项）
    case newline
    /// 新段落（空一行）
    case paragraph
    /// 加空格连接（英文等）
    case space
    /// 直接连接（中文等）
    case direct
    /// 去掉行尾连字符后直接连接（re-\nconstruction → reconstruction）
    case removeHyphen

    var startsNewParagraph: Bool { self == .newline || self == .paragraph }

    func join(_ first: String, _ second: String) -> String {
        switch self {
        case .newline: first + "\n" + second
        case .paragraph: first + "\n\n" + second
        case .space: first + " " + second
        case .direct: first + second
        case .removeHyphen: (first.hasSuffix("-") ? String(first.dropLast()) : first) + second
        }
    }

    /// 按语言决定加不加空格：看上一行最后一个词和下一行第一个词合起来是什么语言
    static func byLanguage(_ previous: String, _ next: String, detector: LanguageDetector) -> LineJoin {
        let joined = TextTraits.lastWord(previous) + TextTraits.firstWord(next)
        let language = detector.detect(joined)
        return (language?.needsWordSpacing ?? true) ? .space : .direct
    }
}

/// 把一栏里逐行识别出的文字合并成段落：逐对判断相邻两行该换行、分段还是接在一起。
///
/// 判断依据按可靠程度从高到低排列，先命中的生效：
/// 同一行 → 连字符 → 字号突变 → 大缩进 → 信件格式 → 行距 → 诗歌 → 列表 → 中文对仗 → 左边缘不齐 → 左边缘对齐 → 默认接续。
struct LineJoiner {
    let block: TextBlock
    let detector: LanguageDetector

    /// 合并整栏文字
    func compose() -> String {
        let lines = block.lines
        guard var text = lines.first?.text else { return "" }
        guard lines.count > 1 else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }

        // 当前段落的行，以及段落里最靠右的行（判断「是否写满」时的参考）
        var paragraph = [lines[0]]
        var paragraphRightmost = lines[0]
        for index in 1..<lines.count {
            let previous = lines[index - 1], current = lines[index]
            let decision = decide(previous: previous, current: current, paragraph: paragraph, paragraphRightmost: paragraphRightmost)
            text = decision.join(text, current.text)
            if decision.startsNewParagraph {
                paragraph = [current]
                paragraphRightmost = current
            } else {
                paragraph.append(current)
                if current.box.maxX > paragraphRightmost.box.maxX { paragraphRightmost = current }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 判断

    func decide(previous: OCRLine, current: OCRLine, paragraph: [OCRLine], paragraphRightmost: OCRLine) -> LineJoin {
        let b = block
        let first = paragraph.first ?? previous
        let firstIndented = b.isIndented(first)
        let previousIndented = previous == first ? firstIndented : b.isIndented(previous)
        // 「是否写满」：段落首行有缩进时和段落里最靠右的行比，否则和整栏最靠右的行比
        let reference = firstIndented ? paragraphRightmost : (b.rightmost ?? previous)
        let previousIsLong = b.isLongLine(previous, next: current, reference: reference)
        let previousIsAbsolutelyLong = b.isLongLine(previous, next: current)
        let previousEndsSentence = TextTraits.endsSentence(previous.text)
        let currentStartsLowercase = TextTraits.startsLowercase(current.text)
        let currentIsList = TextTraits.startsWithListMarker(current.text)
        let previousIsList = TextTraits.startsWithListMarker(previous.text)
        let firstIsList = TextTraits.startsWithListMarker(first.text)
        let alignedWithPrevious = b.isAligned(current, previous)
        let alignedWithFirst = b.isAligned(current, first)
        let indentedFromPrevious = b.isIndented(current, from: previous)
        let bigSpacing = b.hasBigSpacing(previous, current)
        let veryBigSpacing = b.hasBigSpacing(previous, current, strictness: .strict)
        let somewhatBigSpacing = b.hasBigSpacing(previous, current, strictness: .factor(0.65))
        let mayBeParagraph = somewhatBigSpacing || b.hasDifferentFontSize(previous, current)
        let byLanguage = { LineJoin.byLanguage(previous.text, current.text, detector: detector) }

        // 1. 左右并排在同一行
        if !b.isNewLine(previous, current) { return .space }

        // 2. 行尾连字符
        if let hyphen = hyphenJoin(previous: previous, current: current, block: b) { return hyphen }

        // 3. 字号明显变化（标题与正文）
        if b.hasDifferentFontSize(previous, current, strictness: .factor(2.0)) { return .paragraph }

        // 4. 明显缩进，且上一行没写满
        if b.isIndented(current, from: previous, strictness: .strict), !previousIsLong { return .paragraph }

        // 5. 信件格式：右对齐的日期之后是左对齐的称呼
        if previousIsLong, b.widestLineWidth > 0,
           Double(previous.box.minX - current.box.minX) / b.widestLineWidth > 0.45 {
            return .paragraph
        }

        // 6. 行距
        if veryBigSpacing {
            if !previousIsLong { return .paragraph }
            if previousEndsSentence, !currentStartsLowercase { return .paragraph }
        }
        if bigSpacing {
            if previousIsLong, currentStartsLowercase, !currentIsList { return byLanguage() }   // 跨页接续
            if currentIsList, firstIsList { return .newline }
            return .paragraph
        }

        // 7. 诗歌：逐行断开，左边缘差很多或行距大时分段
        if b.isPoetry {
            let farApart = !b.isAligned(current, previous, strictness: .strict) || bigSpacing
            return farApart ? .paragraph : .newline
        }

        // 8. 列表
        if currentIsList {
            if firstIsList {
                if veryBigSpacing { return .paragraph }
                if alignedWithFirst {
                    if b.isIndented(current, from: previous) { return .paragraph }
                    if !bigSpacing { return .newline }
                } else {
                    return .paragraph
                }
            } else {
                if indentedFromPrevious, !alignedWithFirst { return .paragraph }
                if bigSpacing { return .paragraph }
            }
            if !alignedWithPrevious, firstIndented { return .paragraph }
            if previousIndented, !alignedWithFirst { return .paragraph }
            return .newline
        }

        // 9. 中文对仗的诗句
        if b.isMatchingChineseCouplet(previous, current) { return .newline }

        // 10. 左边缘不齐
        if !alignedWithPrevious {
            if !previousIsLong { return .paragraph }
            if !previousIsAbsolutelyLong {
                if previousIndented || previousIsList || b.isIndented(current, from: previous, strictness: .strict) {
                    return .paragraph
                }
                return .newline
            }
            // 居中的多行标题：中心对齐、上一行没结束、字号行距都没变化
            let centeredTitle = b.isAligned(current, previous, edge: .center)
                && !previousEndsSentence
                && !b.hasDifferentFontSize(previous, current, strictness: .loose)
                && !somewhatBigSpacing
                && !currentIsList
                && indentedFromPrevious
            if centeredTitle { return byLanguage() }
            if indentedFromPrevious, !previousIsList { return .paragraph }
            if b.isIndented(current), previousIndented, !indentedFromPrevious { return .paragraph }
            return byLanguage()
        }

        // 11. 左边缘对齐
        if previousIsList, mayBeParagraph, !currentStartsLowercase { return .paragraph }
        if !previousIsLong { return mayBeParagraph ? .paragraph : .newline }
        if previous == first, !previousIndented, !previousIsAbsolutelyLong {
            return mayBeParagraph ? .paragraph : .newline
        }
        if b.isShortLine(current), b.isShortLine(previous) { return .newline }

        // 12. 行距偏大且字号略有不同
        if somewhatBigSpacing, b.hasDifferentFontSize(previous, current, strictness: .loose) { return .paragraph }

        // 13. 默认：同一段落里自然折行
        return byLanguage()
    }

    // MARK: - 连字符

    /// 行尾 / 行首的连字符怎么处理（只对用空格分词的语言、且上一行写满时）
    func hyphenJoin(previous: OCRLine, current: OCRLine, block: TextBlock) -> LineJoin? {
        let upper = previous.text, lower = current.text
        guard !upper.isEmpty, !lower.isEmpty else { return nil }
        let endsWithDash = upper.last.map { "-–—".contains($0) } ?? false
        guard endsWithDash || lower.first == "-" else { return nil }
        guard block.needsWordSpacing, block.isLongLine(previous, next: current) else { return nil }

        // 单词被折行拆开：拼起来是正确的单词就去掉连字符
        if endsWithDash, lower.first?.isLetter == true {
            let head = TextTraits.lastWord(String(upper.dropLast()))
            if !head.isEmpty, TextTraits.isSpelledCorrectly(head + TextTraits.firstWord(lower)) {
                return .removeHyphen
            }
        }
        // 独立的破折号：「true or -」「- false」
        if upper.hasSuffix(" -") || lower.hasPrefix("- ") { return .space }
        // 复合词（state-of-the-art）：保留连字符
        return .direct
    }
}
