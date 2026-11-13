#if DEBUG
import AppKit

/// 开发调试用（只编进 debug 版本）：把 Velos 自己的窗口画成 PNG，用来检查界面布局。
/// 自己画自己的视图，不需要屏幕录制权限。
/// 用法：VELOS_SNAPSHOT_DIR=/某个目录 build/Velos.app/Contents/MacOS/Velos
@MainActor
enum DebugSnapshots {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["VELOS_SNAPSHOT_DIR"] else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            OnboardingWindowController.show()
            try? await Task.sleep(for: .milliseconds(500))
            snapshot(titled: "Velos 权限设置", to: dir.appendingPathComponent("onboarding.png"))

            for tab in SettingsTab.allCases {
                SettingsWindowController.show(tab)
                try? await Task.sleep(for: .milliseconds(500))
                snapshot(titled: tab.title, to: dir.appendingPathComponent("settings-\(tab.rawValue).png"))
            }
            NSApp.terminate(nil)
        }
    }

    /// 内存自测：设置 VELOS_SELFTEST=N 时自动连续截 N 次全屏（只编码 PNG，不写剪贴板），
    /// 结束后外部用 footprint / malloc_history 检查内存是否回落
    static func runSelfTestIfRequested() {
        guard let count = Int(ProcessInfo.processInfo.environment["VELOS_SELFTEST"] ?? "") else { return }
        ScreenshotOutput.dryRun = true
        ScreenshotOutput.dryRunDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("VelosSelfTest")
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
        if title == "Velos 权限设置" { window.orderOut(nil) }
    }
}
#endif

#if DEBUG
import VelosOCRKit

/// 内存诊断：只跑「语言检测 → Apple 翻译」这条真实流程（不截屏、不弹窗），每一步之后记下内存占用，跑完不退出，
/// 方便用 heap / malloc_history 看是谁申请的内存。
/// 用法：open --env VELOS_MEMORY_PROBE=/输出目录 [--env MallocStackLogging=lite] build/Velos.app
enum DebugMemoryProbe {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["VELOS_MEMORY_PROBE"] else { return }
        let url = URL(fileURLWithPath: path).appendingPathComponent("result.txt")
        Task { @MainActor in
            var lines: [String] = []
            func note(_ step: String) {
                lines.append("\(step)：\(DebugUITest.footprintMB()) MB")
                try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            try? await Task.sleep(for: .seconds(3))
            note("启动后空闲")
            let text = "长截图时只框住要滚动的那一块，接得最稳。\n\n这是第二段，用来测试逐段翻译时的内存占用。"
            let language = LanguageDetector(preferredLanguages: []).detect(text)
            note("语言检测（\(language?.rawValue ?? "无")）")
            if #available(macOS 26.0, *) {
                let status = await AppleTranslator.shared.status(from: .simplifiedChinese, to: .english)
                note("查询语言包（\(status)）")
                if status == .installed {
                    for round in 1...3 {
                        let output = try? await AppleTranslator.shared.translate(text, from: .simplifiedChinese, to: .english)
                        note("第 \(round) 次翻译（\(output?.count ?? -1) 字）")
                    }
                    try? await Task.sleep(for: .seconds(70))
                    note("70 秒后（翻译会话已释放）")
                }
            }
            note("结束（进程保留）")
        }
    }
}
#endif

#if DEBUG
/// 用后内存诊断（只编进 debug 版本）：用合成画面截 3 次图（不截真实屏幕、不用系统剪贴板），
/// 再把设置窗口逐页打开、关闭 4 轮，记录每一步后的内存；最后保留进程，便于用 heap / malloc_history 查看留下的是什么。
/// 用法：open --env VELOS_MEMORY_SHOT=/输出目录 [--env MallocStackLogging=lite] build/Velos.app
@MainActor
enum DebugMemoryShot {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["VELOS_MEMORY_SHOT"] else { return }
        let url = URL(fileURLWithPath: path).appendingPathComponent("result.txt")
        ScreenshotOutput.dryRun = true
        Task { @MainActor in
            var lines: [String] = []
            func note(_ step: String) {
                lines.append("\(step)：\(DebugUITest.footprintMB()) MB")
                try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            }
            try? await Task.sleep(for: .seconds(3))
            note("启动后空闲")
            // 反复截图：VELOS_MEMORY_ROUNDS=次数 时，只反复打开、取消截图界面，看内存会不会随次数一直涨（检查泄漏）
            if let rounds = Int(ProcessInfo.processInfo.environment["VELOS_MEMORY_ROUNDS"] ?? ""), rounds > 0 {
                let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                              context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                              isARepeat: false, keyCode: 53)!
                // VELOS_MEMORY_TRANSLATE=1：改成反复截屏翻译（单击合成桌面上的窗口 → 识别、翻译 → 关掉结果窗口）
                let translate = ProcessInfo.processInfo.environment["VELOS_MEMORY_TRANSLATE"] != nil
                let name = translate ? "截屏翻译" : "截图"
                for round in 1...rounds {
                    CaptureCoordinator.shared.beginScreenshot(purpose: translate ? .translate : .screenshot)
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let session = CaptureCoordinator.shared.debugSession else { note("第 \(round) 次：\(name)没有启动"); break }
                    if translate {
                        let point = DebugUITest.debugPointInWindowA
                        session.overlayMouseMoved(to: point)
                        session.overlayMouseDown(at: point)
                        session.overlayMouseUp(at: point)
                        try? await Task.sleep(for: .seconds(2))
                        ScreenTranslateController.shared.debugCloseAll()
                    } else {
                        _ = session.overlayKeyDown(escape)
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    if round % 5 == 0 { note("反复\(name) \(round) 次后") }
                }
                try? await Task.sleep(for: .seconds(5))
                note("结束（进程保留）")
                return
            }
            let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                         characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            for round in 1...3 {
                CaptureCoordinator.shared.beginScreenshot()
                try? await Task.sleep(for: .milliseconds(600))
                guard let session = CaptureCoordinator.shared.debugSession else { note("第 \(round) 次：截图没有启动"); break }
                note("第 \(round) 次：截图界面打开")
                let point = DebugUITest.debugPointInWindowA
                session.overlayMouseMoved(to: point)
                session.overlayMouseDown(at: point)
                session.overlayMouseUp(at: point)
                _ = session.overlayKeyDown(enter)
                try? await Task.sleep(for: .seconds(1))
                note("第 \(round) 次：完成（缩略图 \(ThumbnailManager.shared.visibleCount) 个）")
                try? await Task.sleep(for: .seconds(8))
                note("第 \(round) 次：8 秒后（缩略图 \(ThumbnailManager.shared.visibleCount) 个）")
            }
            try? await Task.sleep(for: .seconds(60))
            note("60 秒后（缩略图 \(ThumbnailManager.shared.visibleCount) 个）")
            for round in 1...4 {
                for tab in SettingsTab.allCases {
                    SettingsWindowController.show(tab)
                    try? await Task.sleep(for: .seconds(1))
                }
                SettingsWindowController.currentWindow?.close()
                try? await Task.sleep(for: .seconds(10))
                note("第 \(round) 轮设置窗口：逐页打开后关闭 10 秒")
            }
            note("结束（进程保留）")
        }
    }
}
#endif
