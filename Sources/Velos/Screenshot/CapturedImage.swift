import AppKit
import ImageIO

/// 一张截图结果：缩略图、钉图、拖拽都围绕它进行。
/// 只在缩略图 / 钉图存在期间被引用，它们关闭后随之释放。
///
/// 省内存：一张整屏截图未压缩约 15~22MB。拿到原生分辨率的无损 PNG（约 1MB）后就丢掉未压缩的图像，
/// 真正需要时（钉图）再从 PNG 解码——无损编码，解码出来与原图逐像素一致。
@MainActor
final class CapturedImage {
    /// 每点像素数
    let scale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int
    /// 截取的位置（全局坐标，单位：点），钉图默认钉在原位
    let sourceRect: CGRect
    let date = Date()

    /// 未压缩的原生像素图像；有了原生分辨率的 PNG 后释放
    private var retainedImage: CGImage?
    /// 原生分辨率的无损 PNG
    private var nativePNG: Data?

    /// 保存成功后的文件位置；没有开启「保存到文件」时为 nil
    var fileURL: URL? {
        didSet { onFileSaved?() }
    }
    var onFileSaved: (() -> Void)?
    /// 正在保存（防止连点「保存」按钮存出两份）
    var isSaving = false

    init(image: CGImage, scale: CGFloat, sourceRect: CGRect) {
        retainedImage = image
        self.scale = scale
        self.pixelWidth = image.width
        self.pixelHeight = image.height
        self.sourceRect = sourceRect
    }

    /// 原生像素图像（不受「按 1x 输出」影响，钉图始终清晰）
    var image: CGImage? {
        if let retainedImage { return retainedImage }
        guard let nativePNG, let source = CGImageSourceCreateWithData(nativePNG as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// 输出流程编码好原生分辨率 PNG 后调用：之后不再保留未压缩的图像
    func adoptNativePNG(_ data: Data) {
        nativePNG = data
        retainedImage = nil
    }

    /// 图像的「点」尺寸
    var pointSize: CGSize {
        CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
    }

    /// 原生分辨率的 PNG（没有就现场编码一次并留存）
    func pngData() -> Data? {
        if let nativePNG { return nativePNG }
        guard let image, let data = ImageEncoder.encode(image, format: .png, quality: 1, scale: scale) else { return nil }
        adoptNativePNG(data)
        return data
    }

    /// 拖拽用的临时文件所在的文件夹：$TMPDIR/Velos
    nonisolated static var sharingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Velos", isDirectory: true)
    }

    /// 启动时删除一天前留下的拖拽临时文件（拖出去的文件对方 App 早已拷走），不让它们越积越多
    nonisolated static func removeStaleSharingFiles(olderThan age: TimeInterval = 24 * 3600) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: sharingDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? manager.removeItem(at: file) }
        }
    }

    /// 拖拽到其他 App、用默认程序打开时需要一个文件：
    /// 已保存就用保存的文件，否则在临时目录写一个 PNG（下次启动时清理一天前的）
    func fileForSharing() -> URL? {
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }
        let directory = Self.sharingDirectory
        let url = directory.appendingPathComponent(SaveLocation.fileName(prefix: "截图", fileExtension: "png", date: date))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = pngData() else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Log.capture.error("临时文件写入失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
