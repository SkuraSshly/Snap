import AppKit

extension NSUserInterfaceItemIdentifier {
    /// Velos 的普通窗口（设置、编辑、视频预览、权限引导）：和其他 App 的窗口一样可以被截图、录屏、截屏翻译截到。
    /// 没有这个标识的 Velos 窗口（截图界面、缩略图、录制控件等临时界面）截图时会被排除，见 ScreenFreezer.ownWindows
    static let velosCapturable = NSUserInterfaceItemIdentifier("local.velos.capturable")
}

extension NSWindow {
    /// 普通窗口（设置、权限设置）：跟到你当前所在的桌面打开，全屏 App 上面也能显示
    func followActiveSpace() {
        collectionBehavior.insert(.moveToActiveSpace)
        collectionBehavior.insert(.fullScreenAuxiliary)
    }

    /// 把窗口叫到眼前：最小化了先恢复，请求切到前台并设为当前窗口。
    /// macOS 的激活是「协作式」的，系统不同意时 Velos 切不到前台，普通窗口会被压在别的 App 下面，所以再强制放到最前。
    /// 不设置为一直置顶：之后点别的 App，它照常退到后面
    func bringToFront() {
        if isMiniaturized { deminiaturize(nil) }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}
