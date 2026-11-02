import AppKit
import NaturalLanguage

/// 排版判断用到的文字特征（标点、列表标记、大小写、分词、拼写）
enum TextTraits {
    /// 句末标点：以这些结尾通常表示一句话说完了
    static let sentenceEnders: Set<String> = [".", "。", "?", "？", "!", "！", ";", ":", "：", "..", "...", "…", "……"]

    static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return sentenceEnders.contains(String(last))
    }

    /// 单个字符是不是句末标点（用于检查句中标点）
    static func isSentenceEnder(_ character: Character) -> Bool {
        "。！？.!?;:…".contains(character)
    }

    static func isPunctuation(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    static func startsLowercase(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first.isLetter && first.isLowercase
    }

    static func startsUppercase(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first.isLetter && first.isUppercase
    }

    static func firstWord(_ text: String) -> String {
        text.components(separatedBy: " ").first ?? ""
    }

    static func lastWord(_ text: String) -> String {
        text.components(separatedBy: " ").last ?? ""
    }

    /// 汉字（CJK 表意文字）
    static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.properties.isIdeographic }
    }

    static func isLatinLetter(_ character: Character) -> Bool {
        guard character.isLetter, let scalar = character.unicodeScalars.first else { return false }
        return scalar.value < 0x250   // 基本拉丁 + 拉丁扩展
    }

    /// 整段都是拉丁文字（字母、空白、标点、数字）
    static func isLatin(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { !$0.isLetter || isLatinLetter($0) }
    }

    /// 只由 ASCII 字母组成的词（去掉非字母后判断）
    static func isASCIIWord(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return !letters.isEmpty && letters.allSatisfy(\.isASCII)
    }

    /// 切词：汉字一个字算一个词，其他字符连在一起算一个词；空白和大部分标点是分隔符
    static func wordComponents(_ text: String) -> [String] {
        var separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        separators.remove(charactersIn: "@#/•\"-.")
        var words: [String] = []
        var current = ""
        for character in text {
            if character.unicodeScalars.allSatisfy({ separators.contains($0) }) {
                if !current.isEmpty { words.append(current); current = "" }
            } else if isHan(character) {
                if !current.isEmpty { words.append(current); current = "" }
                words.append(String(character))
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// 词数：用系统分词，跳过空白和标点
    static func wordCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if text.contains(where: isHan) { tokenizer.setLanguage(.simplifiedChinese) }
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = text[range]
            if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               token.rangeOfCharacter(from: .punctuationCharacters) == nil {
                count += 1
            }
            return true
        }
        return count
    }

    /// 省略号（... 或 …）算一个标点，其余按 Unicode 标点计
    static func punctuationCount(_ text: String, excluding excluded: String = "") -> Int {
        var set = CharacterSet.punctuationCharacters
        set.remove(charactersIn: excluded)
        var rest = text
        var count = 0
        for ellipsis in ["...", "…"] {
            let parts = rest.components(separatedBy: ellipsis)
            count += parts.count - 1
            rest = parts.joined()
        }
        count += rest.unicodeScalars.filter { set.contains($0) }.count
        return count
    }

    // MARK: - 列表

    /// 行首的列表标记：1.  a)  iv.  2）  •  -  *  [3]  等
    static func startsWithListMarker(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard let first = line.first else { return false }
        let characters = Array(line)

        // 数字 + . 或 ) 或 ）（数字后的点不能再接数字，排除 3.14）
        if first.isASCII, first.isNumber {
            var index = 0
            while index < characters.count, characters[index].isASCII, characters[index].isNumber { index += 1 }
            guard index < characters.count else { return false }
            let next = characters[index]
            if next == ")" || next == "）" { return true }
            if next == "." {
                return !(index + 1 < characters.count && characters[index + 1].isNumber)
            }
            return false
        }
        // a~g / A~G + . ) ）
        if characters.count >= 2, "abcdefgABCDEFG".contains(first), ".)）".contains(characters[1]) {
            return true
        }
        // 罗马数字 + .
        var index = 0
        while index < characters.count, "ivxIVX".contains(characters[index]) { index += 1 }
        if index > 0, index < characters.count, characters[index] == "." { return true }
        // 项目符号 + 空白
        if "•-*§¶►▪▫○●◦◾◽".contains(first), characters.count >= 2, characters[1] == " " || characters[1] == "\t" {
            return true
        }
        // [数字] + 空白
        if first == "[" {
            var index = 1
            while index < characters.count, characters[index].isNumber { index += 1 }
            if index > 1, index + 1 < characters.count, characters[index] == "]",
               characters[index + 1] == " " || characters[index + 1] == "\t" {
                return true
            }
        }
        return false
    }

    // MARK: - 中文对仗

    /// 两行的结构相似度：逐字比较，都不是标点、或是同一个标点就算一致
    static func structuralSimilarity(_ a: String, _ b: String) -> Double {
        let length = min(a.count, b.count)
        guard length > 0 else { return 0 }
        var matches = 0
        for (x, y) in zip(a.prefix(length), b.prefix(length)) {
            let px = x.isPunctuation, py = y.isPunctuation
            if (!px && !py) || (px && py && x == y) { matches += 1 }
        }
        return Double(matches) / Double(max(a.count, b.count))
    }

    // MARK: - 拼写

    /// 系统拼写检查认为拼写正确（用于判断行尾连字符拆开的单词）
    static func isSpelledCorrectly(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        // NSSpellChecker 只能在主线程使用；识别在后台进行，这里同步切到主线程问一下（主线程此时不会等待识别，不会死锁）
        let check = {
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: nil, wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
    }

    // MARK: - 字号估计

    /// 用 13pt 系统字体测量文字宽度，按比例估计这行文字在图片里的字号
    static func estimatedFontSize(_ text: String, width: Double) -> Double {
        let base = NSFont.systemFontSize
        guard !text.isEmpty else { return base }
        let measured = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: base)]).width
        guard measured > 0 else { return base }
        return width * base / measured
    }
}
