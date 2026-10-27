import AppKit
import Carbon.HIToolbox

/// 快捷键冲突检测：设置新快捷键前依次检查
/// 1. 必须带 ⌘ / ⌥ / ⌃ 之一（F1–F20 可以单独使用）
/// 2. 不能与 Snap 的另一个快捷键相同
/// 3. 不能占用常用的编辑快捷键（⌘C、⌘V、⌘Z…），否则所有 App 里的这些快捷键都会失效
/// 4. 不能与 macOS 已启用的系统快捷键相同（系统设置 › 键盘 › 键盘快捷键）
/// 5. 系统必须允许注册（被其他程序独占时注册会失败）
///
/// 说明：其他 App 用普通方式注册的全局快捷键，macOS 没有提供查询接口，无法提前发现；
/// 这种情况下后注册的一方生效。
@MainActor
enum HotkeyConflicts {
    /// 返回问题描述；nil 表示可以使用
    static func problem(with hotkey: Hotkey, for action: HotkeyManager.Action) -> String? {
        let modifiers = hotkey.carbonModifiers
        let strong = UInt32(cmdKey | optionKey | controlKey)
        if !hotkey.hasKnownKey {
            return "不支持这个按键，请换一个。"
        }
        if modifiers & strong == 0 && !hotkey.isFunctionKey {
            return "需要包含 ⌘、⌥ 或 ⌃ 之一（只有 F1–F20 可以单独使用）。"
        }
        let other: HotkeyManager.Action = action == .screenshot ? .recording : .screenshot
        if hotkey == CaptureCoordinator.shared.hotkey(for: other) {
            return "\(hotkey.displayString) 已经是「\(other.title)」的快捷键。"
        }
        if reservedEditing.contains(hotkey) {
            return "\(hotkey.displayString) 是常用的编辑快捷键，设为全局快捷键后所有 App 里的 \(hotkey.displayString) 都会失效。"
        }
        if let name = systemShortcutName(for: hotkey) {
            return "\(hotkey.displayString) 与 macOS 系统快捷键「\(name)」冲突。可以换一个，或先在 系统设置 › 键盘 › 键盘快捷键 里关掉它。"
        }
        // 先把自己的旧绑定让出来再试（同一个动作重新设成原来的组合键时不算冲突）
        if hotkey != CaptureCoordinator.shared.hotkey(for: action), !HotkeyManager.shared.canRegister(hotkey) {
            return "\(hotkey.displayString) 已被其他程序占用。"
        }
        return nil
    }

    // MARK: - 常用编辑快捷键

    private static let reservedEditing: Set<Hotkey> = {
        let cmd = UInt32(cmdKey), cmdShift = UInt32(cmdKey | shiftKey)
        var set = Set<Hotkey>()
        let letters = [kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_Q, kVK_ANSI_W,
                       kVK_ANSI_S, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_T, kVK_ANSI_F, kVK_ANSI_H,
                       kVK_ANSI_M, kVK_ANSI_Comma, kVK_ANSI_Grave, kVK_Tab, kVK_Space]
        for code in letters { set.insert(Hotkey(keyCode: UInt32(code), carbonModifiers: cmd)) }
        set.insert(Hotkey(keyCode: UInt32(kVK_ANSI_Z), carbonModifiers: cmdShift))   // 重做
        set.insert(Hotkey(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | optionKey | shiftKey)))   // 粘贴并匹配样式
        set.insert(Hotkey(keyCode: UInt32(kVK_Tab), carbonModifiers: cmdShift))
        return set
    }()

    // MARK: - 系统快捷键

    /// 常见系统快捷键的名字（其余的统称「系统快捷键」）
    private static let knownSystemNames: [Hotkey: String] = {
        let cmd = UInt32(cmdKey), ctrl = UInt32(controlKey), cmdShift = UInt32(cmdKey | shiftKey)
        return [
            Hotkey(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: cmdShift): "截取整个屏幕",
            Hotkey(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: cmdShift): "截取所选区域",
            Hotkey(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: cmdShift): "截屏和录屏选项",
            Hotkey(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: cmdShift | ctrl): "将屏幕拷贝到剪贴板",
            Hotkey(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: cmdShift | ctrl): "将所选区域拷贝到剪贴板",
            Hotkey(keyCode: UInt32(kVK_Space), carbonModifiers: cmd): "聚焦搜索",
            Hotkey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | optionKey)): "访达搜索",
            Hotkey(keyCode: UInt32(kVK_Space), carbonModifiers: ctrl): "切换输入法",
            Hotkey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey)): "切换输入法",
            Hotkey(keyCode: UInt32(kVK_UpArrow), carbonModifiers: ctrl): "调度中心",
            Hotkey(keyCode: UInt32(kVK_DownArrow), carbonModifiers: ctrl): "应用程序窗口",
            Hotkey(keyCode: UInt32(kVK_LeftArrow), carbonModifiers: ctrl): "切换到左边的桌面",
            Hotkey(keyCode: UInt32(kVK_RightArrow), carbonModifiers: ctrl): "切换到右边的桌面",
        ]
    }()

    /// 已启用的系统快捷键里有没有这个组合；有则返回名字
    static func systemShortcutName(for hotkey: Hotkey) -> String? {
        enabledSystemShortcuts().contains(hotkey) ? (knownSystemNames[hotkey] ?? "系统快捷键") : nil
    }

    /// 修饰键正好是 modifiers 的已启用系统快捷键（录制时按键被系统吞掉，用来提示哪些组合不能用）。
    /// 有名字的排在前面，其次按键名排序
    static func systemShortcuts(with modifiers: NSEvent.ModifierFlags) -> [(hotkey: Hotkey, name: String?)] {
        let target = Hotkey(keyCode: 0, carbonModifiers: 0).withCocoaModifiers(modifiers).carbonModifiers
        return enabledSystemShortcuts()
            .filter { $0.carbonModifiers == target && $0.hasKnownKey }
            .map { (hotkey: $0, name: knownSystemNames[$0]) }
            .sorted { ($0.name == nil ? 1 : 0, $0.hotkey.displayString) < ($1.name == nil ? 1 : 0, $1.hotkey.displayString) }
    }

    /// 系统设置 › 键盘 › 键盘快捷键 里已启用的快捷键
    private static func enabledSystemShortcuts() -> Set<Hotkey> {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr,
              let list = array?.takeRetainedValue() as? [[String: Any]] else { return [] }
        var result = Set<Hotkey>()
        for item in list {
            guard item[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let code = item[kHISymbolicHotKeyCode as String] as? Int,
                  let modifiers = item[kHISymbolicHotKeyModifiers as String] as? Int,
                  code >= 0, code < 0xFFFF, modifiers >= 0 else { continue }
            result.insert(Hotkey(keyCode: UInt32(code), carbonModifiers: UInt32(modifiers)))
        }
        return result
    }
}

extension HotkeyManager.Action {
    var title: String { self == .screenshot ? "截图" : "录屏" }
}
