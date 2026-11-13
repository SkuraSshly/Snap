import AVFoundation
import ScreenCaptureKit
import VideoToolbox

/// 录制引擎：ScreenCaptureKit 抓取画面和声音 → AVAssetWriter 用 Apple Silicon 硬件编码器写入 MP4。
///
/// - 画面：原生像素分辨率，HEVC / H.264 硬件编码，写入色彩信息
/// - 声音：系统声音（排除 Velos 自己的声音）+ 麦克风，实时混成一条 AAC 48kHz 256kbps 立体声音轨（见 AudioMixer）
/// - 暂停：暂停期间的画面和声音都丢弃，并从时间线上扣掉这段时长，成品视频是连续的
/// - 只在录制期间存在 SCStream，停止后立即释放
/// - 画面和声音分别在专用的高优先级串行队列上处理，不经过主线程，主线程卡顿不会导致丢帧
///
/// 线程安全：画面状态只在 videoQueue 上读写，混音器只在 audioQueue 上使用，
/// 两个队列共享的时间线由锁保护（@unchecked Sendable 表示由我们自己保证）
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Settings {
        let filter: SCContentFilter
        /// 要录制的区域：显示器内坐标，单位点，原点在左上角（ScreenCaptureKit 的坐标系）
        let sourceRect: CGRect
        /// 输出像素尺寸（偶数，视频编码要求）
        let pixelWidth: Int
        let pixelHeight: Int
        let fps: Int
        let showsCursor: Bool
        let codec: VideoCodec
        let quality: VideoQuality
        /// 广色域屏用 Display P3，否则 sRGB
        let isWideGamut: Bool
        let capturesSystemAudio: Bool
        let capturesMicrophone: Bool
        /// 麦克风设备 uniqueID；nil 表示系统默认
        let microphoneDeviceID: String?
        let outputURL: URL
    }

    enum RecorderError: LocalizedError {
        case cannotStartWriting(Error?)
        case noFrames
        case writeFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .cannotStartWriting(let error): "无法创建视频文件：\(error?.localizedDescription ?? "未知原因")"
            case .noFrames: "没有录到任何画面。"
            case .writeFailed(let error): "视频写入失败：\(error?.localizedDescription ?? "未知原因")"
            }
        }
    }

    let settings: Settings
    /// 录制意外中断（例如权限被收回、显示器被拔掉）时在主线程回调
    var onInterrupted: ((Error) -> Void)?

    private var stream: SCStream?
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let videoQueue = DispatchQueue(label: "local.velos.recorder.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "local.velos.recorder.audio", qos: .userInteractive)
    private let timeline = Timeline()

    // 只在 videoQueue 上读写
    /// 视频文件已经建好、可以写入了。截屏启动成功后才建文件（启动失败就不会在保存文件夹里留下打不开的空视频）；
    /// 启动和建文件之间那几毫秒到的帧直接丢掉
    private var isWriting = false
    private var framesWritten = 0
    private var framesDropped = 0
    private var lastFrameTime = CMTime.zero

    // 只在 audioQueue 上读写
    private var mixer: AudioMixer?
    private var audioBuffersDropped = 0
    private var microphoneMuted = false

    init(settings: Settings) throws {
        self.settings = settings
        writer = try AVAssetWriter(outputURL: settings.outputURL, fileType: .mp4)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(for: settings))
        videoInput.expectsMediaDataInRealTime = true
        if settings.capturesSystemAudio || settings.capturesMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
            input.expectsMediaDataInRealTime = true
            audioInput = input
        } else {
            audioInput = nil
        }
        super.init()
        writer.add(videoInput)
        if let audioInput { writer.add(audioInput) }
    }

    // MARK: - 编码参数

    /// 视频码率：按「每像素每帧多少比特」计算，偏高画质，保证文字和代码边缘清晰
    static func bitRate(for settings: Settings) -> Int {
        let pixelsPerSecond = Double(settings.pixelWidth * settings.pixelHeight * settings.fps)
        let bitsPerPixel: Double = switch (settings.codec, settings.quality) {
        case (.hevc, .high): 0.07
        case (.hevc, .ultra): 0.14
        case (.h264, .high): 0.11
        case (.h264, .ultra): 0.22
        }
        return Int(min(max(pixelsPerSecond * bitsPerPixel, 4_000_000), 160_000_000))
    }

    private static func videoSettings(for settings: Settings) -> [String: Any] {
        let isHEVC = settings.codec == .hevc
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate(for: settings),
            AVVideoExpectedSourceFrameRateKey: settings.fps,
            AVVideoMaxKeyFrameIntervalKey: settings.fps * 2,   // 每 2 秒一个关键帧，拖动进度条时定位准确
            AVVideoProfileLevelKey: isHEVC ? (kVTProfileLevel_HEVC_Main_AutoLevel as String) : AVVideoProfileLevelH264HighAutoLevel,
        ]
        if !isHEVC {
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        }
        return [
            AVVideoCodecKey: isHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: settings.pixelWidth,
            AVVideoHeightKey: settings.pixelHeight,
            AVVideoCompressionPropertiesKey: compression,
            // 写入色彩信息，播放时颜色与屏幕一致
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: settings.isWideGamut ? AVVideoColorPrimaries_P3_D65 : AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
    }

    /// AAC 48kHz 256kbps 立体声（固定码率：默认的可变码率遇到安静的片段会降到几 kbps）
    private static let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: AudioMixer.sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 256_000,
        AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
    ]

    // MARK: - 开始 / 暂停 / 停止

    func start() async throws {
        let config = SCStreamConfiguration()
        config.width = settings.pixelWidth
        config.height = settings.pixelHeight
        config.sourceRect = settings.sourceRect
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        config.showsCursor = settings.showsCursor
        // 直接输出 YUV 4:2:0：HEVC / H.264 本来就以 4:2:0 编码，画质与 RGB 输入完全相同，
        // 但每帧内存只有 RGB 的 3/8，编码器也省去一次格式转换
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = settings.isWideGamut ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        // 帧缓冲队列：硬件编码跟得上，5 帧足够，不必多占内存
        config.queueDepth = 5
        config.captureResolution = .best

        // 声音：系统声音排除 Velos 自己发出的声音；麦克风用 ScreenCaptureKit 自带的麦克风采集（macOS 15+）
        config.capturesAudio = settings.capturesSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(AudioMixer.sampleRate)
        config.channelCount = 2
        config.captureMicrophone = settings.capturesMicrophone
        if settings.capturesMicrophone, let id = settings.microphoneDeviceID {
            config.microphoneCaptureDeviceID = id
        }

        let stream = SCStream(filter: settings.filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if settings.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if settings.capturesMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        // 截屏启动成功了，才建视频文件（startWriting 时文件出现在保存文件夹里）。
        // 在画面队列上做：之后到的帧一定能看到 isWriting，不会在文件还没准备好时写入
        let started = videoQueue.sync {
            isWriting = writer.startWriting()
            return isWriting
        }
        guard started else {
            try? await stream.stopCapture()
            discardOutput()   // 建到一半失败的残留（通常没有）
            throw RecorderError.cannotStartWriting(writer.error)
        }
        self.stream = stream
    }

    /// 没录成（建文件失败、没录到任何画面）：取消写入，删掉 Velos 自己刚建的、没有内容的视频文件
    private func discardOutput() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: settings.outputURL)
    }

    /// 暂停 / 继续：暂停期间的画面和声音都不写入，成品里没有这一段
    func setPaused(_ paused: Bool) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if paused { timeline.pause(at: now) } else { timeline.resume(at: now) }
    }

    /// 已录制的有效时长（扣除暂停），用于界面计时
    var elapsed: TimeInterval { timeline.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock())) }

    /// 麦克风静音（时间线照常推进，只是这一路变成静音）
    func setMicrophoneMuted(_ muted: Bool) {
        audioQueue.async { self.microphoneMuted = muted; self.mixer?.isMicrophoneMuted = muted }
    }

    /// 录制中更换录制范围（同一块显示器，只改排除哪些窗口）
    func updateFilter(_ filter: SCContentFilter) async throws {
        try await stream?.updateContentFilter(filter)
    }

    /// 停止录制并把文件写完；返回文件位置
    func stop() async throws -> URL {
        // 按下停止的时刻（与画面帧使用同一个时钟）。
        // ScreenCaptureKit 只在画面变化时才发新帧，画面静止时最后一帧之后没有新帧，
        // 必须明确告诉写入器视频到这里结束，否则静止画面的录屏会只有一帧那么长
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        let endTime = timeline.endTime(stoppedAt: stopTime)
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        // 等两个队列里剩下的数据处理完，把混音器里剩下的声音全部输出
        let (written, dropped, lastFrame) = await withCheckedContinuation { continuation in
            videoQueue.async { continuation.resume(returning: (self.framesWritten, self.framesDropped, self.lastFrameTime)) }
        }
        let audioDropped = await withCheckedContinuation { continuation in
            audioQueue.async {
                if let endTime { self.mixer?.flush(final: true, until: endTime) }
                continuation.resume(returning: self.audioBuffersDropped)
            }
        }
        guard let endTime, written > 0 else {
            discardOutput()
            throw RecorderError.noFrames
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMaximum(endTime, lastFrame))
        await writer.finishWriting()
        guard writer.status == .completed else { throw RecorderError.writeFailed(writer.error) }
        Log.capture.notice("录制完成：写入 \(written) 帧，丢弃 \(dropped) 帧，丢弃音频块 \(audioDropped)")
        return settings.outputURL
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: handleVideo(sampleBuffer)
        case .audio: handleAudio(sampleBuffer, from: .system)
        case .microphone: handleAudio(sampleBuffer, from: .microphone)
        @unknown default: break
        }
    }

    /// 画面（videoQueue）
    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isWriting, Self.isCompleteFrame(sampleBuffer) else { return }
        let pts = sampleBuffer.presentationTimeStamp
        if !timeline.hasStarted {
            // 以第一帧的时间作为视频起点；先开始写入会话，再让音频队列知道起点
            writer.startSession(atSourceTime: pts)
            timeline.start(at: pts)
            audioQueue.async { self.makeMixer(startTime: pts) }
        }
        // 暂停中的帧丢弃；之后的帧扣除暂停时长
        guard let adjusted = timeline.adjusted(pts),
              let retimed = Self.retimed(sampleBuffer, to: adjusted) else { return }
        if videoInput.isReadyForMoreMediaData, videoInput.append(retimed) {
            framesWritten += 1
            lastFrameTime = adjusted
        } else {
            framesDropped += 1
        }
    }

    /// 声音（audioQueue）
    private func handleAudio(_ sampleBuffer: CMSampleBuffer, from source: AudioMixer.Source) {
        guard let mixer, let adjusted = timeline.adjusted(sampleBuffer.presentationTimeStamp) else { return }
        mixer.add(sampleBuffer, from: source, at: adjusted)
    }

    private func makeMixer(startTime: CMTime) {
        guard let audioInput else { return }
        var sources = Set<AudioMixer.Source>()
        if settings.capturesSystemAudio { sources.insert(.system) }
        if settings.capturesMicrophone { sources.insert(.microphone) }
        mixer = try? AudioMixer(startTime: startTime, sources: sources) { [weak self] buffer in
            guard let self else { return }
            if audioInput.isReadyForMoreMediaData {
                audioInput.append(buffer)
            } else {
                self.audioBuffersDropped += 1
            }
        }
        mixer?.isMicrophoneMuted = microphoneMuted
    }

    /// ScreenCaptureKit 在画面没有变化时会发送「空闲」帧（没有图像），只写入完整帧
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }

    /// 改写帧的时间戳（扣除暂停时长后）
    private static func retimed(_ sampleBuffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        if time == sampleBuffer.presentationTimeStamp { return sampleBuffer }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                                              sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &output)
        return output
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("录制被中断：\(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async { self.onInterrupted?(error) }
    }
}

