import AppKit
import ScreenCaptureKit

/// 长截图的采集：用 ScreenCaptureKit 只截选区，按屏幕刷新率截（60 或 120 帧；画面不变时系统不送新帧，空闲不耗电），
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
    /// 滚轮提供的滚动量（像素，往前为正），从上一次对上的帧算起；nil 表示不知道（例如用的是普通鼠标滚轮）
    private var hint: Double? = 0
    private var scale: CGFloat = 2
    /// 预览最多每 0.2 秒更新一次（每帧都更新太费：要复制一大段像素）
    private var previewDirty = false
    private var lastPreview = ContinuousClock.now
    private var colorSpace: CGColorSpace

    #if DEBUG
    /// 自测：这个窗口虽然属于 Velos，也要截进来
    nonisolated(unsafe) static var debugIncludedWindow: CGWindowID?
    nonisolated(unsafe) static var debugEventLog: [String] = []
    nonisolated(unsafe) static var debugLostFrames: [PixelFrame] = []
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
        // 截得越快，相邻两帧之间页面移动得越少，快速滚动也接得上（拼接一帧只要几毫秒，跟得上）
        let fps = Int32(min(120, max(30, screen.maximumFramesPerSecond)))
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
            hint = 0
        }
    }

    /// 比对时忽略两侧边缘：前面 4 点；后面 18 点（滚动时浮出的滚动条在这里：竖向在右边，横向在下边）
    private static func makeStitcher(axis: ScrollAxis, scale: CGFloat) -> ScrollStitcher {
        ScrollStitcher(axis: axis, maxLength: maxLength,
                       edgeMargin: (Int((4 * scale).rounded()), Int((18 * scale).rounded())))
    }

    /// 滚轮滚了多少（点，NSEvent 的 scrollingDelta：正数是往上 / 往左滚）。precise 为 false 时是普通鼠标滚轮的「行」，换算不准，不作提示
    func addScrollHint(_ points: CGFloat, precise: Bool) {
        queue.async { [self] in
            guard precise else {
                hint = nil
                return
            }
            // 往上滚（正数）= 页面内容往下移 = 拼接方向的负数
            hint = hint.map { $0 - Double(points * scale) }
        }
    }

    /// 等已经送来的帧全部拼完（自动滚动判断「这一步滚完了没有」前调用：拼接慢时结果会晚到）
    /// 返回此刻拼好的长度（像素）：比等主线程收到更新更准
    func flush() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: stitcher.length) }
        }
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
        let usedHint = hint.map { Int($0.rounded()) }
        #if DEBUG
        let began = ContinuousClock.now
        #endif
        let event = stitcher.add(frame, hint: usedHint)
        #if DEBUG
        if Self.debugIncludedWindow != nil {
            let ms = Int(Double((ContinuousClock.now - began).components.attoseconds) / 1e15)
            Self.debugEventLog.append("\(event) 长度 \(stitcher.length) \(ms)ms")
            if event == .started || (event == .lost && Self.debugLostFrames.count < 3) { Self.debugLostFrames.append(frame) }
        }
        #endif
        // 对上了：提示从这一帧重新算；对不上时继续累计（拼接还是拿上一次对上的帧比）
        if event != .lost { hint = 0 }
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
