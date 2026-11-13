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

    /// 钉图：原始大小（100%），钉在截取的原位（看起来就像把那块画面「钉」住了）。
    /// - 比屏幕的可用区域还大：缩小到正好放得下，居中
    /// - 长截图：原来的宽度（太宽才缩小），钉在原位；太长时窗口只露出一段（最多屏幕高度的 85%），在窗口里滚动翻看
    /// - 原位不在任何屏幕上：放到屏幕中间
    func pin(_ capture: CapturedImage) -> PinWindow? {
        guard let image = capture.image else { return nil }
        let size = capture.pointSize
        let screen = NSScreen.screen(containing: CGPoint(x: capture.sourceRect.midX, y: capture.sourceRect.midY))
            ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = Self.pinFrame(size: size, source: capture.sourceRect, screen: screen.frame, visible: screen.visibleFrame)

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

    /// 钉图窗口的位置和大小（单独拿出来，单元测试直接测）
    static func pinFrame(size: CGSize, source: CGRect, screen: CGRect, visible: CGRect) -> CGRect {
        // 坐标取整：带 0.5 的位置会被系统对齐到整点，导致窗口尺寸多出 1 点
        func centered(_ s: CGSize) -> CGRect {
            CGRect(x: (visible.midX - s.width / 2).rounded(), y: (visible.midY - s.height / 2).rounded(), width: s.width, height: s.height)
        }
        /// 放在原位（左上角对齐截取的位置）；超出可用区域的话挪回来
        func inPlace(_ s: CGSize) -> CGRect {
            var origin = CGPoint(x: source.minX, y: source.maxY - s.height)
            origin.x = min(max(origin.x, visible.minX), visible.maxX - s.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - s.height)
            return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: s)
        }
        let onScreen = screen.intersects(source)
        if let axis = PinView.longAxis(for: size) {
            // 长截图：短边按原大小（太宽 / 太高才缩小），长边最多露出可用区域的 85%
            let zoom = axis == .vertical ? min(1, visible.width / size.width) : min(1, visible.height / size.height)
            let shown = axis == .vertical
                ? CGSize(width: (size.width * zoom).rounded(), height: min((size.height * zoom).rounded(), (visible.height * 0.85).rounded()))
                : CGSize(width: min((size.width * zoom).rounded(), (visible.width * 0.85).rounded()), height: (size.height * zoom).rounded())
            return onScreen ? inPlace(shown) : centered(shown)
        }
        // 原位、原大小能完整放在屏幕上：就钉在原位（盖住程序坞也没关系，与 Snipaste 一致）
        let original = CGRect(origin: source.origin, size: size)
        if screen.contains(original) { return original }
        // 比可用区域大：缩小到正好放得下；不大但原位不在屏幕上：原大小放中间
        let factor = min(visible.width / size.width, visible.height / size.height, 1)
        let fitted = CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
        return factor < 1 || !onScreen ? centered(fitted) : inPlace(fitted)
    }

    private func didClose(_ id: ObjectIdentifier) {
        windows.removeAll { ObjectIdentifier($0) == id }
        if let token = closeTokens.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
