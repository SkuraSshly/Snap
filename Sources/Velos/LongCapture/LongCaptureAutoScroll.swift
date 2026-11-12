import AppKit

/// 长截图的自动滚动：点一下控制条上的按钮就一直开着——鼠标在选区里就匀速、慢慢地往下滚，移出选区就停，
/// 移回来立刻接着滚；直到滚到底、长图到了长度上限，或者再点一次按钮才结束。拼接照常只看画面。
///
/// - 发的是「像触控板一样」的像素滚动（连续、带手势阶段），每秒 60 次、每次几个点，看起来是平滑的匀速滚动。
///   手势很短：鼠标一动就结束、在新位置重新开始，鼠标不动时也每半秒重新开始一次——macOS 把一次手势的滚动
///   都交给手势开始时鼠标下面的那块区域，一次手势拖得很长的话，开始时鼠标若在侧边栏、标题栏上，
///   之后移到正文上也滚不动
/// - 速度偏慢（每秒约三分之一个选区高），相邻两帧只差几个点，拼接最稳
/// - 方向：发出去的像素滚动不受「自然滚动」影响，直接往下滚；万一页面在往回走（拼接看到的滚动距离是负的），反过来
/// - 滚到底：鼠标停在刚才能滚动的同一个位置，页面却一段时间不再动。鼠标移动过（比如移到选区里不能滚动的侧边栏）
///   不算到底，继续开着，等鼠标回到能滚动的地方
/// - 鼠标要在选区里：滚动事件交给鼠标下面的窗口
/// - 给别的 App 发滚动事件需要「辅助功能」权限：只有用自动滚动时才请求，手动滚动完全不需要
@MainActor
final class LongCaptureAutoScroll {
    enum State: Equatable {
        case running
        /// 鼠标不在选区里，暂停
        case paused
        case stopped(Reason)
    }

    enum Reason: Equatable {
        case user, reachedEnd, limit, noPermission
    }

    var onChange: ((State) -> Void)?
    private(set) var state: State = .stopped(.user)

    /// 选区（全局坐标，单位：点，原点在主屏左下角）
    private let region: CGRect
    /// 每秒滚多少点
    private let speed: Double
    private var timer: Timer?
    /// 1：往下滚（滚轮的负方向）；-1：反过来
    private var direction: Double = 1
    private var sawProgress = false
    /// 开始后连续几帧往回走（方向反了）
    private var backwardFrames = 0
    private var carry: Double = 0
    /// 上一次页面往下走的时间，和那时鼠标的位置
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private var progressPointer: CGPoint?
    private var gestureBegan = false
    /// 这次手势开始时鼠标的位置、已经发了几次
    private var gesturePoint = CGPoint.zero
    private var gestureTicks = 0

    /// 调节参数
    enum Tuning {
        /// 每秒滚过选区高度的多少（再限制在下面的范围里）
        static let regionsPerSecond = 0.33
        static let minSpeed = 150.0, maxSpeed = 450.0
        static let ticksPerSecond = 60.0
        /// 鼠标停在能滚动的位置、页面这么久没往下走：滚到底了
        static let stallSeconds = 1.2
        /// 鼠标离开「能滚动的位置」多远算移动过（点）
        static let pointerSlack: CGFloat = 4
        /// 开始后连续几帧往回走，才认为方向反了（偶尔一帧的误差不算）
        static let backwardFrames = 3
        /// 一次手势最多发几次（每秒 60 次，30 次是半秒）；鼠标移动超过几个点就重新开始手势
        static let gestureTicks = 30
        static let gestureMoveSlack: CGFloat = 2
    }

    init(region: CGRect) {
        self.region = region
        speed = min(max(region.height * Tuning.regionsPerSecond, Tuning.minSpeed), Tuning.maxSpeed)
    }

    var isActive: Bool {
        switch state {
        case .running, .paused: true
        case .stopped: false
        }
    }

