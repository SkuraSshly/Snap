import AppKit
import ScreenCaptureKit

/// 长截图的采集：用 ScreenCaptureKit 只截选区，最多每秒 60 帧（画面有变化才送新帧：滚动、滚轮的滚动动画、
/// 停下后最后那张停稳的画面都会送来；画面不变时不送，空闲不耗电），
/// 每一帧交给 ScrollStitcher 拼接。拼接在自己的串行队列上做，结果回到主线程通知界面。
/// - 不截鼠标指针（否则指针会被拼进图里）
/// - 排除 Velos 自己的所有窗口（选区边框、控制条、预览）
/// - 只在长截图期间存在，结束后立即停止、释放
final class LongCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Update: @unchecked Sendable {
        let event: ScrollStitcher.Event
        /// 拼好的长度（像素，沿滚动方向）
        let length: Int
        /// 预览用的各段；没有新内容时为 nil
        let preview: [CGImage]?
        /// 第几次重新开始（换方向会重新开始）：界面丢掉旧一轮还在路上的结果
        let generation: Int
    }

    /// 每一帧处理完后在主线程回调
    var onUpdate: (@MainActor (Update) -> Void)?
    /// 采集意外停止（例如屏幕录制权限被撤销）
    var onError: (@MainActor (String) -> Void)?

    private let queue = DispatchQueue(label: "local.velos.longcapture", qos: .userInteractive)
    private var stream: SCStream?
    /// 只在 queue 上读写
    private var stitcher: ScrollStitcher
    private var axis: ScrollAxis
    private var generation = 0
    private var scale: CGFloat = 2
    /// 预览最多每 0.2 秒更新一次（每帧都更新太费：要复制一大段像素）
    private var previewDirty = false
    private var lastPreview = ContinuousClock.now
    private var colorSpace: CGColorSpace

    #if DEBUG
    /// 自测：这个窗口虽然属于 Velos，也要截进来
    nonisolated(unsafe) static var debugIncludedWindow: CGWindowID?
    #endif

    /// 最长：沿滚动方向 20000 像素（Retina 屏上约 10000 点），竖向 1600 像素宽时约 128 MB
    static let maxLength = 20_000

    init(axis: ScrollAxis) {
        stitcher = ScrollStitcher(axis: axis, maxLength: Self.maxLength)
        self.axis = axis
        colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        super.init()
    }

    /// 开始截取 region（全局坐标，单位：点）
    func start(region: CGRect, screen: NSScreen) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw LongCaptureError.displayNotFound
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == pid }
        var excepting: [SCWindow] = []
        #if DEBUG
        // 自测：截 Velos 自己开的测试页面（平时 Velos 的窗口一律不截）
        if let id = Self.debugIncludedWindow { excepting = content.windows.filter { $0.windowID == id } }
        #endif
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: excepting)
        let scale = CGFloat(filter.pointPixelScale)
        let frame = screen.frame

        let config = SCStreamConfiguration()
        // 选区在这块屏幕里的位置（ScreenCaptureKit 的坐标原点在左上角）
        config.sourceRect = CGRect(x: region.minX - frame.minX, y: frame.maxY - region.maxY,
                                   width: region.width, height: region.height)
        config.width = Int((region.width * scale).rounded())
        config.height = Int((region.height * scale).rounded())
        config.captureResolution = .best
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // 不指定色彩空间：按屏幕自己的色彩空间截，不做转换。
        // 转换（例如内建屏的色彩描述 → Display P3）会加一点抖动，三分之一的像素前后两帧差 1~2 级，
        // 滚动前后的画面就不再逐像素一致，只能用慢得多的容差比对，快速滚动时跟不上
        // 最多每秒 60 帧：手动滚动有限速（按每秒 30 帧设计），60 帧足够接上。
        // 不跟着屏幕刷新率走：240Hz 的高刷屏每秒送来 240 帧，每帧都要拼接、更新长度和预览，主线程会被塞满
        let fps = Int32(min(60, max(30, screen.maximumFramesPerSecond)))
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.queueDepth = 5
        self.scale = scale
        stitcher = Self.makeStitcher(axis: axis, scale: scale)
        colorSpace = screen.colorSpace?.cgColorSpace ?? colorSpace

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    /// 换方向：从头开始拼（下一帧作为新的第一帧）
    func reset(axis: ScrollAxis) {
        queue.async { [self] in
            self.axis = axis
            stitcher = Self.makeStitcher(axis: axis, scale: scale)
            generation += 1
        }
    }

    /// 比对时忽略两侧边缘：前面 4 点；后面 18 点（滚动时浮出的滚动条在这里：竖向在右边，横向在下边）
    private static func makeStitcher(axis: ScrollAxis, scale: CGFloat) -> ScrollStitcher {
        ScrollStitcher(axis: axis, maxLength: maxLength,
                       edgeMargin: (Int((4 * scale).rounded()), Int((18 * scale).rounded())))
    }

    /// 拼好的整张图
    func makeImage() async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: stitcher.makeImage()) }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let frame = Self.frame(from: sampleBuffer, colorSpace: colorSpace) else { return }
        process(frame)
    }

    /// 拼接一帧，把结果送回主线程（在 queue 上调用）
    private func process(_ frame: PixelFrame) {
        let event = stitcher.add(frame)
        switch event {
        case .started, .appended, .limitReached, .moved, .unchanged: previewDirty = true   // 覆盖更新也会改变预览
        case .lost: break
        }
        var preview: [CGImage]?
        let now = ContinuousClock.now
        if previewDirty, event == .started || now - lastPreview >= .milliseconds(200) {
            // 预览只显示最后一段（预览窗口约 150 × 420 点，取宽度的 3 倍长就够）
            preview = stitcher.previewParts(maxLines: max(600, (axis == .vertical ? frame.width : frame.height) * 3))
            previewDirty = false
            lastPreview = now
        }
        let update = Update(event: event, length: stitcher.length, preview: preview, generation: generation)
        let callback = onUpdate
        Task { @MainActor in callback?(update) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let callback = onError
        let message = error.localizedDescription
        Task { @MainActor in callback?(message) }
    }

    /// 只要内容完整的帧（画面没变时系统也会送「空闲」帧，跳过）；像素复制出来，缓冲区马上还给系统
    private static func frame(from sampleBuffer: CMSampleBuffer, colorSpace: CGColorSpace) -> PixelFrame? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let data = Data(bytes: base, count: bytesPerRow * height)
        // 帧上带着它的色彩空间时用帧上的（输出的长图按它标记颜色）
        let space = CVImageBufferGetColorSpace(pixelBuffer)?.takeUnretainedValue() ?? colorSpace
        return PixelFrame(width: width, height: height, bytesPerRow: bytesPerRow, data: data, colorSpace: space)
    }
}

#if DEBUG
extension LongCaptureEngine {
    /// 自测：不截屏幕，直接喂合成的画面（不读取用户屏幕内容）
    func debugFeed(_ frame: PixelFrame) {
        queue.async { [self] in process(frame) }
    }
}
#endif

enum LongCaptureError: LocalizedError {
    case displayNotFound

    var errorDescription: String? { "找不到选区所在的屏幕" }
}
