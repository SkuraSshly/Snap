import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Velos
import VelosOCRKit

/// 翻译引擎的签名：和各家官方文档里的例子一致（改动签名代码后必须仍然对得上，否则请求会被拒）
@Suite struct EngineSigningTests {
    @Test func 腾讯TC3规范请求与官方例子一致() {
        // 官方例子的请求体里「未命名」是 JSON 转义写法（反斜杠 u + 4 位十六进制），不是汉字本身；
        // 用字符码拼出反斜杠，免得编辑器 / 工具把转义自动换成汉字，哈希就对不上了
        let u = String(UnicodeScalar(92)) + "u"
        let payload = #"{"Limit": 1, "Filters": [{"Values": [""# + u + "672a" + u + "547d" + u + "540d" + #""], "Name": "instance-name"}]}"#
        let canonical = Tencent.canonicalRequest(host: "cvm.tencentcloudapi.com", action: "DescribeInstances", payload: payload)
        #expect(EngineCrypto.sha256Hex(payload) == "35e9c5b0e3ae67532d3c9f17ead6c90222632e5b1ff7f6e89887f1398934f064")
        #expect(EngineCrypto.sha256Hex(canonical) == "7019a55be8395899b900fb5564e4200d984910f34794a27cb3fb7d10ff6a1e84")
    }

    @Test func 百度签名与官方例子一致() {
        #expect(Baidu.sign("apple", appid: "2015063000000001", salt: "1435660288", secret: "12345678") == "f89f9594663708c1605f3d736d01d2d4")
    }

    @Test func 有道长文本按前10加长度加后10签名() {
        let long = "abcdefghijKLMNOPQRSTUVWXYZ0123456789"
        let expectedInput = "k" + "abcdefghij" + "36" + "0123456789" + "s1x"
        #expect(Youdao.sign(long, appKey: "k", salt: "s", curtime: "1", secret: "x") == EngineCrypto.sha256Hex(expectedInput))
    }

    @Test func DeepL免费版Key用免费接口() {
        #expect(DeepL.endpoint(for: "abc:fx").host == "api-free.deepl.com")
        #expect(DeepL.endpoint(for: "abc").host == "api.deepl.com")
    }
}

/// 翻译的语言规则
@Suite struct LanguageRulesTests {
    @Test func 默认目标语言中文译英文其他译简体中文() {
        #expect(LanguageRules.defaultTarget(for: .simplifiedChinese) == .english)
        #expect(LanguageRules.defaultTarget(for: .traditionalChinese) == .english)
        #expect(LanguageRules.defaultTarget(for: .japanese) == .simplifiedChinese)
        #expect(LanguageRules.defaultTarget(for: nil) == .simplifiedChinese)
    }

    @Test func 目标语言和原文相同时自动换一种() {
        #expect(LanguageRules.resolvedTarget(.english, source: .english) == .simplifiedChinese)
        #expect(LanguageRules.resolvedTarget(.simplifiedChinese, source: .simplifiedChinese) == .english)
        #expect(LanguageRules.resolvedTarget(.japanese, source: .english) == .japanese)
    }

    @Test func 译文混入繁体字时统一成目标字形() {
        #expect(LanguageRules.normalizedChinese("傳統字符與簡化字符不同", target: .simplifiedChinese) == "传统字符与简化字符不同")
        #expect(LanguageRules.normalizedChinese("Hello 世界", target: .simplifiedChinese) == "Hello 世界")
        #expect(LanguageRules.normalizedChinese("简体中文", target: .traditionalChinese) == "簡體中文")
    }

    @Test func Apple翻译支持的语言列表() {
        #expect(LanguageRules.appleSupported.count == 20)
        #expect(LanguageRules.appleSupported.allSatisfy { $0.localeLanguage.languageCode != nil })
    }

    @Test func 大模型接口地址自动补上路径() {
        #expect(OpenAICompatible.endpoint("https://api.deepseek.com/v1")?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(OpenAICompatible.endpoint("https://open.bigmodel.cn/api/paas/v4/")?.absoluteString
                == "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        #expect(OpenAICompatible.endpoint("https://x.com/v1/chat/completions")?.absoluteString == "https://x.com/v1/chat/completions")
        #expect(OpenAICompatible.endpoint("ftp://x.com") == nil)
    }
}

