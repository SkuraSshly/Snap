import AVFoundation
import SnapOCRKit

/// 朗读：AVSpeechSynthesizer，按语言自动选系统里最好的声音（优先「高品质」，其次「增强版」）。
/// 同一时间只朗读一段；再点一次同一个朗读按钮就停止。
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    /// 正在朗读的那一段的标识（界面据此显示「停止」）
    @Published private(set) var speakingID: String?
    private lazy var synthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        return synthesizer
    }()

    /// 朗读；如果正在读同一段就停止
    func toggle(_ text: String, language: TranslateLanguage?, id: String) {
        if speakingID == id {
            stop()
            return
        }
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.bestVoice(for: language)
        utterance.rate = Float(Preferences.shared.speechRate)
        speakingID = id
        synthesizer.speak(utterance)
    }

    /// 按指定口音朗读（词典里的英式 / 美式发音），voiceLanguage 例如 en-GB、en-US、zh-CN
    func toggle(_ text: String, voiceLanguage: String, id: String) {
        if speakingID == id {
            stop()
            return
        }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == voiceLanguage }
        utterance.voice = voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: voiceLanguage)
        utterance.rate = Float(Preferences.shared.speechRate)
        speakingID = id
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speakingID = nil
    }

    /// 某种语言最好的声音：同语言里质量最高的；没有就按语言代码让系统选
    static func bestVoice(for language: TranslateLanguage?) -> AVSpeechSynthesisVoice? {
        guard let language else { return nil }
        let code = language.rawValue
        // 系统声音的语言代码是 zh-CN / zh-TW / en-US 这样的形式
        let prefixes: [String] = switch language {
        case .simplifiedChinese: ["zh-CN"]
        case .traditionalChinese: ["zh-TW", "zh-HK"]
        default: [code]
        }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            prefixes.contains { voice.language == $0 || voice.language.hasPrefix($0 + "-") || voice.language.hasPrefix($0) }
        }
        let best = voices.max { $0.quality.rawValue < $1.quality.rawValue }
        return best ?? AVSpeechSynthesisVoice(language: prefixes[0])
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingID = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if !self.synthesizer.isSpeaking { self.speakingID = nil } }
    }
}
