import AppKit

/// 屏幕顶部中央的模式提示条，例如「区域截图 · ⌥1 切换全屏 · Enter 完成 · Esc 取消」
@MainActor
final class HintBar {
    let view: PillLabel

    /// - Parameter blending: 截图界面 .withinWindow，录屏界面 .behindWindow
    init(blending: NSVisualEffectView.BlendingMode = .withinWindow) {
        view = PillLabel(padding: NSSize(width: 18, height: 8), blending: blending)
    }

    /// - Parameters:
    ///   - title: 模式名，例如「区域截图」
    ///   - items: 后面的操作说明
    func setContent(title: String, items: [String]) {
        // 模式名用暖棕色加粗，其余操作说明用浅一些的暖棕色
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: view.ink,
        ])
        let rest = items.map { " · " + $0 }.joined()
        text.append(NSAttributedString(string: rest, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: view.secondaryInk,
        ]))
        view.setText(text)
    }

    /// 放到某块屏幕的遮罩里：默认在顶部中央（避开刘海和菜单栏），
    /// 如果挡住了选区或鼠标，就移到底部中央。
    /// - Parameter avoid: 需要避开的区域（遮罩视图坐标）
    func place(in overlay: NSView, screen: NSScreen, avoiding avoid: [CGRect]) {
        if view.superview !== overlay {
            view.removeFromSuperview()
            overlay.addSubview(view)
        }
        let bounds = overlay.bounds
        let size = view.frame.size
        let topInset = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        let x = ((bounds.width - size.width) / 2).rounded()

        var frame = CGRect(x: x, y: (bounds.maxY - topInset - 12 - size.height).rounded(),
                           width: size.width, height: size.height)
        let blocked = avoid.contains { $0.insetBy(dx: -12, dy: -12).intersects(frame) }
        if blocked {
            frame.origin.y = 48
        }
        view.frame = frame
    }

    func remove() {
        view.removeFromSuperview()
    }
}
