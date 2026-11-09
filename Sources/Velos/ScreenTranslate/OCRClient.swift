import AppKit
import VelosOCRKit

/// 文字识别的入口：把图片交给识别服务进程（VelosOCR.xpc）识别。
///
/// 为什么不在 Velos 里直接识别：Vision 第一次识别后会把模型留在进程里（二三十 MB，没有公开接口释放）。
/// 放在服务进程里，服务空闲 30 秒后自己退出，内存完整还给系统；Velos 本身的空闲内存不受影响。
/// 服务退出后再次识别时，macOS 会自动重新启动它（多花约 0.1~0.3 秒）。
///
/// 服务启动失败（例如 App 包不完整）时，退回到在 Velos 进程里直接识别，并记日志。
@MainActor
final class OCRClient {
    static let shared = OCRClient()

    private var connection: NSXPCConnection?
    /// 第一次识别要等系统为新安装的程序准备模型，可能需要十几秒，所以超时放宽
    private static let timeout: Duration = .seconds(90)

    private init() {}

    func recognize(_ image: CGImage, pointSize: CGSize, options: TextRecognizer.Options = .init()) async throws -> OCRResult {
        let packStarted = ContinuousClock.now
        if let packed = OCRImage.pack(image) {
            let packed_ = ContinuousClock.now - packStarted
            do {
                let result = try await remote(packed, request: OCRRequest(pointSize: pointSize, options: options))
                Log.capture.notice("截屏翻译：准备图片 \(packed_.formatted(.units(allowed: [.milliseconds])), privacy: .public)，服务识别 \((ContinuousClock.now - packStarted - packed_).formatted(.units(allowed: [.milliseconds])), privacy: .public)")
                return result
            } catch let error as OCRError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.capture.error("识别服务不可用，改在 Velos 里直接识别：\(error.localizedDescription, privacy: .public)")
            }
        }
        return try await TextRecognizer(options: options).recognize(image, pointSize: pointSize)
    }

    // MARK: - XPC

    private func remote(_ packed: OCRImage.Packed, request: OCRRequest) async throws -> OCRResult {
        let requestData = try JSONEncoder().encode(request)
        let connection = currentConnection()
        let once = ResumeOnce<OCRResult>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.set(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    once.resume(throwing: error)
                } as? OCRServiceProtocol
                guard let proxy else {
                    once.resume(throwing: ServiceError.unavailable)
                    return
                }
                proxy.recognize(pixels: packed.pixels, width: packed.width, height: packed.height,
                                bytesPerRow: packed.bytesPerRow, request: requestData) { data, message in
                    if let data, let reply = try? JSONDecoder().decode(OCRReply.self, from: data) {
                        if reply.noText { once.resume(throwing: OCRError.noText) } else { once.resume(returning: reply.result) }
                    } else {
                        once.resume(throwing: ServiceError.failed(message ?? "没有返回结果"))
                    }
                }
                Task {
                    try? await Task.sleep(for: Self.timeout)
                    once.resume(throwing: ServiceError.timeout)
                }
            }
        } onCancel: {
            once.resume(throwing: CancellationError())
        }
    }

    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(serviceName: OCRService.name)
        connection.remoteObjectInterface = NSXPCInterface(with: OCRServiceProtocol.self)
        // 服务空闲退出属于「中断」：连接仍可用，下次发消息时系统会重新启动服务
        connection.interruptionHandler = {
            Log.capture.notice("截屏翻译：识别服务已退出（空闲释放内存）")
        }
        // 「失效」：连接不能再用了，下次重新建立
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    enum ServiceError: LocalizedError {
        case unavailable, timeout
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: "无法连接识别服务"
            case .timeout: "识别超时"
            case .failed(let message): message
            }
        }
    }
}

/// 让 continuation 只被恢复一次（服务回复、连接出错、超时、取消可能同时发生）
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var finished = false
    private var pendingError: Error?

    func set(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let error = pendingError {   // 在 set 之前就被取消了
            finished = true
            lock.unlock()
            continuation.resume(throwing: error)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        if continuation == nil, !finished { pendingError = error }
        lock.unlock()
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let continuation else { return nil }
        finished = true
        self.continuation = nil
        return continuation
    }
}
