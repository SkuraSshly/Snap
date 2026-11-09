import AppKit

/// 把已有的录屏转成 GIF：选一个视频文件，在屏幕角落显示它的缩略图并开始导出（进度显示在缩略图上，GIF 存在视频旁边）
@MainActor
enum GIFConversion {
    static func chooseAndConvert() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.prompt = "转为 GIF"
        panel.message = "选择要转为 GIF 的录屏（GIF 会保存在视频旁边）"
        panel.directoryURL = SaveLocation.directory(for: .recording)
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await ThumbnailManager.shared.showRecording(url, on: nil, exportGIF: true) }
    }
}
