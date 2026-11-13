import Combine
import Foundation
import Testing
@testable import Velos

/// 截屏翻译「等译文出来」不再轮询，改成跟着状态变化等（TranslationModel.waitUntilSettled 的做法）：
/// 状态变成「有结果」时立刻结束；等待中的任务被取消（又开始了新的截屏翻译、关了窗口）时也立刻结束，不会一直挂着
@MainActor
@Suite struct TranslationWaitTests {
    /// 带一个 @Published 状态的模型（和 TranslationModel 一样），等待用的是 TranslationModel 里真正的那段代码
    @MainActor final class Model: ObservableObject {
        @Published var status = TranslationModel.Status.idle
        func waitUntilSettled() async { await TranslationModel.waitUntilSettled($status) }
    }

    @Test func 已经有结果时立刻返回() async {
        let model = Model()
        model.status = .done
        await model.waitUntilSettled()
    }

    @Test func 状态变成有结果时结束() async throws {
        let model = Model()
        model.status = .translating
        let waiter = Task { await model.waitUntilSettled(); return true }
        try await Task.sleep(for: .milliseconds(50))
        model.status = .translating   // 还在翻：继续等
        try await Task.sleep(for: .milliseconds(50))
        model.status = .done
        #expect(await waiter.value)
    }

    @Test func 等待中被取消时立刻结束() async throws {
        let model = Model()
        model.status = .translating
        let started = ContinuousClock.now
        let waiter = Task { await model.waitUntilSettled() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await waiter.value
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(model.status == .translating)   // 状态没变，是取消让它结束的
    }
}
