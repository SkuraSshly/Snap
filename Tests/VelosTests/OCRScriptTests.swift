import Testing
@testable import VelosOCRKit

/// 文字识别「多候选择优」：候选结果要保住自动识别里的非拉丁文字。
/// 指定拉丁字母语言（例如德语）识别时，Vision 可能把中文认成一串拉丁字母乱码，这种候选不能胜出
@Suite struct OCRScriptTests {
    @Test func 中文被认成拉丁字母乱码的候选不算() {
        let auto = "Velos translate test\n截屏翻译自测"
        #expect(!TextRecognizer.keepsScripts(of: auto, in: "Velos translate test\n\nÄMì·áN"))
        #expect(TextRecognizer.keepsScripts(of: auto, in: "Velos translate test\n\n截屏翻译自测"))
    }

    @Test func 只有拉丁字母的原文不受影响() {
        // 英文、德文、法文之间互相比较：都是拉丁字母，照旧按字数和置信度挑
        #expect(TextRecognizer.keepsScripts(of: "Hello world", in: "Hallo Welt"))
    }

    @Test func 其他文字系统也要保住() {
        #expect(!TextRecognizer.keepsScripts(of: "こんにちは 世界", in: "konnichiwa sekai"))
        #expect(!TextRecognizer.keepsScripts(of: "안녕하세요", in: "annyeong"))
        #expect(!TextRecognizer.keepsScripts(of: "Привет мир", in: "Privet mir"))
        // 认错一两个字没关系（保住九成就行）
        #expect(TextRecognizer.keepsScripts(of: "截屏翻译自测中文识别", in: "截屏翻译自测中文识列"))
    }
}
