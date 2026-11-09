import AppKit

/// 录制时高亮鼠标点击：在点击位置画一个杏色圆圈，松开时向外扩散并淡出（右键是珊瑚色）。
///
/// 做法：录制所在屏幕上盖一层完全透明、鼠标可以穿透的窗口，圆圈画在这层窗口里。
/// Velos 的窗口默认都不录进视频，这层窗口是唯一的例外（创建录制范围时明确把它加进去），
/// 所以视频里能看到点击效果，控制条、红框等仍然不会被录进去。
///
/// 点击用全局鼠标事件监听（只监听鼠标按下 / 拖动 / 松开，不需要辅助功能权限，也不读取键盘），
/// 只在录制期间存在；没有点击时不做任何事，不占 CPU。
@MainActor
final class ClickHighlighter {
    private let window: NSPanel
    private let screenFrame: CGRect
    private var monitor: Any?
    /// 正按着的按钮对应的圆圈（拖动时跟着鼠标走）
    private var pressed: [Int: CALayer] = [:]

    private static let radius: CGFloat = 17

    /// 这层窗口的编号：创建录制范围时加入「例外」列表
    var windowID: CGWindowID { CGWindowID(window.windowNumber) }

    init(screen: NSScreen) {
        screenFrame = screen.frame
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
    }

    func start() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                           .rightMouseDown, .rightMouseUp, .rightMouseDragged]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let location = NSEvent.mouseLocation
            let type = event.type
            MainActor.assumeIsolated { self?.handle(type, at: location) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window.orderOut(nil)
        window.close()
    }

    /// 处理一次鼠标事件（自测时直接调用）
    func handle(_ type: NSEvent.EventType, at location: CGPoint) {
        let button = (type == .rightMouseDown || type == .rightMouseUp || type == .rightMouseDragged) ? 1 : 0
        let point = CGPoint(x: location.x - screenFrame.minX, y: location.y - screenFrame.minY)
        switch type {
        case .leftMouseDown, .rightMouseDown:
            guard screenFrame.contains(location) else { return }
            pressed[button]?.removeFromSuperlayer()
            pressed[button] = press(at: point, color: button == 0 ? WarmPalette.apricot : WarmPalette.coral)
        case .leftMouseDragged, .rightMouseDragged:
            guard let layer = pressed[button] else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.position = point
            CATransaction.commit()
        case .leftMouseUp, .rightMouseUp:
            guard let layer = pressed.removeValue(forKey: button) else { return }
            release(layer)
        default:
            break
        }
    }

    /// 按下：圆圈从小弹到正常大小
    private func press(at point: CGPoint, color: NSColor) -> CALayer {
        let r = Self.radius
        let layer = CAShapeLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        layer.position = point
        layer.path = CGPath(ellipseIn: layer.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        layer.fillColor = color.withAlphaComponent(0.35).cgColor
        layer.strokeColor = color.withAlphaComponent(0.95).cgColor
        layer.lineWidth = 2.5
        layer.contentsScale = window.backingScaleFactor
        window.contentView?.layer?.addSublayer(layer)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.5
        grow.toValue = 1
        grow.duration = 0.12
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(grow, forKey: "press")
        return layer
    }

    /// 松开：向外扩散并淡出，然后移除
    private func release(_ layer: CALayer) {
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let spread = CABasicAnimation(keyPath: "transform.scale")
        spread.fromValue = 1
        spread.toValue = 1.8
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [spread, fade]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "release")
        CATransaction.commit()
    }

    #if DEBUG
    var debugLayerCount: Int { window.contentView?.layer?.sublayers?.count ?? 0 }
    var debugWindow: NSWindow { window }
    #endif
}
