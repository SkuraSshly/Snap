import AppKit
import ScreenCaptureKit

/// 一块被「冻结」的屏幕：按下快捷键那一刻、以原生像素截下的整屏底图。
/// 之后的区域截图和全屏截图都从这张图裁剪，保证所见即所得。
struct FrozenDisplay {
    let displayID: CGDirectDisplayID
    let screen: NSScreen
    /// 原生像素的整屏图像（已带色彩空间）
    let image: CGImage
    /// 每点对应的像素数（Retina 屏为 2）
    let scale: CGFloat

    /// 按全局坐标（点）裁剪出一块区域，返回原生像素图像
    func crop(_ globalRect: CGRect) -> CGImage? {
        let frame = screen.frame
        // AppKit 全局坐标原点在左下角，CGImage 原点在左上角，需要翻转 y
        let pixelRect = CGRect(
            x: (globalRect.minX - frame.minX) * scale,
            y: (frame.maxY - globalRect.maxY) * scale,
            width: globalRect.width * scale,
            height: globalRect.height * scale
        ).integral
        let bounded = pixelRect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !bounded.isEmpty else { return nil }
        return image.cropping(to: bounded)
    }

    /// 全局坐标（点）对应的像素位置（以图像左上角为原点，限制在图像范围内）
    func pixel(at globalPoint: CGPoint) -> (x: Int, y: Int) {
        let frame = screen.frame
        let x = Int(((globalPoint.x - frame.minX) * scale).rounded(.down))
        let y = Int(((frame.maxY - globalPoint.y) * scale).rounded(.down))
        return (min(max(x, 0), image.width - 1), min(max(y, 0), image.height - 1))
    }

    /// 读取某个像素的颜色，并转换到 sRGB（取色器、网页、设计软件通用的色彩空间）。
    /// 只裁出这 1 个像素来转换，不会处理整张图。
    func color(atPixelX x: Int, y: Int) -> SRGBColor? {
        guard let pixelImage = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return SRGBColor(red: bytes[0], green: bytes[1], blue: bytes[2])
    }
}

/// 用 ScreenCaptureKit 截取整块显示器（只在按下快捷键时调用一次，不保持任何 SCStream）
@MainActor
enum ScreenFreezer {
    enum FreezeError: LocalizedError {
        case displayNotFound
        var errorDescription: String? { "找不到要截取的显示器" }
    }

    /// 当前屏幕上的显示器和窗口列表
    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// 标记「普通窗口」的 identifier：设置、权限设置、标注编辑、视频预览。
    /// 它们和其他 App 的窗口一样，可以被截图、录屏、截屏翻译截到（也能悬停识别、单击选中）。
    static let capturableIdentifier = NSUserInterfaceItemIdentifier("local.velos.capturable")

    /// 可以被截到的 Velos 窗口：上面那些普通窗口 + 钉图（用户钉在屏幕上的内容，与 Snipaste 一致）
    static var capturableOwnWindows: Set<CGWindowID> {
        let normal = NSApp.windows.filter { $0.identifier == capturableIdentifier && $0.isVisible && $0.windowNumber > 0 }
        return Set(normal.map { CGWindowID($0.windowNumber) }).union(PinManager.shared.windowNumbers)
    }

    /// 截图时要排除的 Velos 窗口：截图 / 录屏界面、缩略图、录制控件、截屏翻译的结果窗口和提示等临时界面。
    /// 菜单栏图标不排除：它属于菜单栏的一部分，排除掉反而会在菜单栏上留下一块空缺
    static func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let capturable = capturableOwnWindows
        return content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer != statusLevel && !capturable.contains($0.windowID)
        }
    }

    /// 以原生分辨率截取一块屏幕
    static func capture(_ screen: NSScreen, content: SCShareableContent,
                        excluding excluded: [SCWindow], showsCursor: Bool) async throws -> FrozenDisplay {
        let displayID = screen.displayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw FreezeError.displayNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let scale = CGFloat(filter.pointPixelScale)

        let config = SCStreamConfiguration()
        // 输出尺寸 = 点尺寸 × 缩放倍数，即屏幕的原生像素，不做任何缩放
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.captureResolution = .best
        config.showsCursor = showsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // 广色域屏（如 MacBook 内建屏）用 Display P3，否则用 sRGB，颜色与屏幕显示一致
        config.colorSpaceName = screen.canRepresent(.p3) ? CGColorSpace.displayP3 : CGColorSpace.sRGB

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return FrozenDisplay(displayID: displayID, screen: screen, image: image, scale: scale)
    }
}
