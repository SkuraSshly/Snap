import CoreGraphics
import Foundation

// 文字识别放在单独的 XPC 服务进程（Velos.app/Contents/XPCServices/VelosOCR.xpc）里做：
// Vision 第一次识别后会把识别模型留在进程里（二三十 MB，没有公开接口释放），
// 放在服务进程里，空闲 30 秒后服务自己退出，内存就完整还给系统，Velos 本身保持原来的空闲内存。

/// XPC 服务的名字和参数
public enum OCRService {
    /// 服务名（= 服务 bundle 的 CFBundleIdentifier）
    public static let name = "local.velos.Velos.OCR"
    /// 空闲多久后服务进程自动退出
    public static let idleTimeout: TimeInterval = 30
}

/// Velos 与服务进程之间的接口
@objc public protocol OCRServiceProtocol {
    /// 识别一张图片
    /// - Parameters:
    ///   - pixels: RGBA 8 位、sRGB、预乘 alpha 的像素（见 OCRImage）
    ///   - request: JSON 编码的 OCRRequest
    ///   - reply: JSON 编码的 OCRReply；服务出错时为 nil 和错误描述
    func recognize(pixels: Data, width: Int, height: Int, bytesPerRow: Int, request: Data,
                   reply: @escaping (Data?, String?) -> Void)
}

/// 识别参数
public struct OCRRequest: Codable, Sendable {
    public var pointWidth: Double
    public var pointHeight: Double
    public var preferredLanguages: [String]
    public var selectsBestCandidate: Bool
    public var detectsQRCodes: Bool
    public var smartLayout: Bool

    public init(pointSize: CGSize, options: TextRecognizer.Options) {
        pointWidth = pointSize.width
        pointHeight = pointSize.height
        preferredLanguages = options.preferredLanguages.map(\.rawValue)
        selectsBestCandidate = options.selectsBestCandidate
        detectsQRCodes = options.detectsQRCodes
        smartLayout = options.smartLayout
    }

    public var options: TextRecognizer.Options {
        var options = TextRecognizer.Options()
        options.preferredLanguages = preferredLanguages.compactMap(TranslateLanguage.init(rawValue:))
        options.selectsBestCandidate = selectsBestCandidate
        options.detectsQRCodes = detectsQRCodes
        options.smartLayout = smartLayout
        return options
    }
}

/// 识别结果（只带界面需要的部分，不传原始行）
public struct OCRReply: Codable, Sendable {
    public var text: String
    public var language: String?
    public var confidence: Double
    /// 没有识别到文字（与其他错误区分开）
    public var noText: Bool

    public init(_ result: OCRResult) {
        text = result.text
        language = result.language?.rawValue
        confidence = result.confidence
        noText = false
    }

    public static let empty = OCRReply(text: "", language: nil, confidence: 0, noText: true)

    private init(text: String, language: String?, confidence: Double, noText: Bool) {
        self.text = text
        self.language = language
        self.confidence = confidence
        self.noText = noText
    }

    public var result: OCRResult {
        OCRResult(text: text, language: language.flatMap(TranslateLanguage.init(rawValue:)), confidence: confidence, lines: [])
    }
}

/// 图片 ↔ 原始像素（跨进程传递用；比 PNG 编码快得多）
public enum OCRImage {
    public struct Packed: Sendable {
        public let pixels: Data
        public let width: Int
        public let height: Int
        public let bytesPerRow: Int
    }

    /// 画进 sRGB 的 RGBA 位图
    public static func pack(_ image: CGImage) -> Packed? {
        let width = image.width, height = image.height, bytesPerRow = width * 4
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = Data(count: bytesPerRow * height)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Packed(pixels: data, width: width, height: height, bytesPerRow: bytesPerRow) : nil
    }

    public static func unpack(_ pixels: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard width > 0, height > 0, pixels.count >= bytesPerRow * height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
