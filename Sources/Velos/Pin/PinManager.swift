import AppKit

/// 管理所有钉图窗口。
/// 钉图属于「内容」而不是 Velos 的界面：再次截图时会出现在画面里，也可以被窗口识别选中（与 Snipaste 一致）。
@MainActor
final class PinManager {
    static let shared = PinManager()

    private var windows: [PinWindow] = []
    private var closeTokens: [ObjectIdentifier: NSObjectProtocol] = [:]

    private init() {}

    /// 钉图窗口的编号，截图时用来把它们从「排除列表」中拿掉
    var windowNumbers: Set<CGWindowID> {
        Set(windows.map { CGWindowID($0.windowNumber) })
    }

    var count: Int { windows.count }

    /// 钉图：默认钉在截取的原位（看起来就像把那块画面「钉」住了）；
    /// 太大（比如全屏截图）时缩小到屏幕可见区域的 60% 并居中
    func pin(_ capture: CapturedImage) -> PinWindow? {
        guard let image = capture.image else { return nil }
        let size = capture.pointSize
        let screen = NSScreen.screen(containing: CGPoint(x: capture.sourceRect.midX, y: capture.sourceRect.midY))
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var frame = CGRect(origin: capture.sourceRect.origin, size: size)
        // 原位只要在屏幕范围内就行（盖住程序坞也没关系，与 Snipaste 一致）
        let fitsInPlace = screen.frame.contains(frame)
            && size.width <= visible.width * 0.8 && size.height <= visible.height * 0.8
        if let axis = PinView.longAxis(for: size) {
            // 长截图：整张缩进屏幕会细得看不清。按能看清的大小显示（最多原大小），只露出一段，在窗口里滚动翻看
            let zoom = axis == .vertical ? min(1, visible.width * 0.45 / size.width) : min(1, visible.height * 0.45 / size.height)
            let shown = axis == .vertical
                ? CGSize(width: (size.width * zoom).rounded(), height: min((size.height * zoom).rounded(), (visible.height * 0.85).rounded()))
                : CGSize(width: min((size.width * zoom).rounded(), (visible.width * 0.85).rounded()), height: (size.height * zoom).rounded())
            frame = CGRect(x: (visible.midX - shown.width / 2).rounded(), y: (visible.midY - shown.height / 2).rounded(),
                           width: shown.width, height: shown.height)
        } else if !fitsInPlace {
            let factor = min(visible.width * 0.6 / size.width, visible.height * 0.6 / size.height, 1)
            let fitted = CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
            // 坐标取整：带 0.5 的位置会被系统对齐到整点，导致窗口尺寸多出 1 点
            frame = CGRect(x: (visible.midX - fitted.width / 2).rounded(), y: (visible.midY - fitted.height / 2).rounded(),
                           width: fitted.width, height: fitted.height)
        }

        let window = PinWindow(capture: capture, image: image, frame: frame)
        windows.append(window)
        // 关闭时移出列表（窗口和整张图随之释放），并注销这个通知
        let id = ObjectIdentifier(window)
        closeTokens[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                 object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didClose(id) }
        }
        window.orderFrontRegardless()
        return window
    }

    private func didClose(_ id: ObjectIdentifier) {
        windows.removeAll { ObjectIdentifier($0) == id }
        if let token = closeTokens.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
