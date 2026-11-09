import CoreServices
import Foundation

/// 一条词典结果（来自 macOS 自带词典，离线）
struct DictionaryEntry: Equatable, Sendable {
    struct Phonetic: Equatable, Sendable {
        /// 「英」「美」或拼音时为空
        let label: String
        let text: String
        /// 朗读用的声音语言（en-GB / en-US / zh-CN）
        let voiceLanguage: String
    }

    struct Sense: Equatable, Sendable {
        let gloss: String
        let example: String?
    }

    struct PartOfSpeech: Equatable, Sendable {
        /// 「名词」「及物动词」等；词典没写时为空
        let name: String
        let senses: [Sense]
    }

    let headword: String
    let phonetics: [Phonetic]
    let parts: [PartOfSpeech]
}

/// 查 macOS 自带词典（「词典」App 里启用的那些，按它的顺序）。
///
/// 用公开接口 DCSCopyTextDefinition：返回纯文本，这里按牛津英汉词典 / 现代汉语词典的格式拆成音标、词性、释义。
/// 它只返回「词典 App 里排在前面、并且查得到这个词」的那一本的结果，所以要核对词条是不是查的这个词
/// （例如 run 会先查到汉语词典里的「瞤 rún」，这种结果不显示）。
enum DictionaryLookup {
    /// 只有单个单词或短语才查词典：英文等最多 4 个词，中文最多 6 个字，不含句子标点
    static func shouldLookUp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40, !trimmed.contains("\n") else { return false }
        if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ".,;:!?，。；：！？、\"“”()（）")) != nil { return false }
        let hasHan = trimmed.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if hasHan { return trimmed.count <= 6 && !trimmed.contains(" ") }
        let words = trimmed.split(whereSeparator: { $0 == " " })
        return words.count <= 4 && trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// 查词；没有结果、或查到的不是这个词时返回 nil
    static func lookUp(_ text: String) -> DictionaryEntry? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldLookUp(query) else { return nil }
        let range = CFRange(location: 0, length: (query as NSString).length)
        guard let raw = DCSCopyTextDefinition(nil, query as CFString, range)?.takeRetainedValue() as String? else { return nil }
        return parse(raw, query: query)
    }

    // MARK: - 解析

    static func parse(_ raw: String, query: String) -> DictionaryEntry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = text.components(separatedBy: " | ")
        if fields.count >= 3 {
            return parseBilingual(fields, query: query)
        }
        return parseChinese(text, query: query)
    }

    /// 牛津英汉：「light 1 | BrE lʌɪt, AmE laɪt | A. noun ① (brightness) 光亮 guāngliàng▸ 例句 ② … B. verb …」
    private static func parseBilingual(_ fields: [String], query: String) -> DictionaryEntry? {
        let headword = fields[0].replacingOccurrences(of: #"\s+\d+$"#, with: "", options: .regularExpression)
        guard matches(headword: headword, query: query) else { return nil }

        var phonetics: [DictionaryEntry.Phonetic] = []
        for part in fields[1].components(separatedBy: ", ") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.hasPrefix("BrE ") {
                phonetics.append(.init(label: "英", text: String(piece.dropFirst(4)), voiceLanguage: "en-GB"))
            } else if piece.hasPrefix("AmE ") {
                phonetics.append(.init(label: "美", text: String(piece.dropFirst(4)), voiceLanguage: "en-US"))
            }
        }

        var body = fields[2...].joined(separator: " | ")
        // 词条末尾的短语动词列表（PHRASAL VERB …）不显示
        if let phrasal = body.range(of: "PHRASAL VERB") { body = String(body[..<phrasal.lowerBound]) }
        // 词性块：「A. noun …」「B. transitive verb …」（编号前面不一定有空格）；没有字母编号时整段是一个词性
        let names = englishPartsOfSpeech.map(\.0).joined(separator: "|")
        let blocks = split(body, by: "[A-H]\\.\\s(?=(?:\(names))\\b)")
        var parts: [DictionaryEntry.PartOfSpeech] = []
        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let (name, rest) = partOfSpeechName(in: trimmed)
            let senses = parseSenses(rest, skippingHeader: true)
            if !senses.isEmpty { parts.append(.init(name: name, senses: Array(senses.prefix(4)))) }
            if parts.count == 3 { break }
        }
        guard !parts.isEmpty else { return nil }
        return DictionaryEntry(headword: headword, phonetics: phonetics, parts: parts)
    }

    /// 现代汉语：「电脑 diànnǎo 名 电子计算机的通称。」「苹果 píngguǒ 名 ① … ② …」
    private static func parseChinese(_ text: String, query: String) -> DictionaryEntry? {
        var tokens = text.split(separator: " ", maxSplits: 3).map(String.init)
        guard tokens.count >= 2, tokens[0] == query else { return nil }
        let headword = tokens.removeFirst()
        var phonetics: [DictionaryEntry.Phonetic] = []
        if let first = tokens.first, isPinyin(first) {
            phonetics.append(.init(label: "", text: tokens.removeFirst(), voiceLanguage: "zh-CN"))
        }
        var name = ""
        if let first = tokens.first, let mapped = chinesePartsOfSpeech[first] {
            name = mapped
            tokens.removeFirst()
        }
        let senses = parseSenses(tokens.joined(separator: " "))
        guard !senses.isEmpty else { return nil }
        return DictionaryEntry(headword: headword, phonetics: phonetics, parts: [.init(name: name, senses: Array(senses.prefix(4)))])
    }

    /// 释义：按 ①②③ 拆开；每条取「▸」前面的解释（去掉拼音、语法标签），和第一个例句。
    /// skippingHeader：有编号时，第一个编号前面的是词形变化说明（例如 past tense lit），不算释义
    private static func parseSenses(_ text: String, skippingHeader: Bool = false) -> [DictionaryEntry.Sense] {
        var pieces = split(text, by: "[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳]")
        if skippingHeader, pieces.count > 1 { pieces.removeFirst() }
        return pieces.compactMap { piece in
            let parts = piece.components(separatedBy: "▸")
            let gloss = cleanGloss(parts[0])
            guard !gloss.isEmpty else { return nil }
            let example = parts.count > 1 ? cleanExample(parts[1]) : nil
            return DictionaryEntry.Sense(gloss: gloss, example: example?.isEmpty == false ? example : nil)
        }
    }

    /// 去掉拼音（汉字后面跟着的小写拉丁字母词）、交叉引用（→ …）、语法标签
    private static func cleanGloss(_ raw: String) -> String {
        var text = raw
        if let arrow = text.range(of: "→") { text = String(text[..<arrow.lowerBound]) }
        var kept: [String] = []
        var afterHan = false
        for token in text.split(separator: " ").map(String.init) {
            if afterHan, isPinyin(token) {
                // 汉字后面的拼音：去掉，但保留它后面的分号（分隔两个释义）
                if token.hasSuffix(";"), let last = kept.popLast() { kept.append(last + "；") }
                continue
            }
            if grammarLabels.contains(token) { continue }
            kept.append(token)
            afterHan = token.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        }
        return kept.joined(separator: " ")
            .replacingOccurrences(of: " ;", with: ";")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ";")))
    }

    /// 例句：英文 + 中文，同样去掉中文后面的拼音
    private static func cleanExample(_ raw: String) -> String {
        cleanGloss(raw)
    }

    /// 词条和查的词是否一致：忽略大小写，连字符和空格视为相同；单个词允许是屈折形式（apples → apple）
    private static func matches(headword: String, query: String) -> Bool {
        func normalized(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        }
        let h = normalized(headword), q = normalized(query)
        if h == q { return true }
        guard !q.contains(" "), !h.contains(" "), h.count >= 3 else { return false }
        return q.hasPrefix(String(h.prefix(max(3, h.count - 1)))) && abs(q.count - h.count) <= 4
    }

    private static func partOfSpeechName(in block: String) -> (String, String) {
        // 先匹配长的（transitive verb 在 verb 前面）
        for (english, chinese) in englishPartsOfSpeech where block.hasPrefix(english + " ") || block == english {
            return (chinese, String(block.dropFirst(english.count)))
        }
        return ("", block)
    }

    private static func split(_ text: String, by pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let ns = text as NSString
        var result: [String] = []
        var start = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
        }
        result.append(ns.substring(from: start))
        return result
    }

    private static func isPinyin(_ token: String) -> Bool {
        let letters = token.trimmingCharacters(in: CharacterSet(charactersIn: ";,'’…"))
        guard !letters.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜüńňǹḿ'’")
        return letters.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static let englishPartsOfSpeech: [(String, String)] = [
        ("transitive verb", "及物动词"), ("intransitive verb", "不及物动词"), ("phrasal verb", "短语动词"),
        ("modal verb", "情态动词"), ("auxiliary verb", "助动词"), ("verb", "动词"), ("noun", "名词"),
        ("adjective", "形容词"), ("adverb", "副词"), ("pronoun", "代词"), ("preposition", "介词"),
        ("conjunction", "连词"), ("exclamation", "感叹词"), ("interjection", "感叹词"), ("determiner", "限定词"),
        ("abbreviation", "缩略词"), ("prefix", "前缀"), ("suffix", "后缀"), ("numeral", "数词"),
    ]

    private static let chinesePartsOfSpeech: [String: String] = [
        "名": "名词", "动": "动词", "形": "形容词", "副": "副词", "代": "代词", "数": "数词", "量": "量词",
        "介": "介词", "连": "连词", "助": "助词", "叹": "叹词", "拟声": "拟声词",
    ]

    /// 不显示的语法标签（可数 / 不可数、只作定语 / 表语等）
    private static let grammarLabels: Set<String> = [
        "countable", "uncountable", "attributive", "predicative",
    ]
}
