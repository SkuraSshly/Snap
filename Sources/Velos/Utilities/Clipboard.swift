import AppKit

/// Velos 读写剪贴板时用哪一个：复制译文、缩略图「拷贝文件」、取色器读颜色代码。
/// 正式版里一直是系统剪贴板；自测时换成私有剪贴板，不读写用户的剪贴板。
/// （截图结果和拷贝颜色在自测的「演练模式」下另有私有剪贴板，见 ScreenshotOutput.dryRun）
enum Clipboard {
    nonisolated(unsafe) static var target = NSPasteboard.general
}
