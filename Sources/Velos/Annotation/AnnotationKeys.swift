import AppKit
import Carbon.HIToolbox

/// 方向键：移动标注、截图界面里微调选区都用
enum ArrowKey {
    /// 方向（右、上为正）；不是方向键返回 nil
    static func direction(_ keyCode: UInt16) -> (dx: Int, dy: Int)? {
        switch Int(keyCode) {
        case kVK_LeftArrow: (-1, 0)
        case kVK_RightArrow: (1, 0)
        case kVK_UpArrow: (0, 1)
        case kVK_DownArrow: (0, -1)
        default: nil
        }
    }

    /// 每按一次移动多少：单独按 1，按住 Shift 10；还按着 ⌘ / ⌥ / ⌃ 时不算移动（nil）
    static func step(_ modifiers: NSEvent.ModifierFlags) -> Int? {
        let relevant = modifiers.intersection([.command, .option, .control, .shift])
        guard relevant.subtracting(.shift).isEmpty else { return nil }
        return relevant.contains(.shift) ? 10 : 1
    }
}

extension AnnotationController {
    /// 截图界面和编辑窗口共用的标注编辑按键：Esc（结束文字输入 → 取消选中）、Delete、方向键移动选中的标注、⌘Z / ⇧⌘Z。
    /// 调色盘属于工具栏，由宿主在调用之前先关；退出、完成、保存这些也由宿主处理。
    /// - Returns: true 处理了；false 是标注按键但这次没起作用（宿主应当返回「没处理」）；nil 不是标注按键，交给宿主
    func handleEditingKey(_ event: NSEvent) -> Bool? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape:
            // 正在输入文字时只结束输入（保留文字）；选中了标注时先取消选中；都没有时交给宿主（退出）
            if isEditingText {
                endTextEditing()
                return true
            }
            return deselect() ? true : nil
        case kVK_Delete, kVK_ForwardDelete:
            // 删除选中的标注（⌘Z 可以恢复）
            return deleteSelection()
        case kVK_ANSI_Z where modifiers == .command:
            undo()
            return true
        case kVK_ANSI_Z where modifiers == [.command, .shift]:
            redo()
            return true
        default:
            // 选中了标注：方向键移动 1 点，Shift + 方向键 10 点；按着 ⌘ / ⌥ / ⌃ 时不动
            guard hasSelection, let direction = ArrowKey.direction(event.keyCode) else { return nil }
            guard let step = ArrowKey.step(modifiers) else { return false }
            moveSelection(dx: CGFloat(direction.dx * step), dy: CGFloat(direction.dy * step))
            return true
        }
    }

    /// 改样式：从属性栏当前显示的样式改起（选中标注时显示的是它的样式），改完应用到当前工具或选中的标注
    func updateDisplayedStyle(_ change: (inout AnnotationStyle) -> Void) {
        var newStyle = displayedStyle
        change(&newStyle)
        applyStyle(newStyle)
    }
}
