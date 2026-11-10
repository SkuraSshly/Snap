import Carbon.HIToolbox
import Testing
@testable import Velos

/// 快捷键冲突检查：各个动作现在的快捷键、能不能注册都由调用方提供，这里用固定的值测
@MainActor
@Suite struct HotkeyConflictTests {
    static let assigned: [HotkeyManager.Action: Hotkey] = [
        .screenshot: .defaultScreenshot, .recording: .defaultRecording, .translate: .defaultTranslate,
    ]

    func problem(_ hotkey: Hotkey, for action: HotkeyManager.Action = .screenshot, canRegister: Bool = true) -> String? {
        HotkeyConflicts.problem(with: hotkey, for: action, assigned: { Self.assigned[$0]! }, canRegister: { _ in canRegister })
    }

    static func key(_ code: Int, _ modifiers: Int) -> Hotkey { Hotkey(keyCode: UInt32(code), carbonModifiers: UInt32(modifiers)) }

    @Test func 没有修饰键或只有Shift被拒绝() {
        #expect(problem(Self.key(kVK_ANSI_A, 0)) != nil)
        #expect(problem(Self.key(kVK_ANSI_A, shiftKey)) != nil)
    }

    @Test func 和其他动作重复时说明是哪个动作() {
        let text = problem(.defaultTranslate, for: .screenshot) ?? ""
        #expect(text.contains(HotkeyManager.Action.translate.title))
    }

    @Test func 设回自己原来的组合键不算冲突() {
        #expect(problem(.defaultScreenshot, for: .screenshot, canRegister: false) == nil)
    }

    @Test func 常用编辑快捷键被拒绝() {
        #expect(problem(Self.key(kVK_ANSI_C, cmdKey))?.contains("常用的编辑快捷键") == true)
    }

    @Test func 被其他程序占用时说明() {
        #expect(problem(Self.key(kVK_ANSI_J, optionKey | controlKey), canRegister: false)?.contains("已被其他程序占用") == true)
        #expect(problem(Self.key(kVK_ANSI_J, optionKey | controlKey), canRegister: true) == nil)
    }
}

@Suite struct DurationFormatTests {
    @Test func 分秒和时分秒() {
        #expect(DurationFormat.clock(0) == "00:00")
        #expect(DurationFormat.clock(65.9) == "01:05")
        #expect(DurationFormat.clock(3600 + 61) == "1:01:01")
        #expect(DurationFormat.clock(-3) == "00:00")
    }
}
