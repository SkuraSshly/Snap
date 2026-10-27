#if DEBUG
import AppKit

/// 开发调试用（只编进 debug 版本）：把 Snap 自己的窗口画成 PNG，用来检查界面布局。
/// 自己画自己的视图，不需要屏幕录制权限。
/// 用法：SNAP_SNAPSHOT_DIR=/某个目录 build/Snap.app/Contents/MacOS/Snap
@MainActor
enum DebugSnapshots {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["SNAP_SNAPSHOT_DIR"] else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            OnboardingWindowController.show()
            try? await Task.sleep(for: .milliseconds(500))
            snapshot(titled: "Snap 权限设置", to: dir.appendingPathComponent("onboarding.png"))

            for tab in SettingsTab.allCases {
                SettingsWindowController.show(tab)
                try? await Task.sleep(for: .milliseconds(500))
                snapshot(titled: tab.title, to: dir.appendingPathComponent("settings-\(tab.rawValue).png"))
            }
            NSApp.terminate(nil)
        }
    }

    /// 内存自测：设置 SNAP_SELFTEST=N 时自动连续截 N 次全屏（只编码 PNG，不写剪贴板），
    /// 结束后外部用 footprint / malloc_history 检查内存是否回落
    static func runSelfTestIfRequested() {
        guard let count = Int(ProcessInfo.processInfo.environment["SNAP_SELFTEST"] ?? "") else { return }
        ScreenshotOutput.dryRun = true
        ScreenshotOutput.dryRunDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SnapSelfTest")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            for _ in 0..<count {
                CaptureCoordinator.shared.beginScreenshot()
                try? await Task.sleep(for: .milliseconds(700))
                CaptureCoordinator.shared.debugSession?.toggleMode()
                CaptureCoordinator.shared.debugSession?.debugComplete()
                try? await Task.sleep(for: .milliseconds(700))
            }
            Log.capture.notice("自测完成：\(count) 次截图")
        }
    }

    /// 把遮罩（底图 + 蒙版 + 边框 + 提示条 + 放大镜）画成 PNG，供界面自测检查
    static func renderOverlay(_ view: NSView?, to url: URL) {
        guard let view, let layer = view.layer else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func snapshot(titled title: String, to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }),
              let view = window.contentView?.superview ?? window.contentView else {
            print("未找到窗口：\(title)")
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("\(title)：窗口 \(Int(window.frame.width))×\(Int(window.frame.height)) → \(url.lastPathComponent)")
        // 用 orderOut 而不是 close：不触发 windowWillClose，不会把「已完成首次引导」写进设置
        if title == "Snap 权限设置" { window.orderOut(nil) }
    }
}
#endif
