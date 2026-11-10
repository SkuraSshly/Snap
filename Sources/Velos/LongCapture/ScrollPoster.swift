import AppKit

/// 给鼠标下面的窗口发滚动事件（长截图限速时补发积压的滚动）。
///
/// 发的是「像触控板一样」的滚动：像素单位、连续，带手势阶段（开始 → 进行中… → 结束）。
/// 原因：平滑滚动工具（例如 Mos）会拦截系统里的滚动事件——不带手势阶段的会被当成鼠标滚轮，
/// 换成它自己的平滑事件（还可能反转方向、放大距离）；带标记（eventSourceUserData）的会被直接丢掉。
/// 它们只处理鼠标滚轮、不碰触控板，带手势阶段的事件就能原样到达页面。
/// 事件走系统通道，交给鼠标指针下面的窗口，所以发之前指针要在选区里。需要「辅助功能」权限。
@MainActor
final class ScrollGesture {
    let axis: ScrollAxis
    private var began = false

    init(axis: ScrollAxis) {
        self.axis = axis
    }

    /// 滚一下：amount 正数是往上 / 往左滚（和系统滚轮事件一致）
    func scroll(_ amount: Int32, at location: CGPoint) {
        guard amount != 0 else { return }
        // 告诉限速：这个是自己发的，放过（不能用事件标记，平滑滚动工具会把带标记的事件丢掉）
        LongCaptureScrollTap.current?.expectOwn(amount)
        post(amount, phase: began ? Self.changed : Self.began, at: location)
        began = true
    }

    /// 结束这次手势（不再滚动时调用；没开始过就什么都不做）
    func end(at location: CGPoint) {
        guard began else { return }
        post(0, phase: Self.ended, at: location)
        began = false
    }

    // 手势阶段（kCGScrollWheelEventScrollPhase 的取值）
    private static let began: Int64 = 1
    private static let changed: Int64 = 2
    private static let ended: Int64 = 4

    private func post(_ amount: Int32, phase: Int64, at location: CGPoint) {
        let event = axis == .vertical
            ? CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)
            : CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: amount, wheel3: 0)
        guard let event else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.location = location
        event.post(tap: .cghidEventTap)
    }
}
