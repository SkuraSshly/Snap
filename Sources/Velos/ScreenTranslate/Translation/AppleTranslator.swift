import Foundation
import VelosOCRKit
import Translation

/// Apple 系统翻译的快速通道（macOS 26 起）：语言包已经下载时，不需要窗口就能直接翻译。
///
/// 比通过窗口的 .translationTask 快得多（一句话约 30~90 毫秒），所以识别一结束就能开始翻译，
/// 结果窗口出现时译文多半已经好了。语言包没下载时还是走窗口那条路（系统要在窗口上弹下载提示）。
/// 同一对语言的翻译会话会复用；空闲 60 秒后释放，空闲时不占资源。
@available(macOS 26.0, *)
@MainActor
final class AppleTranslator {
    static let shared = AppleTranslator()

    private var sessions: [String: TranslationSession] = [:]
    /// 已确认下载好语言包的语言对（避免每次都问系统）
    private var installed: Set<String> = []
    private var releaseTask: Task<Void, Never>?

    private init() {}

    private static func key(_ source: TranslateLanguage, _ target: TranslateLanguage) -> String {
        source.rawValue + ">" + target.rawValue
    }

    /// 这对语言的状态（已下载 / 需要下载 / 不支持）
    func status(from source: TranslateLanguage, to target: TranslateLanguage) async -> LanguageAvailability.Status {
        let key = Self.key(source, target)
        if installed.contains(key) { return .installed }
        let status = await LanguageAvailability().status(from: source.localeLanguage, to: target.localeLanguage)
        if status == .installed { installed.insert(key) }
        return status
    }

    /// 直接翻译（调用前确认 status 是 .installed）
    func translate(_ text: String, from source: TranslateLanguage, to target: TranslateLanguage) async throws -> String {
        try await translateByParagraph(text, from: source, to: target) { _ in }
    }

    /// 逐段翻译，每翻好一段就回调一次（参数是目前为止的译文）。
    /// Apple 翻译的耗时和字数成正比（约每 300 字 0.1 秒），整篇一起翻和逐段翻总时间差不多，
    /// 但逐段翻第一段约 0.1 秒就能显示，不用等整篇翻完。
    func translateByParagraph(_ text: String, from source: TranslateLanguage, to target: TranslateLanguage,
                              onProgress: (String) -> Void) async throws -> String {
        let key = Self.key(source, target)
        let session = sessions[key] ?? TranslationSession(installedSource: source.localeLanguage, target: target.localeLanguage)
        sessions[key] = session
        scheduleRelease()
        // 段落之间是空行（排版结果的格式）；保留原来的分隔
        let paragraphs = text.components(separatedBy: "\n\n")
        var done: [String] = []
        do {
            for paragraph in paragraphs {
                try Task.checkCancellation()
                if paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    done.append(paragraph)
                    continue
                }
                let translated = try await session.translate(paragraph).targetText
                done.append(LanguageRules.normalizedChinese(translated, target: target))
                if done.count < paragraphs.count { onProgress(done.joined(separator: "\n\n")) }
            }
        } catch {
            // 语言包被删掉了之类：下次重新问系统
            sessions[key] = nil
            installed.remove(key)
            throw error
        }
        return done.joined(separator: "\n\n")
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.sessions.removeAll()
        }
    }
}
