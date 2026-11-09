import AppKit

/// 把截图放进剪贴板：PNG（无损、带色彩配置文件）+ TIFF（老一些的软件只认 TIFF）。
///
/// 两种格式都是「按需提供」：剪贴板里先只登记有哪些格式，真正有程序读取（也就是粘贴）时，
/// 系统才来向 Velos 要数据。这样：
/// - TIFF 只在需要时才从 PNG 转换，平时不占内存
/// - Velos 能知道「截图已经被粘贴了」，从而收起对应的缩略图（macOS 没有别的办法得知别的 App 粘贴了）
@MainActor
final class ClipboardWriter: NSObject, NSPasteboardItemDataProvider {
    /// 剪贴板内容被替换之前，需要保持提供者存活
    private static var current: ClipboardWriter?
    private let png: Data
    private var onFirstRead: (() -> Void)?

    private init(png: Data, onFirstRead: (() -> Void)?) {
        self.png = png
        self.onFirstRead = onFirstRead
    }

    /// - Parameter onFirstRead: 第一次有程序读取（粘贴）时回调
    static func write(png: Data, to pasteboard: NSPasteboard, onFirstRead: (() -> Void)? = nil) {
        let writer = ClipboardWriter(png: png, onFirstRead: onFirstRead)
        let item = NSPasteboardItem()
        item.setDataProvider(writer, forTypes: [.png, .tiff])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        current = writer
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                                provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .png:
            item.setData(png, forType: .png)
        case .tiff:
            guard let rep = NSBitmapImageRep(data: png), let tiff = rep.tiffRepresentation(using: .lzw, factor: 0) else { return }
            item.setData(tiff, forType: .tiff)
        default:
            return
        }
        // 系统会在主线程上回调；回调只触发一次
        MainActor.assumeIsolated {
            let callback = onFirstRead
            onFirstRead = nil
            callback?()
        }
    }

    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        MainActor.assumeIsolated {
            if Self.current === self { Self.current = nil }
        }
    }
}
