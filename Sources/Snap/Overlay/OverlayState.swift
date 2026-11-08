import AppKit

/// 选区的两种模式（截图和录屏共用）
enum CaptureMode {
    case region
    case fullscreen

    mutating func toggle() {
        self = (self == .region) ? .fullscreen : .region
    }
}

/// 某一块屏幕上遮罩需要显示的内容（坐标均为该遮罩视图自己的坐标，单位：点）
struct OverlayState {
    enum RegionStyle {
        /// 用户拖出的选区：细边框 + 8 个控制点
        case selection
        /// 鼠标悬停识别出的窗口：粗边框，没有控制点
        case window
    }

    var mode: CaptureMode = .region
    /// 鼠标是否在这块屏幕上（全屏模式下只高亮这一块）
    var isActiveScreen = false
    /// 区域模式下高亮的区域（选区或识别出的窗口）
    var region: CGRect?
    var regionStyle: RegionStyle = .selection
    /// 区域的像素尺寸（用于显示「1280 × 720」）
    var regionPixelSize: CGSize?
}

/// 遮罩窗口把鼠标、键盘事件转交给会话处理（坐标统一为 AppKit 全局坐标）
@MainActor
protocol OverlayEventHandler: AnyObject {
    func overlayMouseDown(at point: NSPoint)
    func overlayMouseDragged(to point: NSPoint)
    func overlayMouseUp(at point: NSPoint)
    func overlayMouseMoved(to point: NSPoint)
    func overlayRightMouseDown(at point: NSPoint)
    /// 返回 true 表示已处理
    func overlayKeyDown(_ event: NSEvent) -> Bool
    /// 是否要抢在文字输入框之前处理这个按键（⌥A 切换模式、⌘S 保存，输入文字时也要生效）
    func overlayShouldIntercept(_ event: NSEvent) -> Bool
    func overlayDidResignKey()
    /// 该位置应显示的鼠标指针（控制点上是调整大小箭头，选区内是手形等）
    func overlayCursor(at point: NSPoint) -> NSCursor
}

/// 截图界面、录屏界面、截屏翻译的强调色：都取自温暖的主题配色
enum OverlayAccent {
    /// 截图：主题的杏色（选区边框、控制点、标注的控制点、长截图的边框、选中的钉图）
    static let screenshot = WarmPalette.apricot
    /// 录屏：主题的珊瑚红
    static let recording = WarmPalette.coral
    /// 截屏翻译：鼠尾草绿（设置界面里用的那种柔和的绿），和截图、录屏一眼区分开，又同属温暖的配色
    static let translate = NSColor(srgbRed: 0.45, green: 0.70, blue: 0.47, alpha: 1)
}
