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
        /// 拼好的长度（像素）
        let length: Int
        /// 预览小图；这一帧不更新预览时为 nil
        let preview: CGImage?
        /// 这一帧页面滚动了多少像素（往下为正）；没认出滚动时为 nil
        var motion: Int? = nil
    }

    /// 每一帧处理完后在主线程回调
    var onUpdate: (@MainActor (Update) -> Void)?
    /// 采集意外停止（例如屏幕录制权限被撤销）
    var onError: (@MainActor (String) -> Void)?

    private let queue = DispatchQueue(label: "local.velos.longcapture", qos: .userInteractive)
    /// 开始、停止都在主线程上调用：正在启动时被停止（点剪刀后马上取消），启动完成后要立刻停掉，
    /// 否则界面已经关了，截屏却一直在后台跑
    @MainActor private var stream: SCStream?
    @MainActor private var isStopped = false
    /// 只在 queue 上读写
    private var stitcher: ScrollStitcher
    /// 预览小图的大小（像素）；每秒最多更新 30 次，跟得上滚动
    private var previewSize = (width: 0, height: 0)
    private var previewDirty = false
    private var lastPreview = ContinuousClock.now
    private static let previewInterval = Duration.milliseconds(33)
    private var previewFlushScheduled = false
    private var colorSpace: CGColorSpace
    /// 诊断日志：每 3 秒记一次这段时间里各种结果有多少帧（只有数字，不含画面）
    private var counts: [String: Int] = [:]
    private var lastCountLog = ContinuousClock.now

    #if DEBUG
    /// 自测：这个窗口虽然属于 Velos，也要截进来
    nonisolated(unsafe) static var debugIncludedWindow: CGWindowID?
    #endif

    /// 最长：20000 像素（Retina 屏上约 10000 点），1600 像素宽时约 128 MB
    static let maxLength = 20_000

    override init() {
        stitcher = ScrollStitcher(maxLength: Self.maxLength)
        colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        super.init()
    }

    /// 开始截取 region（全局坐标，单位：点）。启动期间调用了 stop() 的话，启动完成后马上停掉
    @MainActor
    func start(region: CGRect, screen: NSScreen) async throws {
        // 要所有 App（不只是屏幕上正在显示窗口的）：选区边框、提示刚弹出来时可能还没登记成「在屏幕上」，
        // 这时 Velos 不在列表里，就排除不掉，提示条会被截进画面
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !isStopped else { return }
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
        if own.isEmpty { Log.capture.error("长截图：没找到 Velos 自己，选区边框和提示可能被截进画面") }
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
        stitcher = Self.makeStitcher(scale: scale)
        colorSpace = screen.colorSpace?.cgColorSpace ?? colorSpace

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream   // 先记下来：启动期间 stop() 也能停到它
        do {
            try await stream.startCapture()
        } catch {
            if isStopped { return }   // 启动期间被停止，启动失败也无所谓
            self.stream = nil
            throw error
        }
        if isStopped {
            // 启动期间被停止了：stop() 那时停的可能是还没启动完的截屏，这里再停一次
            try? await stream.stopCapture()
        }
    }

    @MainActor
    func stop() async {
        isStopped = true
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    /// 预览窗口里图片的大小（像素）
    func setPreviewSize(width: Int, height: Int) {
        queue.async { [self] in
            previewSize = (width, height)
            previewDirty = true
        }
    }

    /// 比对时忽略两侧边缘：左边 4 点；右边 18 点（滚动时浮出的滚动条在这里）
    private static func makeStitcher(scale: CGFloat) -> ScrollStitcher {
        ScrollStitcher(maxLength: maxLength, edgeMargin: (Int((4 * scale).rounded()), Int((18 * scale).rounded())))
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
        countForLog(event)
        switch event {
        case .started, .appended, .limitReached, .moved, .unchanged: previewDirty = true   // 覆盖更新也会改变预览
        case .lost: break
        }
        send(event, motion: stitcher.lastShift, forcePreview: event == .started)
    }

    /// 把结果送回主线程；预览到时间了就顺带画一张，没到时间就稍后补一张（滚动停下后预览也是最新的）
    private func send(_ event: ScrollStitcher.Event, motion: Int? = nil, forcePreview: Bool = false) {
        var preview: CGImage?
        let now = ContinuousClock.now
        if previewDirty, previewSize.width > 0 {
            if forcePreview || now - lastPreview >= Self.previewInterval {
                preview = stitcher.previewImage(pixelWidth: previewSize.width, pixelHeight: previewSize.height)
                previewDirty = false
                lastPreview = now
            } else if !previewFlushScheduled {
                previewFlushScheduled = true
                queue.asyncAfter(deadline: .now() + .milliseconds(40)) { [self] in
                    previewFlushScheduled = false
                    if previewDirty { send(.unchanged) }
                }
            }
        }
        let update = Update(event: event, length: stitcher.length, preview: preview, motion: motion)
        let callback = onUpdate
        Task { @MainActor in callback?(update) }
    }

    private func countForLog(_ event: ScrollStitcher.Event) {
        let key: String = switch event {
        case .started: "开始"
        case .appended: "接上"
        case .unchanged: "没变"
        case .moved: "往回"
        case .lost: "对不上"
        case .limitReached: "到上限"
        }
        counts[key, default: 0] += 1
        let now = ContinuousClock.now
        guard now - lastCountLog >= .seconds(3) else { return }
        let text = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "，")
        Log.capture.notice("长截图：近 3 秒 \(text, privacy: .public)；已拼 \(self.stitcher.length) 像素")
        counts = [:]
        lastCountLog = now
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
