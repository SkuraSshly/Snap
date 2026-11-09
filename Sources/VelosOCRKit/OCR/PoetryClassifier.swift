import Foundation

/// 判断一栏文字是不是诗歌 / 歌词：是的话每行单独成行，不合并成段落。
///
/// 思路：诗歌的行短、标点少或标点规律（每行都以标点结尾，或几乎都没有标点）；
/// 一旦看到典型的散文特征（句中句号后接大写字母、长行被自然折行），就判定不是诗歌。
enum PoetryClassifier {
    /// 诗歌里常见、不算作标点的符号
    private static let poetrySymbols = "《》一•·-#—"
    private static let maxWordsPerLine = 7.0
    private static let maxCharactersPerLine = 12.0

    static func isPoetry(_ block: TextBlock) -> Bool {
        let lines = block.lines
        guard lines.count > 1, block.punctuationPerLine <= 2.5 else { return false }

        var sentenceEndLines = 0, punctuationEndLines = 0, unpunctuatedLines = 0
        var words = 0, punctuation = 0, characters = 0
        for (index, line) in lines.enumerated() {
            let text = line.text
            if hasSentenceBreakInMiddle(text) { return false }

            let count = TextTraits.punctuationCount(text, excluding: poetrySymbols)
            if count == 0 { unpunctuatedLines += 1 } else { punctuation += count }
            characters += text.count - count
            words += TextTraits.wordCount(text)
            if endsWithPoetryPunctuation(text) { punctuationEndLines += 1 }
            let endsSentence = TextTraits.endsSentence(text)
            if endsSentence { sentenceEndLines += 1 }

            if index > 0 {
                let previous = lines[index - 1]
                if block.isLongLine(previous, next: line),
                   looksLikeWrappedProse(previous: previous.text, current: text, currentEndsSentence: endsSentence) {
                    return false
                }
            }
        }

        let count = Double(lines.count)
        let charactersPerLine = Double(characters) / count
        let wordsPerLine = Double(words) / count
        let punctuationPerLine = Double(punctuation) / count
        let sentenceEndRatio = Double(sentenceEndLines) / count
        let punctuationEndRatio = Double(punctuationEndLines) / count
        let unpunctuatedRatio = Double(unpunctuatedLines) / count

        if charactersPerLine < 2 || punctuationPerLine > 2.0 { return false }
        guard isPoemLength(words: wordsPerLine, characters: charactersPerLine, scale: 2.0) else { return false }

        if isPoemLength(words: wordsPerLine, characters: charactersPerLine, scale: 1.0), punctuationPerLine <= 1.5 {
            return true
        }
        if isPoemLength(words: wordsPerLine, characters: charactersPerLine, scale: 1.5) {
            if sentenceEndRatio >= 0.8 || punctuationEndRatio >= 0.8 || unpunctuatedRatio >= 0.9 || punctuationPerLine <= 0.1 {
                return true
            }
            if sentenceEndRatio == 0, punctuationEndRatio < 0.2, unpunctuatedRatio > 0.8, punctuationPerLine < 0.2 {
                return true
            }
        }
        return false
    }

    /// 每行的词数或字数在诗歌范围内
    private static func isPoemLength(words: Double, characters: Double, scale: Double) -> Bool {
        words <= maxWordsPerLine * scale || characters <= maxCharactersPerLine * scale
    }

    private static func endsWithPoetryPunctuation(_ text: String) -> Bool {
        guard let scalar = text.last?.unicodeScalars.first else { return false }
        var set = CharacterSet.punctuationCharacters
        set.remove(charactersIn: poetrySymbols)
        return set.contains(scalar)
    }

    /// 句中有句末标点、后面又以大写字母开始新句子 → 散文
    private static func hasSentenceBreakInMiddle(_ text: String) -> Bool {
        let characters = Array(text)
        for (index, character) in characters.enumerated() where TextTraits.isSentenceEnder(character) {
            if let letter = characters[(index + 1)...].first(where: \.isLetter), letter.isUppercase {
                return true
            }
        }
        return false
    }

    /// 上一行写满了、在这一行才结束句子 → 是被自动折行的散文
    private static func looksLikeWrappedProse(previous: String, current: String, currentEndsSentence: Bool) -> Bool {
        let previousEndsWithPunctuation = previous.last?.isPunctuation ?? false
        if currentEndsSentence, !previousEndsWithPunctuation {
            if TextTraits.startsLowercase(previous) || TextTraits.startsUppercase(previous) { return true }
            if !isPoemLength(words: Double(TextTraits.wordCount(previous)), characters: Double(previous.count), scale: 1.5) {
                return true
            }
        }
        // 列表项内容折行到下一行（下一行小写开头）
        if TextTraits.startsWithListMarker(previous), !previousEndsWithPunctuation, TextTraits.startsLowercase(current) {
            return true
        }
        return false
    }
}
