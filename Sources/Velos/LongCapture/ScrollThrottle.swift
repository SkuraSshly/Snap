import AppKit

/// 长截图的滚动限速：把一下猛甩拆成几次小的滚动，保证相邻两帧画面之间页面移动不超过选区的一小半，拼接永远接得上。
///
/// 按时间发放「额度」：每秒最多移动 maxPerFrame ÷ frameInterval 点，额度最多攒一帧的量。
/// 一次滚动超出额度的部分先记下来（pending），之后每一帧补发一点；反向滚动时清掉没补发的部分；
/// 积压最多 maxPending 点，再多的直接丢掉（免得松手后页面还滚很久）。
struct ScrollThrottle {
    /// 每一帧最多让页面移动多少点
    let maxPerFrame: Double
    /// 按多快的截取速度来算「一帧」（秒）
    let frameInterval: Double
    /// 最多积压多少点
    let maxPending: Double
    /// 还没补发的滚动量（点，带正负）
    private(set) var pending: Double = 0
    private var budget: Double
    private var lastRefill: TimeInterval

    init(maxPerFrame: Double, frameInterval: Double, maxPending: Double, now: TimeInterval) {
        self.maxPerFrame = maxPerFrame
        self.frameInterval = frameInterval
        self.maxPending = maxPending
        budget = maxPerFrame
        lastRefill = now
    }

    private mutating func refill(_ now: TimeInterval) {
        budget = min(maxPerFrame, budget + (now - lastRefill) / frameInterval * maxPerFrame)
        lastRefill = now
    }

    /// 用户的一次滚动 delta（点）：返回这次放行多少，其余记下来以后补发
    mutating func take(_ delta: Double, now: TimeInterval) -> Double {
        refill(now)
        guard delta != 0 else { return 0 }
        // 反向了：以前没补发的不要了
        if pending != 0, (pending > 0) != (delta > 0) { pending = 0 }
        let allowed = (delta > 0 ? 1 : -1) * min(abs(delta), budget)
        budget -= abs(allowed)
        pending += delta - allowed
        pending = min(max(pending, -maxPending), maxPending)
        return allowed
    }

    /// 每一帧调用：返回这一帧要补发多少（点），0 表示没有
    mutating func drain(now: TimeInterval) -> Double {
        refill(now)
        guard pending != 0, budget > 0 else { return 0 }
        let amount = (pending > 0 ? 1 : -1) * min(abs(pending), budget)
        budget -= abs(amount)
        pending -= amount
        if abs(pending) < 0.5 { pending = 0 }
        return amount
    }
}

/// 长截图期间拦截选区里的滚轮事件、按 ScrollThrottle 限速。
/// 需要「辅助功能」权限；没有权限时创建不了，返回 nil，长截图照常工作，只是不限速。
/// 只改鼠标在选区里时、沿当前方向的滚动量；其他滚动、其他事件原样放过。长截图结束时立即移除。
@MainActor
final class LongCaptureScrollTap {
    /// 正在工作的限速（长截图期间只有一个）：自己补发的事件要先登记，拦截时放过
    private(set) static weak var current: LongCaptureScrollTap?
    /// 登记过、马上会经过这里的自己发的滚动量
    private var ownAmounts: [Int64] = []
    /// 补发积压时用的手势（开始 → 进行中 → 结束）
    private var drainGesture: ScrollGesture?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var throttle: ScrollThrottle
    /// 选区（Quartz 全局坐标：原点在主屏左上角）
    private let region: CGRect
    let axis: ScrollAxis

    /// - Parameter speed: 设置里的限速快慢（相对「正常」的倍数）
    init?(region: CGRect, axis: ScrollAxis, extent: CGFloat, framesPerSecond: Int, speed: Double = 1) {
        self.region = region
        self.axis = axis
        // 按每秒 30 帧算（截取实际能到 60 / 120 帧，留足余量），每帧最多移动选区的 1/4（相邻两帧至少重叠 3/4，比对稳），
        // 也就是每秒最多滚过约 7.5 个选区；另外不超过每秒 4000 点（选区很高时也不会快得看不清）
        let perFrame = min(Double(extent) * 0.25, 4000.0 / 30) * speed
        throttle = ScrollThrottle(maxPerFrame: perFrame, frameInterval: 1.0 / 30,
                                  maxPending: Double(extent) * 3, now: ProcessInfo.processInfo.systemUptime)
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<LongCaptureScrollTap>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { owner.handle(type: type, event: event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.current = self
        // 每帧补发积压的滚动
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(max(30, framesPerSecond)), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainPending() }
        }
    }

    /// 登记一个马上要发的自己的滚动（经过拦截时原样放过，不再限速）
    func expectOwn(_ amount: Int32) {
        ownAmounts.append(Int64(amount))
        if ownAmounts.count > 32 { ownAmounts.removeFirst(ownAmounts.count - 32) }
    }

    func stop() {
        if Self.current === self { Self.current = nil }
        timer?.invalidate()
        timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统觉得处理太慢、或用户输入时临时停用了：重新打开
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel, region.contains(event.location) else { return Unmanaged.passUnretained(event) }
        let (pointField, fixedField, lineField): (CGEventField, CGEventField, CGEventField) = axis == .vertical
            ? (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventDeltaAxis1)
            : (.scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventDeltaAxis2)
        let delta = Double(event.getIntegerValueField(pointField))
        guard delta != 0 else { return Unmanaged.passUnretained(event) }
        // 自己发的（补发积压）：已经控制过速度，原样放过
        if let index = ownAmounts.firstIndex(of: Int64(delta)) {
            ownAmounts.remove(at: index)
            return Unmanaged.passUnretained(event)
        }
        let allowed = throttle.take(delta, now: ProcessInfo.processInfo.systemUptime)
        if allowed != delta {
            // 按比例缩小这次滚动（三种单位一起改，各 App 读哪个都一致）；放行 0 时也保留事件，不打断手势的开始 / 结束
            let k = allowed / delta
            event.setIntegerValueField(pointField, value: Int64(allowed.rounded()))
            event.setDoubleValueField(fixedField, value: event.getDoubleValueField(fixedField) * k)
            event.setIntegerValueField(lineField, value: Int64((Double(event.getIntegerValueField(lineField)) * k).rounded()))
        }
        return Unmanaged.passUnretained(event)
    }

    /// 补发积压的滚动：发给鼠标下面的窗口（还在选区里时），像触控板一样带手势阶段；补完了就结束这次手势
    private func drainPending() {
        let amount = Int32(throttle.drain(now: ProcessInfo.processInfo.systemUptime).rounded())
        guard let location = CGEvent(source: nil)?.location, region.contains(location) else { return }
        guard amount != 0 else {
            drainGesture?.end(at: location)
            drainGesture = nil
            return
        }
        let gesture = drainGesture ?? ScrollGesture(axis: axis)
        drainGesture = gesture
        gesture.scroll(amount, at: location)
    }
}