/// 快捷键的表示
@Suite struct HotkeyTests {
    @Test func 默认快捷键是ALT加ASD() {
        #expect(Hotkey.defaultScreenshot.displayString == "⌥A")
        #expect(Hotkey.defaultRecording.displayString == "⌥S")
        #expect(Hotkey.defaultTranslate.displayString == "⌥D")
    }

    @Test func 只保留四个修饰键() {
        let key = Hotkey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey | alphaLock))
        #expect(key.carbonModifiers == UInt32(cmdKey))
    }

    @Test func 功能键和已知按键() {
        #expect(Hotkey(keyCode: UInt32(kVK_F5), carbonModifiers: 0).isFunctionKey)
        #expect(!Hotkey.defaultScreenshot.isFunctionKey)
        #expect(Hotkey.defaultScreenshot.hasKnownKey)
    }
}

/// 缩略图尺寸：按比例缩小，不超过 240×150；很长的图至少 150×100（按钮放得下），原图本来就小的不放大
@MainActor
@Suite struct ThumbnailSizeTests {
    @Test func 普通截图按比例缩小() {
        #expect(ThumbnailManager.fittedSize(CGSize(width: 1200, height: 750)) == CGSize(width: 240, height: 150))
    }

    @Test func 长截图有最小宽度() {
        let size = ThumbnailManager.fittedSize(CGSize(width: 800, height: 12000))
        #expect(size.width >= 150 && size.height == 150)
    }

    @Test func 很小的截图不放大() {
        #expect(ThumbnailManager.fittedSize(CGSize(width: 80, height: 50)) == CGSize(width: 80, height: 50))
    }
}

/// GIF 编码：第一帧完整写入，之后只写变化的区域，完全没变的帧跳过
@Suite struct GIFEncoderTests {
    static func pixels(_ color: UInt32, width: Int, height: Int, square: (Int, Int)? = nil) -> [UInt32] {
        var p = [UInt32](repeating: color, count: width * height)
        if let (sx, sy) = square {
            for y in sy..<(sy + 4) { for x in sx..<(sx + 4) { p[y * width + x] = 0xFF00_00FF } }
        }
        return p
    }

    @Test func 生成的GIF帧数和尺寸正确() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("velos-test-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let (w, h) = (16, 12)
        let encoder = try GIFEncoder(url: url, width: w, height: h)
        let first = Self.pixels(0xFF33_6699, width: w, height: h)
        let moved = Self.pixels(0xFF33_6699, width: w, height: h, square: (3, 3))
        try first.withUnsafeBufferPointer { try encoder.add($0, at: 0) }
        try first.withUnsafeBufferPointer { try encoder.add($0, at: 0.1) }    // 完全没变：跳过
        try moved.withUnsafeBufferPointer { try encoder.add($0, at: 0.2) }
        try encoder.finish(endTime: 0.4)
        #expect(encoder.framesWritten == 2)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == w && image.height == h)
    }
}

/// 文字识别（离线 Vision）和语言检测
@Suite struct OCRTests {
    /// 白底黑字的合成图片（2 倍像素）
    static func textImage(_ text: String, size: CGSize = CGSize(width: 420, height: 60)) -> CGImage? {
        let scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)]))
        ctx.textPosition = CGPoint(x: 16, y: 18)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    @Test func 识别合成图片里的英文() async throws {
        let image = try #require(Self.textImage("Hello Velos screenshot"))
        let result = try await TextRecognizer().recognize(image, pointSize: CGSize(width: 420, height: 60))
        #expect(result.text.contains("Hello"))
        #expect(result.text.contains("screenshot"))
    }

    @Test func 语言检测() {
        let detector = LanguageDetector(preferredLanguages: [])
        #expect(detector.detect("这是一段用来测试语言检测的中文句子。") == .simplifiedChinese)
        #expect(detector.detect("This is an English sentence used for language detection.") == .english)
    }
}
