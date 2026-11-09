import Foundation
import VelosOCRKit

// Velos 的文字识别服务进程（XPC 服务）：只做一件事——收到图片，用 Vision 识别，返回文字。
// 由 macOS 在 Velos 第一次识别时按需启动；空闲 30 秒后自己退出，Vision 模型占用的内存随之完整释放。
// 不联网、不读写文件、不需要任何权限（图片由 Velos 传过来）。

/// 空闲计时：没有进行中的识别、且 30 秒内没有新请求时退出进程
final class IdleExit: @unchecked Sendable {
    static let shared = IdleExit()
    private var active = 0
    private var pending: DispatchWorkItem?

    func begin() {
        DispatchQueue.main.async {
            self.active += 1
            self.pending?.cancel()
            self.pending = nil
        }
    }

    func end() {
        DispatchQueue.main.async {
            self.active -= 1
            self.scheduleIfIdle()
        }
    }

    /// 刚启动、还没收到请求时也按空闲计时（连上后什么都没发的情况）
    func scheduleIfIdle() {
        guard active == 0 else { return }
        pending?.cancel()
        let item = DispatchWorkItem { exit(0) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + OCRService.idleTimeout, execute: item)
    }
}

final class Service: NSObject, OCRServiceProtocol {
    func recognize(pixels: Data, width: Int, height: Int, bytesPerRow: Int, request: Data,
                   reply: @escaping (Data?, String?) -> Void) {
        IdleExit.shared.begin()
        guard let image = OCRImage.unpack(pixels, width: width, height: height, bytesPerRow: bytesPerRow),
              let request = try? JSONDecoder().decode(OCRRequest.self, from: request) else {
            reply(nil, "图片或参数无效")
            IdleExit.shared.end()
            return
        }
        let reply = UncheckedReply(reply)
        Task.detached(priority: .userInitiated) {
            defer { IdleExit.shared.end() }
            do {
                let result = try await TextRecognizer(options: request.options)
                    .recognize(image, pointSize: CGSize(width: request.pointWidth, height: request.pointHeight))
                reply.send(try? JSONEncoder().encode(OCRReply(result)), nil)
            } catch OCRError.noText {
                reply.send(try? JSONEncoder().encode(OCRReply.empty), nil)
            } catch {
                reply.send(nil, error.localizedDescription)
            }
        }
    }
}

/// XPC 的回复闭包可以在任意线程调用一次
struct UncheckedReply: @unchecked Sendable {
    let send: (Data?, String?) -> Void
    init(_ send: @escaping (Data?, String?) -> Void) { self.send = send }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: OCRServiceProtocol.self)
        connection.exportedObject = Service()
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
IdleExit.shared.scheduleIfIdle()
listener.resume()   // 不会返回：开始处理请求（主线程运行 NSRunLoop，见 Info.plist 的 RunLoopType）
