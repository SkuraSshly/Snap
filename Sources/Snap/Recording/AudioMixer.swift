import AVFoundation
import CoreMedia

/// 实时混音：把系统声音和麦克风混成一条音轨，音画同步。
///
/// 做法：
/// 1. 两路声音先统一转换成 48kHz、立体声、32 位浮点（采样率或声道不同时用 AVAudioConverter 转换）
/// 2. 按每段声音自带的时间戳（与画面同一个时钟）算出它在时间线上的位置（第几个采样），叠加到混音缓冲区
/// 3. 两路都已经写到的部分即可输出，交给 AAC 编码器；某一路暂时没有数据（卡住或延迟）超过 0.5 秒，
///    就按静音处理，不让另一路无限等待
///
/// 所有方法都必须在同一个串行队列（录制引擎的音频队列）上调用。
final class AudioMixer {
    enum Source: CaseIterable { case system, microphone }

    static let sampleRate = 48_000.0
    static let channels: AVAudioChannelCount = 2
    /// 混音格式：48kHz 立体声浮点（非交错）
    static let mixFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: channels, interleaved: false)!

    /// 输出：交错的 32 位浮点立体声（AAC 编码器的输入）
    private let outputDescription: CMAudioFormatDescription
    /// 时间线起点（第一帧画面的时间）
    private let startTime: CMTime
    /// 起点换算成 48kHz 时间刻度下的采样序号。输出时间戳直接用「起点序号 + 采样数」表示，保证首尾严格相接
    ///（ScreenCaptureKit 的时间刻度是纳秒，与 1/48000 秒相加时公倍数超出 CMTime 的范围，会被四舍五入，导致相邻两段之间有纳秒级的缝）
    private let startSample: CMTimeValue
    private let activeSources: Set<Source>
    private let onOutput: (CMSampleBuffer) -> Void

    /// 麦克风静音：静音期间麦克风这一路按静音处理（时间线照常推进）
    var isMicrophoneMuted = false

    // 混音缓冲区：left[0] / right[0] 对应时间线上的第 baseIndex 个采样
    private var left: [Float] = []
    private var right: [Float] = []
    private var baseIndex: Int64 = 0
    /// 每一路已经写到的位置（不含）
    private var sourceEnd: [Source: Int64] = [:]
    private var converters: [Source: (input: AVAudioFormat, converter: AVAudioConverter)] = [:]

    /// 某一路落后超过这么多采样就按静音处理（0.5 秒）
    private let maxLag = Int64(sampleRate / 2)
    /// 每次至少攒够这么多采样再输出（约 21 毫秒）
    private let minChunk: Int64 = 1024

    init(startTime: CMTime, sources: Set<Source>, onOutput: @escaping (CMSampleBuffer) -> Void) throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &description)
        guard status == noErr, let description else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        outputDescription = description
        self.startTime = startTime
        startSample = CMTimeConvertScale(startTime, timescale: CMTimeScale(Self.sampleRate), method: .roundHalfAwayFromZero).value
        self.activeSources = sources
        self.onOutput = onOutput
    }

    // MARK: - 输入

    /// 加入一段声音
    /// - Parameter time: 已扣除暂停时长的时间（与画面时间线一致）
    func add(_ sampleBuffer: CMSampleBuffer, from source: Source, at time: CMTime) {
        guard activeSources.contains(source), let pcm = Self.pcmBuffer(from: sampleBuffer),
              let converted = convert(pcm, from: source), converted.frameLength > 0 else { return }

        let frames = Int64(converted.frameLength)
        var index = Int64((CMTimeGetSeconds(CMTimeSubtract(time, startTime)) * Self.sampleRate).rounded())
        var offset: Int64 = 0
        // 已经输出过的部分不能再改：丢掉落在已输出区间里的开头
        if index < baseIndex {
            offset = baseIndex - index
            index = baseIndex
        }
        guard offset < frames else { return }
        let count = frames - offset

        // 缓冲区不够长就补静音
        let needed = Int(index + count - baseIndex)
        if left.count < needed {
            left.append(contentsOf: repeatElement(0, count: needed - left.count))
            right.append(contentsOf: repeatElement(0, count: needed - right.count))
        }
        let mute = source == .microphone && isMicrophoneMuted
        if !mute, let channels = converted.floatChannelData {
            let start = Int(index - baseIndex)
            let l = channels[0], r = channels[converted.format.channelCount > 1 ? 1 : 0]
            for i in 0..<Int(count) {
                left[start + i] += l[Int(offset) + i]
                right[start + i] += r[Int(offset) + i]
            }
        }
        sourceEnd[source] = max(sourceEnd[source] ?? 0, index + count)
        flush(final: false)
    }

    // MARK: - 输出

    /// 把两路都已写到的部分输出；final 为 true 时把剩下的全部输出（结束录制时）
    func flush(final: Bool, until endTime: CMTime? = nil) {
        let ends = activeSources.map { sourceEnd[$0] ?? baseIndex }
        guard let latest = ends.max() else { return }
        var flushEnd: Int64
        if final {
            flushEnd = latest
            if let endTime {
                // 结束录制：声音对齐到视频结束的时刻，没有声音的尾部补静音（例如最后几秒系统没有出声）
                let endIndex = Int64((CMTimeGetSeconds(CMTimeSubtract(endTime, startTime)) * Self.sampleRate).rounded())
                let needed = Int(endIndex - baseIndex)
                if needed > left.count {
                    left.append(contentsOf: repeatElement(0, count: needed - left.count))
                    right.append(contentsOf: repeatElement(0, count: needed - right.count))
                }
                flushEnd = endIndex
            }
        } else {
            // 两路都写到的位置；落后太多的一路按静音处理
            flushEnd = max(ends.min() ?? latest, latest - maxLag)
        }
        flushEnd = min(flushEnd, baseIndex + Int64(left.count))
        let count = flushEnd - baseIndex
        guard count > 0, final || count >= minChunk else { return }

        if let sampleBuffer = makeSampleBuffer(count: Int(count)) {
            onOutput(sampleBuffer)
        }
        left.removeFirst(Int(count))
        right.removeFirst(Int(count))
        baseIndex = flushEnd
    }

    /// 把缓冲区开头 count 个采样做成交错立体声的 CMSampleBuffer（超出 ±1 的部分削波，避免爆音）
    private func makeSampleBuffer(count: Int) -> CMSampleBuffer? {
        var interleaved = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            interleaved[i * 2] = min(max(left[i], -1), 1)
            interleaved[i * 2 + 1] = min(max(right[i], -1), 1)
        }
        let byteCount = count * 8
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer) == noErr,
              let blockBuffer else { return nil }
        let copied = interleaved.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { return nil }

        let presentationTime = CMTime(value: startSample + baseIndex, timescale: CMTimeScale(Self.sampleRate))
        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: outputDescription,
            sampleCount: count, presentationTimeStamp: presentationTime, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer)
        return status == noErr ? sampleBuffer : nil
    }

    // MARK: - 格式转换

    /// CMSampleBuffer → AVAudioPCMBuffer（拷贝 PCM 数据）
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// 转换成 48kHz 立体声浮点；已经是这个格式就直接用
    private func convert(_ buffer: AVAudioPCMBuffer, from source: Source) -> AVAudioPCMBuffer? {
        let input = buffer.format
        if input.commonFormat == .pcmFormatFloat32, !input.isInterleaved,
           input.sampleRate == Self.sampleRate, input.channelCount == Self.channels {
            return buffer
        }
        // 每一路一个转换器（重采样有内部状态，不能每次新建，否则衔接处会有杂音）
        if converters[source]?.input != input {
            guard let converter = AVAudioConverter(from: input, to: Self.mixFormat) else { return nil }
            if input.channelCount == 1 {
                converter.channelMap = [0, 0]   // 单声道麦克风：左右声道都放同一路
            }
            converters[source] = (input, converter)
        }
        guard let converter = converters[source]?.converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * Self.sampleRate / input.sampleRate).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.mixFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
}
