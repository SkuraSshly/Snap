import AVFoundation
import CoreGraphics
import VideoToolbox

/// 把录屏视频转成 GIF：顺序解码视频（每帧只解码一次），按设置的帧率取帧、缩放，交给流式 GIF 编码器边转边写。
/// 在后台线程运行，不阻塞界面；可以随时取消（取消后不留下半成品文件）。
enum GIFExporter {
    struct Options: Sendable {
        /// 帧率
        var fps: Int
        /// 最大宽度（像素），0 表示与视频相同
        var maxWidth: Int
    }

    enum ExportError: LocalizedError {
        case noVideoTrack
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "文件里没有视频画面。"
            case .decodeFailed: "视频解码失败。"
            }
        }
    }

    /// GIF 保存在视频旁边，文件名相同，扩展名 .gif（重名时自动加序号）
    static func outputURL(for video: URL) -> URL {
        let name = video.deletingPathExtension().lastPathComponent + ".gif"
        return SaveLocation.uniqueURL(in: video.deletingLastPathComponent(), fileName: name)
    }

    /// 导出
    /// - Parameter progress: 进度 0~1（在后台线程回调）
    /// - Returns: GIF 文件位置
    static func export(video: URL, options: Options, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let naturalSize = try await track.load(.naturalSize)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))

        // 输出尺寸：不超过最大宽度，保持比例
        let factor = options.maxWidth > 0 ? min(1, CGFloat(options.maxWidth) / naturalSize.width) : 1
        let width = max(1, Int((naturalSize.width * factor).rounded()))
        let height = max(1, Int((naturalSize.height * factor).rounded()))

        let frameCount = max(1, Int((duration * Double(options.fps)).rounded(.up)))
        let trackStart = try await track.load(.timeRange).start

        // 顺序读取：比按时间点逐个取图快得多（逐个取图每次都要从最近的关键帧重新解码）
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)
        guard reader.startReading() else { throw reader.error ?? ExportError.decodeFailed }
        defer { reader.cancelReading() }

        // 先写到同一文件夹下的隐藏临时文件，完成后再改名，中途取消或失败不留半成品
        let output = outputURL(for: video)
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).gif.partial")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let encoder = try GIFEncoder(url: temporary, width: width, height: height)
        // GIF 没有色彩配置文件，看图软件一律按 sRGB 显示，所以先转换到 sRGB
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { throw ExportError.decodeFailed }
        context.interpolationQuality = .high
        let pixels = UnsafeBufferPointer(start: data.bindMemory(to: UInt32.self, capacity: width * height), count: width * height)

        // 第 index 帧 GIF 显示「时间 ≤ index/fps 的最后一帧视频」。
        // 录屏是可变帧率（画面不变时没有新帧），同一帧视频可能对应好几帧 GIF，只画一次
        var held: CVPixelBuffer?
        var drawn: CVPixelBuffer?
        var nextIndex = 0
        var lastReported = -1
        func emit(until time: Double) throws {
            while nextIndex < frameCount, Double(nextIndex) / Double(options.fps) < time {
                if let held, held !== drawn {
                    var image: CGImage?
                    VTCreateCGImageFromCVPixelBuffer(held, options: nil, imageOut: &image)
                    if let image {
                        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                        try encoder.add(pixels, at: Double(nextIndex) / Double(options.fps))
                        drawn = held
                    }
                }
                nextIndex += 1
                let percent = nextIndex * 100 / frameCount
                if percent != lastReported {
                    lastReported = percent
                    progress(Double(nextIndex) / Double(frameCount))
                }
            }
        }
        while let sample = trackOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMTimeGetSeconds(CMTimeSubtract(sample.presentationTimeStamp, trackStart))
            if held != nil { try emit(until: time) }
            held = buffer
        }
        guard reader.status == .completed else { throw reader.error ?? ExportError.decodeFailed }
        try emit(until: .infinity)
        guard encoder.framesWritten > 0 else { throw ExportError.decodeFailed }
        try encoder.finish(endTime: duration)
        try FileManager.default.moveItem(at: temporary, to: output)
        Log.capture.notice("GIF 导出完成：\(width)×\(height)，\(options.fps) fps，写入 \(encoder.framesWritten)/\(frameCount) 帧（相同的帧已合并）")
        return output
    }
}
