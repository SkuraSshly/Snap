import Foundation
import SnapOCRKit

/// 翻译的语言规则
enum LanguageRules {
    /// Apple 系统翻译支持的语言（与 LanguageAvailability().supportedLanguages 一致：21 种）
    static let appleSupported: [TranslateLanguage] = [
        .simplifiedChinese, .traditionalChinese, .english, .japanese, .korean, .french, .german, .spanish,
        .portuguese, .italian, .russian, .ukrainian, .arabic, .hindi, .indonesian, .vietnamese, .thai,
        .turkish, .dutch, .polish,
    ]

    /// 默认目标语言：原文是中文 → 英文；其他语言 → 简体中文
    static func defaultTarget(for source: TranslateLanguage?) -> TranslateLanguage {
        source?.isChinese == true ? .english : .simplifiedChinese
    }

    /// Apple 翻译偶尔会在要求简体中文时混入繁体字（反之亦然）：统一转换成目标字形（系统自带的繁简转换，离线）
    static func normalizedChinese(_ text: String, target: TranslateLanguage) -> String {
        switch target {
        case .simplifiedChinese: text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        case .traditionalChinese: text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
        default: text
        }
    }

    /// 原文语言和目标语言相同时自动换成另一种（中文 ↔ 英文）
    static func resolvedTarget(_ target: TranslateLanguage, source: TranslateLanguage) -> TranslateLanguage {
        guard target == source else { return target }
        return source.isChinese ? .english : .simplifiedChinese
    }
}
