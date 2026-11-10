import AppKit

extension NSUserInterfaceItemIdentifier {
    /// Velos 的普通窗口（设置、编辑、视频预览、权限引导）：和其他 App 的窗口一样可以被截图、录屏、截屏翻译截到。
    /// 没有这个标识的 Velos 窗口（截图界面、缩略图、录制控件等临时界面）截图时会被排除，见 ScreenFreezer.ownWindows
    static let velosCapturable = NSUserInterfaceItemIdentifier("local.velos.capturable")
}