    /// 开始。没有「辅助功能」权限时请求一次（系统弹出提示），返回 false
    @discardableResult
    func start() -> Bool {
        guard !isActive else { return true }
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            set(.stopped(.noPermission))
            return false
        }
        direction = 1
        sawProgress = false
        backwardFrames = 0
        carry = 0
        lastProgress = ProcessInfo.processInfo.systemUptime
        progressPointer = nil
        set(region.contains(NSEvent.mouseLocation) ? .running : .paused)
        timer = Timer.scheduledTimer(withTimeInterval: 1 / Tuning.ticksPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()   // 鼠标已经在选区里时立刻开始，不等下一拍
        Log.capture.notice("长截图：开始自动滚动，每秒 \(Int(self.speed)) 点")
        return true
    }

    func stop(_ reason: Reason = .user) {
        timer?.invalidate()
        timer = nil
        endGesture()
        if isActive { Log.capture.notice("长截图：自动滚动停止") }
        set(.stopped(reason))
    }

    /// 拼接的反馈：这一帧页面滚动了多少像素（往下为正）
    func noteMotion(_ shift: Int) {
        guard state == .running else { return }
        if shift > 0 {
            sawProgress = true
            backwardFrames = 0
            lastProgress = ProcessInfo.processInfo.systemUptime
            progressPointer = NSEvent.mouseLocation
        } else if shift < 0, !sawProgress {
            backwardFrames += 1
            if backwardFrames >= Tuning.backwardFrames {
                backwardFrames = 0
                flip()
            }
        }
    }

    private func flip() {
        direction = -direction
        endGesture()
        Log.capture.notice("长截图：自动滚动方向反了，改为反向")
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        guard region.contains(mouse) else {
            if state == .running {
                endGesture()
                set(.paused)
            }
            lastProgress = ProcessInfo.processInfo.systemUptime   // 暂停的时间不算「不动」
            return
        }
        if state == .paused { set(.running) }
        let now = ProcessInfo.processInfo.systemUptime
        // 滚到底：鼠标还停在刚才能滚动的位置，页面却一段时间没再往下走
        if let spot = progressPointer, now - lastProgress > Tuning.stallSeconds,
           hypot(mouse.x - spot.x, mouse.y - spot.y) <= Tuning.pointerSlack {
            stop(.reachedEnd)
            return
        }
        // 鼠标移动了、或者这次手势已经够长：结束它，下面在鼠标现在的位置重新开始
        if gestureBegan, gestureTicks >= Tuning.gestureTicks
            || hypot(mouse.x - gesturePoint.x, mouse.y - gesturePoint.y) > Tuning.gestureMoveSlack {
            endGesture()
        }
        carry += speed / Tuning.ticksPerSecond
        let step = Int32(carry)
        guard step > 0 else { return }
        carry -= Double(step)
        post(-step * Int32(direction), at: mouse)
    }

    // 手势阶段（kCGScrollWheelEventScrollPhase 的取值）
    private static let began: Int64 = 1, changed: Int64 = 2, ended: Int64 = 4

    /// 发一次像素滚动给鼠标下面的窗口。amount 正数是往上（和系统滚轮事件一致）。
    /// 不设事件的位置：直接发进系统的事件带了位置，系统会把鼠标指针移过去——
    /// 你移动鼠标时它会被拉回上一帧的位置，来回跳。不设位置就是发生在鼠标现在所在的地方
    private func post(_ amount: Int32, at mouse: CGPoint) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)
        else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: gestureBegan ? Self.changed : Self.began)
        event.post(tap: .cghidEventTap)
        if !gestureBegan {
            gesturePoint = mouse
            gestureTicks = 0
        }
        gestureBegan = true
        gestureTicks += 1
    }

    private func endGesture() {
        guard gestureBegan else { return }
        gestureBegan = false
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)
        else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Self.ended)
        event.post(tap: .cghidEventTap)
    }

    private func set(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onChange?(newState)
    }
}
