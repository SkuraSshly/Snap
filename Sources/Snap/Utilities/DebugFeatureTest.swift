#if DEBUG
import AppKit
import AVFoundation
import Carbon.HIToolbox
import ImageIO

/// 第 8 阶段功能自测（只编进 debug 版本）：快捷键自定义与冲突检测、3 秒倒计时、点击高亮、GIF 导出、
/// 隐藏菜单栏图标、录屏缩略图开关。
/// - 测试中临时修改的设置在结束时全部恢复
/// - 点击高亮的画面核对只读取 Snap 自己画的钉图和圆圈所在位置的像素，不读取屏幕上的其他内容
/// - 录到的视频和 GIF 只核对参数，核对完立即删除
/// 用法：open --env SNAP_FEATURETEST=/输出目录 build/Snap.app
@MainActor
enum DebugFeatureTest {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["SNAP_FEATURETEST"] else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        RecordingManager.debugOutputDirectory = dir
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let check = DebugUITest.Checks()
            let prefs = Preferences.shared
            // 记下会被临时修改的设置
            let saved = (prefs.recordingCountdown, prefs.highlightClicks, prefs.recordingShowThumbnail, prefs.recordingShowsCursor,
                         prefs.recordSystemAudio, prefs.recordMicrophone, prefs.showMenuBarIcon, prefs.screenshotHotkey,
                         prefs.recordingHotkey, prefs.gifFrameRate, prefs.gifMaxWidth)
            ThumbnailManager.shared.pasteboard = NSPasteboard(name: .init("local.snap.selftest"))
            prefs.recordSystemAudio = false
            prefs.recordMicrophone = false

            testStaleFileCleanup(check)
            testHotkeys(check)
            await testHotkeyRecorder(check, dir: dir)
            // SNAP_FEATURETEST_ONLY=hotkeys：只测快捷键（不弹出选区、不录制，不打扰正在使用电脑的人）
            if ProcessInfo.processInfo.environment["SNAP_FEATURETEST_ONLY"] != "hotkeys" {
                testMenuBarIcon(check)
                await testCountdown(check, dir: dir)
                await testClickHighlightAndGIF(check, dir: dir)
            }

            // 恢复设置
            (prefs.recordingCountdown, prefs.highlightClicks, prefs.recordingShowThumbnail, prefs.recordingShowsCursor,
             prefs.recordSystemAudio, prefs.recordMicrophone, prefs.showMenuBarIcon) = (saved.0, saved.1, saved.2, saved.3, saved.4, saved.5, saved.6)
            _ = CaptureCoordinator.shared.setHotkey(saved.7, for: .screenshot)
            _ = CaptureCoordinator.shared.setHotkey(saved.8, for: .recording)
            (prefs.gifFrameRate, prefs.gifMaxWidth) = (saved.9, saved.10)
            ThumbnailManager.shared.pasteboard = .general
            check("测试修改的设置已全部恢复", prefs.screenshotHotkey == saved.7 && prefs.recordingHotkey == saved.8
                  && prefs.showMenuBarIcon == saved.6 && prefs.recordingCountdown == saved.0)

