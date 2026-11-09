import Foundation
import NaturalLanguage

/// 截屏翻译支持的语言（文字识别、语言检测、翻译共用）
public enum TranslateLanguage: String, CaseIterable, Codable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case spanish = "es"
    case portuguese = "pt"
    case italian = "it"
    case german = "de"
    case russian = "ru"
    case ukrainian = "uk"
    case thai = "th"
    case vietnamese = "vi"
    case arabic = "ar"
    case turkish = "tr"
    case indonesian = "id"
    case czech = "cs"
    case danish = "da"
    case dutch = "nl"
    case norwegian = "nb"
    case malay = "ms"
    case polish = "pl"
    case romanian = "ro"
    case swedish = "sv"
    case finnish = "fi"
    case greek = "el"
    case hebrew = "he"
    case hindi = "hi"
    case hungarian = "hu"
    case persian = "fa"
    case catalan = "ca"

    /// 界面上显示的名字
    public var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁体中文"
        case .english: "英语"
        case .japanese: "日语"
        case .korean: "韩语"
        case .french: "法语"
        case .spanish: "西班牙语"
        case .portuguese: "葡萄牙语"
        case .italian: "意大利语"
        case .german: "德语"
        case .russian: "俄语"
        case .ukrainian: "乌克兰语"
        case .thai: "泰语"
        case .vietnamese: "越南语"
        case .arabic: "阿拉伯语"
        case .turkish: "土耳其语"
        case .indonesian: "印尼语"
        case .czech: "捷克语"
        case .danish: "丹麦语"
        case .dutch: "荷兰语"
        case .norwegian: "挪威语"
        case .malay: "马来语"
        case .polish: "波兰语"
        case .romanian: "罗马尼亚语"
        case .swedish: "瑞典语"
        case .finnish: "芬兰语"
        case .greek: "希腊语"
        case .hebrew: "希伯来语"
        case .hindi: "印地语"
        case .hungarian: "匈牙利语"
        case .persian: "波斯语"
        case .catalan: "加泰罗尼亚语"
        }
    }

    /// 系统框架（Translation、语音）使用的语言标识
    public var localeLanguage: Locale.Language { Locale.Language(identifier: rawValue) }

    public var nlLanguage: NLLanguage {
        switch self {
        case .simplifiedChinese: .simplifiedChinese
        case .traditionalChinese: .traditionalChinese
        case .norwegian: .norwegian
        default: NLLanguage(rawValue: rawValue)
        }
    }

    public init?(nlLanguage: NLLanguage) {
        if let match = Self.allCases.first(where: { $0.nlLanguage == nlLanguage }) {
            self = match
        } else {
            return nil
        }
    }

    /// 由系统语言标识（如 zh-Hans-CN、en-US、zh-TW）得到语言
    public init?(localeIdentifier: String) {
        let locale = Locale.Language(identifier: localeIdentifier)
        guard let code = locale.languageCode?.identifier else { return nil }
        if code == "zh" {
            let script = locale.script?.identifier
            let region = locale.region?.identifier
            let traditional = script == "Hant" || (script == nil && ["TW", "HK", "MO"].contains(region ?? ""))
            self = traditional ? .traditionalChinese : .simplifiedChinese
            return
        }
        if code == "no" || code == "nn" { self = .norwegian; return }
        guard let match = Self(rawValue: code) else { return nil }
        self = match
    }

    public var isChinese: Bool { self == .simplifiedChinese || self == .traditionalChinese }

    /// 词与词之间是否用空格分隔（中文、日文、韩文、泰文按惯例视为不用）
    public var needsWordSpacing: Bool {
        switch self {
        case .simplifiedChinese, .traditionalChinese, .japanese, .korean, .thai: false
        default: true
        }
    }

    // MARK: - 文字识别

    /// Vision 文字识别使用的语言代码；不支持识别的语言为 nil
    public func visionCode(modernAPI: Bool) -> String? {
        switch self {
        case .simplifiedChinese: "zh-Hans"
        case .traditionalChinese: "zh-Hant"
        case .english: "en-US"
        case .japanese: "ja-JP"
        case .korean: "ko-KR"
        case .french: "fr-FR"
        case .spanish: "es-ES"
        case .portuguese: "pt-BR"
        case .italian: "it-IT"
        case .german: "de-DE"
        case .russian: "ru-RU"
        case .ukrainian: "uk-UA"
        case .thai: "th-TH"
        case .vietnamese: "vi-VN"
        case .arabic: "ar-SA"
        case .turkish: modernAPI ? "tr-TR" : nil
        case .indonesian: modernAPI ? "id-ID" : nil
        case .czech: modernAPI ? "cs-CZ" : nil
        case .danish: modernAPI ? "da-DK" : nil
        case .dutch: modernAPI ? "nl-NL" : nil
        case .norwegian: modernAPI ? "no-NO" : nil
        case .malay: modernAPI ? "ms-MY" : nil
        case .polish: modernAPI ? "pl-PL" : nil
        case .romanian: modernAPI ? "ro-RO" : nil
        case .swedish: modernAPI ? "sv-SE" : nil
        default: nil
        }
    }

    /// 文字识别的默认语言顺序（之后再按用户优先语言调整）
    public static let recognitionOrder: [TranslateLanguage] = [
        .english, .simplifiedChinese, .traditionalChinese, .japanese, .korean, .french, .spanish,
        .portuguese, .italian, .german, .russian, .ukrainian, .thai, .vietnamese, .arabic,
        .turkish, .indonesian, .czech, .danish, .dutch, .norwegian, .malay, .polish, .romanian, .swedish,
    ]

    /// 系统偏好语言（系统设置 › 语言与地区），去重后按顺序
    public static var systemPreferred: [TranslateLanguage] {
        var result: [TranslateLanguage] = []
        for identifier in Locale.preferredLanguages {
            if let language = TranslateLanguage(localeIdentifier: identifier), !result.contains(language) {
                result.append(language)
            }
        }
        return result
    }
}