/// 录制时间线：记录起点和所有暂停区间，把原始时间换算成扣除暂停后的时间。
/// 画面队列和音频队列都会读，用锁保护。
private final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private var startTime: CMTime?
    /// 已结束的暂停区间
    private var pauses: [(start: CMTime, end: CMTime)] = []
    private var pausedAt: CMTime?

    var hasStarted: Bool { lock.withLock { startTime != nil } }

    func start(at time: CMTime) {
        lock.withLock { if startTime == nil { startTime = time } }
    }

    func pause(at time: CMTime) {
        lock.withLock { if pausedAt == nil { pausedAt = time } }
    }

    func resume(at time: CMTime) {
        lock.withLock {
            guard let pausedAt else { return }
            pauses.append((pausedAt, time))
            self.pausedAt = nil
        }
    }

    /// 扣除暂停后的时间；落在暂停期间（或起点之前）的返回 nil，应丢弃
    func adjusted(_ time: CMTime) -> CMTime? {
        lock.withLock {
            guard let startTime, time >= startTime else { return nil }
            if let pausedAt, time >= pausedAt { return nil }
            var offset = CMTime.zero
            for pause in pauses {
                if time >= pause.end {
                    offset = CMTimeAdd(offset, CMTimeSubtract(pause.end, pause.start))
                } else if time >= pause.start {
                    return nil
                }
            }
            return CMTimeSubtract(time, offset)
        }
    }

    /// 视频结束时间（扣除暂停后）；暂停中停止的，结束在暂停那一刻
    func endTime(stoppedAt time: CMTime) -> CMTime? {
        lock.withLock {
            guard let startTime else { return nil }
            let end = CMTimeMaximum(pausedAt ?? time, startTime)
            var offset = CMTime.zero
            for pause in pauses where pause.end <= end {
                offset = CMTimeAdd(offset, CMTimeSubtract(pause.end, pause.start))
            }
            return CMTimeSubtract(end, offset)
        }
    }

    /// 已录制的有效时长（扣除暂停），用于界面上的计时
    func elapsed(at time: CMTime) -> TimeInterval {
        guard let start = lock.withLock({ startTime }), let end = endTime(stoppedAt: time) else { return 0 }
        return max(0, CMTimeGetSeconds(CMTimeSubtract(end, start)))
    }
}