            try? check.lines.joined(separator: "\n").write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            Log.capture.notice("功能自测完成：\(check.lines.filter { $0.hasPrefix("✓") }.count)/\(check.lines.count) 通过")
        }
    }

    private static func key(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "", window: Int = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }

    private static func hk(_ code: Int, _ modifiers: Int) -> Hotkey {
        Hotkey(keyCode: UInt32(code), carbonModifiers: UInt32(modifiers))
    }

    // MARK: - 临时文件清理

    /// 只清理一天前的拖拽临时文件，新的保留（用测试自己写的两个空文件验证，不碰其他文件）
    private static func testStaleFileCleanup(_ check: DebugUITest.Checks) {
        let manager = FileManager.default
        let directory = CapturedImage.sharingDirectory
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent("selftest-old.png")
        let fresh = directory.appendingPathComponent("selftest-fresh.png")
        manager.createFile(atPath: old.path, contents: Data())
        manager.createFile(atPath: fresh.path, contents: Data())
        try? manager.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 3600)], ofItemAtPath: old.path)
        CapturedImage.removeStaleSharingFiles()
        check("启动清理：删除一天前的拖拽临时文件，保留新的", !manager.fileExists(atPath: old.path) && manager.fileExists(atPath: fresh.path))
        try? manager.removeItem(at: fresh)
    }

    // MARK: - 快捷键

    private static func testHotkeys(_ check: DebugUITest.Checks) {
        let coordinator = CaptureCoordinator.shared
        func problem(_ hotkey: Hotkey, _ action: HotkeyManager.Action = .screenshot) -> String? {
            HotkeyConflicts.problem(with: hotkey, for: action)
        }
        check("冲突检测：没有修饰键的普通键被拒绝", problem(hk(kVK_ANSI_A, 0)) != nil)
        check("冲突检测：只有 ⇧ 被拒绝", problem(hk(kVK_ANSI_A, shiftKey)) != nil)
        check("冲突检测：F13 可以单独使用", problem(hk(kVK_F13, 0)) == nil, problem(hk(kVK_F13, 0)) ?? "")
        let copy = problem(hk(kVK_ANSI_C, cmdKey)) ?? ""
        check("冲突检测：⌘C 是常用编辑快捷键", copy.contains("编辑快捷键"), copy)
        let other = problem(hk(kVK_ANSI_2, optionKey), .screenshot) ?? ""
        check("冲突检测：与录屏快捷键 ⌥2 相同", other.contains("录屏"), other)
        if HotkeyConflicts.systemShortcutName(for: hk(kVK_ANSI_3, cmdKey | shiftKey)) != nil {
            let system = problem(hk(kVK_ANSI_3, cmdKey | shiftKey)) ?? ""
            check("冲突检测：⇧⌘3 与系统「截取整个屏幕」冲突", system.contains("截取整个屏幕"), system)
        }
        let original = coordinator.screenshotHotkey
        check("同一个动作重新设成原来的快捷键不算冲突", coordinator.setHotkey(original, for: .screenshot) == nil)

        // 改成 ⌃⌥⌘J：注册、保存、菜单显示都跟着变
        let custom = hk(kVK_ANSI_J, controlKey | optionKey | cmdKey)
        let result = coordinator.setHotkey(custom, for: .screenshot)
        check("设置新快捷键 ⌃⌥⌘J", result == nil, result ?? "")
        check("新快捷键已保存并注册", Preferences.shared.screenshotHotkey == custom
              && HotkeyManager.shared.hotkey(for: .screenshot) == custom && !HotkeyManager.shared.failedActions.contains(.screenshot))
        check("显示文字：⌃⌥⌘J / ⌃ ⌥ ⌘ J", custom.displayString == "⌃⌥⌘J" && custom.spacedDisplayString == "⌃ ⌥ ⌘ J",
              custom.spacedDisplayString)
        let titles = StatusBarController.debugCurrent?.debugMenuTitles ?? []
        check("菜单里多了「将录屏转为 GIF…」", titles.contains("将录屏转为 GIF…"), "\(titles)")
        // 冲突时保留原来的快捷键
        _ = coordinator.setHotkey(hk(kVK_ANSI_V, cmdKey), for: .screenshot)
        check("冲突时保留原来的快捷键", Preferences.shared.screenshotHotkey == custom)
        check("恢复默认 ⌥1", coordinator.setHotkey(.defaultScreenshot, for: .screenshot) == nil
              && Preferences.shared.screenshotHotkey == .defaultScreenshot)
        check("快捷键存储格式可还原", Hotkey(stored: custom.stored) == custom)
    }

    /// 在真实的「设置 › 快捷键」窗口里模拟点击和按键：事件交给窗口分发（⌘ 组合键先走 performKeyEquivalent，与系统一致），
    /// 不要求设置窗口成为焦点窗口（正在使用其他 App 时，macOS 不允许别的 App 抢焦点）。
    /// 系统快捷键在系统层面被拦截、不会到达 App，这一步测试无法重现，
    /// 只能模拟「只收到修饰键 / 只收到松开 / 窗口失去焦点」这几种被拦截后 App 实际能看到的情况。
    private static func testHotkeyRecorder(_ check: DebugUITest.Checks, dir: URL) async {
        SettingsWindowController.show(.hotkeys)
        try? await Task.sleep(for: .milliseconds(800))
        func fields(in view: NSView?) -> [HotkeyRecorderField] {
            guard let view else { return [] }
            return (view as? HotkeyRecorderField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        guard let window = NSApp.windows.first(where: { $0.title == "快捷键" && $0.isVisible }),
              let field = fields(in: window.contentView).first else { return check("打开设置 › 快捷键", false) }
        let model = HotkeySettingsModel.shared
        let prefs = Preferences.shared
        let registered = HotkeyManager.shared.debugRegisteredCount

        func click() {
            let point = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
        }
        func send(_ type: NSEvent.EventType, _ code: Int, _ flags: NSEvent.ModifierFlags, _ chars: String = "") {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
            // 与 NSApplication 一样：按下先给窗口一次处理快捷键的机会，没人处理再交给第一响应者
            if type == .keyDown, window.performKeyEquivalent(with: event) { return }
            window.sendEvent(event)
        }

        // 1. 点击进入录制，全局快捷键暂停
        click()
        check("点击快捷键框进入录制，全局快捷键暂停", field.isRecording && HotkeyManager.shared.debugRegisteredCount == 0)

        // 2. ⌘C：走 performKeyEquivalent 路径，被冲突检测拒绝
        send(.keyDown, kVK_ANSI_C, .command, "c")
        let copyMessage = model.messages[.screenshot] ?? ""
        check("按 ⌘C：提示是常用编辑快捷键，快捷键不变", copyMessage.contains("编辑快捷键") && prefs.screenshotHotkey == .defaultScreenshot
              && !field.isRecording && HotkeyManager.shared.debugRegisteredCount == registered, copyMessage)

        // 3. ⌃⌥S：设置成功，提示清除
        click()
        check("再次点击时清除上一次的提示", model.messages[.screenshot] == nil)
        send(.keyDown, kVK_ANSI_S, [.control, .option], "s")
        check("按 ⌃⌥S：设置成功", prefs.screenshotHotkey == hk(kVK_ANSI_S, controlKey | optionKey) && model.messages[.screenshot] == nil)

        // 4. 系统吞掉按键，只收到修饰键：⌘⇧ 按下又松开
        click()
        send(.flagsChanged, kVK_Command, .command)
        send(.flagsChanged, kVK_Shift, [.command, .shift])
        send(.flagsChanged, kVK_Shift, .command)
        send(.flagsChanged, kVK_Command, [])
        let swallowed = model.messages[.screenshot] ?? ""
        check("只收到修饰键：说明被系统占用，并列出 ⇧⌘3 等系统快捷键", swallowed.contains("没有收到按键") && swallowed.contains("⇧⌘3（截取整个屏幕）")
              && field.isRecording, swallowed)
        // 布局图：提示文字较长，确认没有被截断
        try? await Task.sleep(for: .milliseconds(300))
        if let view = window.contentView?.superview ?? window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("snap-快捷键提示.png"))
        }

        // 5. 系统吞掉按下、只收到松开：按 ⇧⌘3 处理，冲突检测指出是哪个系统快捷键
        send(.flagsChanged, kVK_Command, .command)
        send(.flagsChanged, kVK_Shift, [.command, .shift])
        send(.keyUp, kVK_ANSI_3, [.command, .shift], "#")
        let keyUpMessage = model.messages[.screenshot] ?? ""
        check("只收到松开：识别为 ⇧⌘3 并提示与「截取整个屏幕」冲突", keyUpMessage.contains("⇧⌘3") && keyUpMessage.contains("截取整个屏幕")
              && !field.isRecording && prefs.screenshotHotkey == hk(kVK_ANSI_S, controlKey | optionKey), keyUpMessage)
        send(.flagsChanged, kVK_Command, [])

        // 6. 按住修饰键时窗口失去焦点（如 ⌘⇧5 弹出系统截屏工具栏）
        click()
        send(.flagsChanged, kVK_Command, .command)
        send(.flagsChanged, kVK_Shift, [.command, .shift])
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        check("按住修饰键时窗口失去焦点：结束录制并说明原因", !field.isRecording && (model.messages[.screenshot] ?? "").contains("没有收到按键")
              && HotkeyManager.shared.debugRegisteredCount == registered)

        // 7. Esc 取消
        click()
        send(.keyDown, kVK_Escape, [], "\u{1b}")
        check("Esc 取消录制，快捷键不变", !field.isRecording && prefs.screenshotHotkey == hk(kVK_ANSI_S, controlKey | optionKey))

        // 8. 恢复默认
        model.record(.defaultScreenshot, for: .screenshot)
        check("恢复默认 ⌥1", prefs.screenshotHotkey == .defaultScreenshot)
        window.close()
    }

    // MARK: - 菜单栏图标

    private static func testMenuBarIcon(_ check: DebugUITest.Checks) {
        guard let bar = StatusBarController.debugCurrent else { return check("菜单栏控制器", false) }
        Preferences.shared.showMenuBarIcon = false
        check("隐藏菜单栏图标：图标被移除", !bar.debugHasStatusItem)
        Preferences.shared.showMenuBarIcon = true
        check("重新显示菜单栏图标", bar.debugHasStatusItem)
    }

    // MARK: - 倒计时

    /// 打开录屏选区并拖出一块区域（屏幕左下角 100,100 起 200×150）
    private static func selectRegion() async -> (RecordingSelectionSession, CGRect)? {
        guard let screen = NSScreen.underMouse else { return nil }
        let o = screen.frame.origin
        CaptureCoordinator.shared.beginRecording()
        try? await Task.sleep(for: .milliseconds(600))
        guard let session = CaptureCoordinator.shared.debugRecordingSession else { return nil }
        session.overlayMouseDown(at: CGPoint(x: o.x + 100, y: o.y + 100))
        session.overlayMouseDragged(to: CGPoint(x: o.x + 200, y: o.y + 180))
        session.overlayMouseDragged(to: CGPoint(x: o.x + 300, y: o.y + 250))
        session.overlayMouseUp(at: CGPoint(x: o.x + 300, y: o.y + 250))
        return (session, CGRect(x: o.x + 100, y: o.y + 100, width: 200, height: 150))
    }

    private static func testCountdown(_ check: DebugUITest.Checks, dir: URL) async {
        let manager = RecordingManager.shared
        let prefs = Preferences.shared
        prefs.recordingCountdown = true

        // 1. Esc 取消
        guard let (session, region) = await selectRegion() else { return check("打开录屏选区", false) }
        _ = session.overlayKeyDown(key(kVK_Return))
        try? await Task.sleep(for: .milliseconds(300))
        guard let countdown = manager.debugCountdown else { return check("Enter 后出现倒计时", false) }
        check("Enter 后出现 3 秒倒计时，红框已出现", manager.state == .countingDown && countdown.isVisible
              && countdown.debugNumber == "3" && manager.debugFrameWindow?.isVisible == true)
        check("倒计时卡片在录制区域中央", abs(countdown.frame.midX - region.midX) < 1 && abs(countdown.frame.midY - region.midY) < 1)
        // 布局图（离屏绘制：磨砂只画出暖色底，不包含后面的屏幕画面）
        DebugSnapshots.renderOverlay(countdown.contentView, to: dir.appendingPathComponent("snap-倒计时.png"))
        try? await Task.sleep(for: .milliseconds(1000))
        check("1 秒后显示 2", countdown.debugNumber == "2", countdown.debugNumber)
        countdown.keyDown(with: key(kVK_Escape))
        try? await Task.sleep(for: .milliseconds(300))
        check("Esc 取消：没有开始录制，选区和红框都关闭", manager.state == .idle && manager.debugFrameWindow == nil
              && CaptureCoordinator.shared.debugRecordingSession == nil && !countdown.isVisible)

        // 2. 录屏快捷键取消
        guard let (session2, _) = await selectRegion() else { return check("打开录屏选区", false) }
        _ = session2.overlayKeyDown(key(kVK_Return))
        try? await Task.sleep(for: .milliseconds(300))
        manager.debugCountdown?.keyDown(with: key(kVK_ANSI_2, .option, "™"))
        try? await Task.sleep(for: .milliseconds(300))
        check("倒计时中按录屏快捷键取消", manager.state == .idle)

        // 3. 完整倒数 3 秒后开始录制；关闭缩略图开关，停止后不出现缩略图
        prefs.recordingShowThumbnail = false
        guard let (session3, _) = await selectRegion() else { return check("打开录屏选区", false) }
        let start = Date()
        _ = session3.overlayKeyDown(key(kVK_Return))
        while manager.state != .recording, Date().timeIntervalSince(start) < 6 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let waited = Date().timeIntervalSince(start)
        check("倒数结束后开始录制（等待 \(String(format: "%.1f", waited)) 秒）", manager.isRecording && waited > 2.9 && waited < 4)
        try? await Task.sleep(for: .milliseconds(800))
        CaptureCoordinator.shared.handleHotkey(.recording)
        try? await Task.sleep(for: .milliseconds(1200))
        check("关闭「显示缩略图」后，停止录制不出现缩略图", manager.state == .idle && ThumbnailManager.shared.debugNewestVideoURL == nil)
        if let url = manager.debugLastOutput { try? FileManager.default.removeItem(at: url) }
        prefs.recordingShowThumbnail = true

        // 4. Enter 跳过倒计时
        guard let (session4, _) = await selectRegion() else { return check("打开录屏选区", false) }
        _ = session4.overlayKeyDown(key(kVK_Return))
        try? await Task.sleep(for: .milliseconds(200))
        manager.debugCountdown?.keyDown(with: key(kVK_Return))
        try? await Task.sleep(for: .milliseconds(900))
        check("倒计时中按 Enter 立即开始", manager.isRecording, "\(manager.state)")
        CaptureCoordinator.shared.handleHotkey(.recording)
        try? await Task.sleep(for: .milliseconds(1500))
        ThumbnailManager.shared.debugDismissAll()
        if let url = manager.debugLastOutput { try? FileManager.default.removeItem(at: url) }
        prefs.recordingCountdown = false
    }

    // MARK: - 点击高亮 + GIF

    /// 在录制区域放一张灰色钉图（钉图会被录进视频），在它中间模拟点击，
    /// 然后从视频里读出钉图中心的颜色：点击前是灰色，按下时混入杏色
    private static func testClickHighlightAndGIF(_ check: DebugUITest.Checks, dir: URL) async {
        let manager = RecordingManager.shared
        let prefs = Preferences.shared
        prefs.highlightClicks = true
        prefs.recordingShowsCursor = false   // 不让鼠标指针碰巧挡住采样点

        guard let screen = NSScreen.underMouse else { return }
        let scale = screen.backingScaleFactor
        let region = CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 200, height: 150)
        guard let context = CGContext(data: nil, width: Int(200 * scale), height: Int(150 * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return }
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let gray = context.makeImage(), let pin = PinManager.shared.pin(CapturedImage(image: gray, scale: scale, sourceRect: region)) else {
            return check("放置测试钉图", false)
        }
        try? await Task.sleep(for: .milliseconds(300))

        guard let (session, _) = await selectRegion() else { return check("打开录屏选区", false) }
        _ = session.overlayKeyDown(key(kVK_Return))
        try? await Task.sleep(for: .milliseconds(1500))
        guard let highlighter = manager.debugHighlighter else {
            pin.close()
            return check("打开「高亮鼠标点击」后录制时出现高亮层", false)
        }
        check("高亮层盖住整个屏幕且不拦截鼠标", highlighter.debugWindow.frame == screen.frame && highlighter.debugWindow.ignoresMouseEvents)
        let center = CGPoint(x: region.midX, y: region.midY)
        try? await Task.sleep(for: .milliseconds(500))
        let beforeTime = manager.elapsed
        highlighter.handle(.leftMouseDown, at: center)
        check("按下时出现圆圈", highlighter.debugLayerCount == 1)
        try? await Task.sleep(for: .milliseconds(400))
        let pressTime = manager.elapsed
        try? await Task.sleep(for: .milliseconds(200))
        highlighter.handle(.leftMouseUp, at: center)
        try? await Task.sleep(for: .milliseconds(700))
        check("松开后圆圈扩散消失", highlighter.debugLayerCount == 0, "\(highlighter.debugLayerCount)")
        highlighter.handle(.leftMouseDown, at: CGPoint(x: -99_999, y: -99_999))
        check("屏幕外的点击不显示", highlighter.debugLayerCount == 0)
        try? await Task.sleep(for: .milliseconds(300))
        CaptureCoordinator.shared.handleHotkey(.recording)
        try? await Task.sleep(for: .milliseconds(1500))
        check("停止后高亮层关闭", manager.debugHighlighter == nil && !highlighter.debugWindow.isVisible)
        pin.close()

        guard let video = manager.debugLastOutput else { return check("录屏文件", false) }
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        func centerColor(at seconds: Double) async -> (r: Int, g: Int, b: Int)? {
            guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
            // 只取画面正中间 2×2 像素（钉图中心）
            let cx = image.width / 2, cy = image.height / 2
            guard let crop = image.cropping(to: CGRect(x: cx - 1, y: cy - 1, width: 2, height: 2)) else { return nil }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
        }
        let before = await centerColor(at: max(0.05, beforeTime - 0.2))
        let pressed = await centerColor(at: pressTime)
        let beforeText = before.map { "(\($0.r),\($0.g),\($0.b))" } ?? "无"
        let pressedText = pressed.map { "(\($0.r),\($0.g),\($0.b))" } ?? "无"
        check("钉图被录进视频（点击前中心是灰色 \(beforeText)）",
              before.map { abs($0.r - $0.b) < 12 && abs($0.r - 128) < 30 } ?? false)
        check("点击高亮被录进视频（按下时中心偏杏色 \(pressedText)）",
              pressed.map { $0.r - $0.b > 25 } ?? false)

        // GIF：在录屏缩略图上点「GIF」
        prefs.gifFrameRate = .fps15
        prefs.gifMaxWidth = .w960
        let thumbnails = ThumbnailManager.shared
        guard let view = thumbnails.debugNewestView, thumbnails.debugNewestVideoURL == video else {
            return check("录屏缩略图", false)
        }
        thumbnails.debugHoverNewest()
        check("录屏缩略图悬停出现「导出为 GIF」", view.debugVisibleButtons.contains("导出为 GIF"), "\(view.debugVisibleButtons)")
        let exportStart = Date()
        view.onGIF?()
        // 布局图：录制区域被 Snap 自己的灰色钉图盖住，封面里只有钉图和点击圆圈
        DebugSnapshots.renderOverlay(view, to: dir.appendingPathComponent("snap-GIF导出中.png"))
        check("导出中显示进度，只保留关闭按钮", thumbnails.debugNewestIsExporting && view.debugStatusText?.contains("GIF") == true
              && view.debugVisibleButtons == ["关闭"], "\(view.debugStatusText ?? "无") \(view.debugVisibleButtons)")
        var gifURL: URL?
        while Date().timeIntervalSince(exportStart) < 20 {
            try? await Task.sleep(for: .milliseconds(100))
            if let newest = thumbnails.debugNewestVideoURL, newest.pathExtension == "gif" { gifURL = newest; break }
        }
        let exportTime = Date().timeIntervalSince(exportStart)
        guard let gifURL else { return check("GIF 导出完成", false) }
        thumbnails.debugHoverNewest()
        try? await Task.sleep(for: .milliseconds(200))
        DebugSnapshots.renderOverlay(thumbnails.debugNewestView, to: dir.appendingPathComponent("snap-GIF缩略图.png"))
        check("GIF 导出完成，缩略图换成 GIF（\(String(format: "%.1f", exportTime)) 秒）", FileManager.default.fileExists(atPath: gifURL.path)
              && gifURL.deletingPathExtension().lastPathComponent == video.deletingPathExtension().lastPathComponent)
        let videoDuration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        if let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) {
            let count = CGImageSourceGetCount(source)
            var total = 0.0
            for i in 0..<count {
                let gif = (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any])?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
                total += (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double) ?? 0
            }
            let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
            let expectedWidth = min(Int(200 * scale), 960)
            check("GIF 可被系统正常读取：\(count) 帧，时长 \(String(format: "%.2f", total)) 秒（视频 \(String(format: "%.2f", videoDuration)) 秒）",
                  count > 0 && abs(total - videoDuration) < 0.15)
            check("GIF 尺寸 \(first?.width ?? 0)×\(first?.height ?? 0)", first?.width == expectedWidth)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: gifURL.path)[.size] as? Int) ?? 0
        Log.capture.notice("GIF 文件 \(size / 1024) KB")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".partial") }) ?? []
        check("没有遗留临时文件", leftovers.isEmpty, "\(leftovers)")

        // 导出中关闭 = 取消，不留下 GIF
        thumbnails.debugDismissAll()
        try? FileManager.default.removeItem(at: gifURL)
        await thumbnails.showRecording(video, on: screen, exportGIF: true)
        try? await Task.sleep(for: .milliseconds(30))
        let cancelling = thumbnails.debugNewestIsExporting
        thumbnails.debugDismissAll()
        try? await Task.sleep(for: .milliseconds(800))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        check("导出中关闭缩略图即取消，不留下 GIF 和临时文件", cancelling && !files.contains { $0.hasSuffix(".gif") || $0.hasSuffix(".partial") },
              "\(files)")

        try? FileManager.default.removeItem(at: video)
        check("自测文件已删除", ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0 != "result.txt" && !$0.hasPrefix("snap-") }.isEmpty)
    }
}
#endif
