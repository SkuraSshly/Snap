import AppKit
import Carbon.HIToolbox

/// 一个快捷键：Carbon 虚拟键码 + Carbon 修饰键。
/// 用 Carbon 的表示是因为全局注册走 RegisterEventHotKey；
/// 截图界面里自己处理按键时，再用 `matches(_:)` 和 NSEvent 比较。
struct Hotkey: Hashable, Codable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultScreenshot = Hotkey(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: UInt32(optionKey))
    static let defaultRecording = Hotkey(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(optionKey))

    /// ⌃⌥⇧⌘ 四个修饰键（Carbon）
    static let modifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers & Self.modifierMask
    }

    /// 从按键事件创建（录制新快捷键时）
    init(event: NSEvent) {
        self = Hotkey(keyCode: UInt32(event.keyCode), carbonModifiers: 0).withCocoaModifiers(event.modifierFlags)
    }

    /// 换成另一组修饰键（Cocoa 表示）
    func withCocoaModifiers(_ flags: NSEvent.ModifierFlags) -> Hotkey {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return Hotkey(keyCode: keyCode, carbonModifiers: modifiers)
    }

    /// 存进设置的形式：[键码, 修饰键]
    var stored: [Int] { [Int(keyCode), Int(carbonModifiers)] }

    init?(stored: [Int]) {
        guard stored.count == 2, stored[0] >= 0, stored[1] >= 0 else { return nil }
        self.init(keyCode: UInt32(stored[0]), carbonModifiers: UInt32(stored[1]))
    }

    /// 修饰键部分的显示文字，例如「⌃⌥」（录制快捷键时实时显示正按着的修饰键）
    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }

    var isFunctionKey: Bool { Self.functionKeyCodes.contains(Int(keyCode)) }

    /// 键盘上是否有这个键的名字（没有名字的键不允许设为快捷键，否则无法显示）
    var hasKnownKey: Bool { Self.keyNames[Int(keyCode)] != nil }

    private static let functionKeyCodes = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                           kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                                           kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    /// 对应的 Cocoa 修饰键
    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// 按键事件是否就是这个快捷键（只比较 ⌃⌥⇧⌘ 四个修饰键，左右 Option 都算 Option）
    func matches(_ event: NSEvent) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        return UInt32(event.keyCode) == keyCode
            && event.modifierFlags.intersection(relevant) == cocoaModifiers
    }

    /// 显示用文字，例如「⌥1」
    var displayString: String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (Self.keyNames[Int(keyCode)] ?? "?")
    }

    /// 键帽样式：修饰键和按键之间加空格，例如「⌥ 1」「⌃ ⌘ F12」
    var spacedDisplayString: String {
        let flags = cocoaModifiers
        let symbols = Self.modifierSymbols(flags).map(String.init)
        return (symbols + [Self.keyNames[Int(keyCode)] ?? "?"]).joined(separator: " ")
    }

    /// 菜单项右侧显示的按键字符（小写）
    var menuKeyEquivalent: String {
        (Self.keyNames[Int(keyCode)] ?? "").lowercased()
    }

    /// 美式键盘布局下的键名（快捷键按物理键位注册，与当前输入法无关）
    private static let keyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_ANSI_Keypad0: "小键盘 0", kVK_ANSI_Keypad1: "小键盘 1", kVK_ANSI_Keypad2: "小键盘 2",
            kVK_ANSI_Keypad3: "小键盘 3", kVK_ANSI_Keypad4: "小键盘 4", kVK_ANSI_Keypad5: "小键盘 5",
            kVK_ANSI_Keypad6: "小键盘 6", kVK_ANSI_Keypad7: "小键盘 7", kVK_ANSI_Keypad8: "小键盘 8",
            kVK_ANSI_Keypad9: "小键盘 9",
        ]
        for (index, code) in functionKeyCodes.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()
}
