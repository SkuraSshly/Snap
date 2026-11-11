import AppKit
import AVKit

/// 录屏预览窗口：单击录屏缩略图打开，用系统播放器（AVPlayerView）播放。
/// 窗口关闭后播放器立即释放，不占内存。
@MainActor
final class VideoPreviewWindowController: NSWindowController, NSWindowDelegate {
    private static var openControllers: [VideoPreviewWindowController] = []

    let url: URL
    private let playerView = AVPlayerView()

    /// 打开（同一个文件已经打开时直接提到最前）
    /// - Parameter videoSize: 视频的显示尺寸（点）
    @discardableResult
    static func show(_ url: URL, videoSize: CGSize, on screen: NSScreen?) -> VideoPreviewWindowController {
        let controller = openControllers.first { $0.url == url } ?? {
            let controller = VideoPreviewWindowController(url: url, videoSize: videoSize,
                                                          screen: screen ?? NSScreen.main ?? NSScreen.screens[0])
            openControllers.append(controller)
            return controller
        }()
        controller.window?.bringToFront()
        controller.playerView.player?.play()
        return controller
    }

    /// 文件被删除时关闭对应的预览
    static func close(for url: URL) {
        openControllers.first { $0.url == url }?.close()
    }

    private init(url: URL, videoSize: CGSize, screen: NSScreen) {
        self.url = url
        // 按视频比例，放进屏幕可用区域的 75% 以内
        let visible = screen.visibleFrame
        let size = videoSize.width > 0 && videoSize.height > 0 ? videoSize : CGSize(width: 16, height: 9)
        let factor = min(visible.width * 0.75 / size.width, visible.height * 0.75 / size.height, 1)
        var content = CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
        if content.width < 480 {
            content = CGSize(width: 480, height: (480 * size.height / size.width).rounded())
        }

        let window = NSWindow(contentRect: CGRect(origin: .zero, size: content),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.identifier = .velosCapturable
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = size
        // 最小宽度 320（按视频比例），免得拖得太小、播放控件挤坏
        window.contentMinSize = CGSize(width: 320, height: (320 * size.height / size.width).rounded())
        window.centerOnScreen()

        playerView.player = AVPlayer(url: url)
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        window.contentView = playerView

        // 标题栏右侧：在访达中显示
        let reveal = NSButton(title: "在访达中显示", image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!,
                              target: nil, action: nil)
        reveal.bezelStyle = .accessoryBarAction
        reveal.controlSize = .small
        reveal.imagePosition = .imageLeading
        let accessory = NSTitlebarAccessoryViewController()
        let container = NSView(frame: CGRect(x: 0, y: 0, width: reveal.fittingSize.width + 12, height: 28))
        reveal.frame = CGRect(x: 0, y: (28 - reveal.fittingSize.height) / 2, width: reveal.fittingSize.width, height: reveal.fittingSize.height)
        container.addSubview(reveal)
        accessory.view = container
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)

        super.init(window: window)
        window.delegate = self
        reveal.target = self
        reveal.action = #selector(revealInFinder)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        playerView.player = nil
        Self.openControllers.removeAll { $0 === self }
    }

    #if DEBUG
    static var debugOpenCount: Int { openControllers.count }
    #endif
}
