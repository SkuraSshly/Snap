import Testing
@testable import Velos

/// 长截图的滚动限速：每一帧最多放行 maxPerFrame，多出来的积压起来按帧补发
@Suite struct ScrollThrottleTests {
    static func make() -> ScrollThrottle {
        ScrollThrottle(maxPerFrame: 100, frameInterval: 0.1, maxPending: 300, now: 0)
    }

    @Test func 触控板一下滚太多时只放行一帧的量其余补发() {
        var throttle = Self.make()
        #expect(throttle.take(250, now: 0) == 100)
        #expect(throttle.drain(now: 0.1) == 100)
        #expect(throttle.drain(now: 0.2) == 50)
        #expect(throttle.drain(now: 0.3) == 0)
    }

    /// 鼠标滚轮：整个放进积压，一点也不直接放行，之后每帧最多补发一帧的量
    @Test func 鼠标滚轮全部按帧补发() {
        var throttle = Self.make()
        throttle.queue(-260, now: 0)
        #expect(throttle.pending == -260)
        #expect(throttle.drain(now: 0.1) == -100)
        #expect(throttle.drain(now: 0.2) == -100)
        #expect(throttle.drain(now: 0.3) == -60)
        #expect(throttle.drain(now: 0.4) == 0)
    }

    @Test func 鼠标滚轮积压有上限反向时清掉() {
        var throttle = Self.make()
        throttle.queue(-200, now: 0)
        throttle.queue(-200, now: 0)
        #expect(throttle.pending == -300)
        throttle.queue(40, now: 0)
        #expect(throttle.pending == 40)
    }
}
