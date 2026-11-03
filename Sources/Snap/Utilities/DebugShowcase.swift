#if DEBUG
import AppKit
import ScreenCaptureKit

/// README 用的界面截图（只编进 debug 版本）。
/// - 背景是 Snap 自己画的演示桌面（渐变壁纸 + 几个示意窗口），不读取真实屏幕
/// - 只截取 Snap 自己的窗口（SCContentFilter 的 including 方式），其他 App、通知等不可能出现在图里
/// - 截图界面沿用自测的「合成冻屏」；录屏界面、缩略图、倒计时下面垫一层演示桌面窗口，磨砂虚化的也只是演示桌面
/// 用法：open --env SNAP_SHOWCASE=/输出目录 build/Snap.app（运行约 30 秒，结束后自动退出）
@MainActor
enum DebugShowcase {
    static var outputDir: URL? {
        ProcessInfo.processInfo.environment["SNAP_SHOWCASE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: - 演示桌面

    /// 演示桌面的布局（屏幕内坐标，单位：点，原点在左下角）
    private struct Layout {
        let stage: CGRect
        /// 文档窗口、图表窗口（在前）、便签
        let document: CGRect
        let chart: CGRect
        let note: CGRect

        init(screenSize s: CGSize) {
            let w = min(s.width - 80, 1500), h = min(s.height - 120, 920)
            stage = CGRect(x: ((s.width - w) / 2).rounded(), y: ((s.height - h) / 2).rounded(), width: w, height: h)
            document = CGRect(x: stage.minX + 60, y: stage.minY + 170, width: 780, height: 560)
            chart = CGRect(x: stage.minX + 640, y: stage.minY + 330, width: 700, height: 470)
            note = CGRect(x: stage.maxX - 360, y: stage.minY + 50, width: 300, height: 200)
        }
    }

    private static var cachedDesktop: (image: CGImage, layout: Layout, origin: CGPoint)?

    /// 截图界面自测钩子：用演示桌面代替真实屏幕
    static func syntheticScreen(for screen: NSScreen) -> DebugUITest.Synthetic? {
        guard outputDir != nil, let (image, layout) = desktop(for: screen) else { return nil }
        let o = screen.frame.origin
        let frozen = FrozenDisplay(displayID: screen.displayID, screen: screen, image: image, scale: screen.backingScaleFactor)
        // 窗口识别：前面的在前
        return DebugUITest.Synthetic(frozen: frozen, windows: [layout.chart, layout.note, layout.document].map { $0.offsetBy(dx: o.x, dy: o.y) })
    }

    /// 合成的演示桌面图片（垫在 Snap 窗口后面截图用）
    static func desktopImage(for screen: NSScreen) -> CGImage? { desktop(for: screen)?.0 }

    private static func desktop(for screen: NSScreen) -> (CGImage, Layout)? {
        if let cached = cachedDesktop, cached.origin == screen.frame.origin { return (cached.image, cached.layout) }
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        let layout = Layout(screenSize: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawDesktop(size: size, layout: layout)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.retagging(with: .sRGB)?.cgImage else { return nil }
        cachedDesktop = (image, layout, screen.frame.origin)
        return (image, layout)
    }

    nonisolated private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    private static func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
                             color: NSColor = hex(0x2B2B33), centeredIn width: CGFloat? = nil) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let s = NSAttributedString(string: string, attributes: attributes)
        var p = point
        if let width { p.x += (width - s.size().width) / 2 }
        s.draw(at: p)
    }

    /// 一行「文字」：用圆角灰条示意
    private static func line(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, color: NSColor = hex(0xDADDE5), height: CGFloat = 9) {
        color.setFill()
        NSBezierPath(roundedRect: CGRect(x: x, y: y, width: width, height: height), xRadius: height / 2, yRadius: height / 2).fill()
    }

    /// 示意窗口：白底圆角、标题栏、红黄绿三个按钮、柔和投影
    private static func window(_ frame: CGRect, title: String, background: NSColor = .white) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.22)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        background.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.restoreGraphicsState()

        let bar = CGRect(x: frame.minX, y: frame.maxY - 40, width: frame.width, height: 40)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).addClip()
        hex(0xF3F3F6).setFill()
        bar.fill()
        hex(0xE2E2E8).setFill()
        CGRect(x: frame.minX, y: bar.minY, width: frame.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
        for (i, color) in [hex(0xFF5F57), hex(0xFEBC2E), hex(0x28C840)].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: frame.minX + 16 + CGFloat(i) * 20, y: bar.midY - 6, width: 12, height: 12)).fill()
        }
        text(title, at: CGPoint(x: frame.minX, y: bar.midY - 8), size: 13, weight: .semibold, color: hex(0x55555F), centeredIn: frame.width)
    }

    private static func drawDesktop(size: CGSize, layout: Layout) {
        // 壁纸：蜜桃色到淡紫蓝的渐变 + 几团柔和的光斑
        NSGradient(colors: [hex(0xF8D9C4), hex(0xEBD3E6), hex(0xC9D7F3)])?
            .draw(in: CGRect(origin: .zero, size: size), angle: -35)
        for (center, radius, color) in [(CGPoint(x: size.width * 0.18, y: size.height * 0.8), 420.0, hex(0xF7B48A, 0.35)),
                                        (CGPoint(x: size.width * 0.85, y: size.height * 0.25), 520.0, hex(0xA9C1F2, 0.35)),
                                        (CGPoint(x: size.width * 0.6, y: size.height * 0.9), 300.0, hex(0xF9E2A6, 0.35))] {
            NSGradient(starting: color, ending: color.withAlphaComponent(0))?
                .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
        }

        // 文档窗口
        let d = layout.document
        window(d, title: "周报.md")
        // 侧边栏：按窗口的圆角裁剪，左下角也是圆的
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: d, xRadius: 12, yRadius: 12).addClip()
        hex(0xF7F7FA).setFill()
        CGRect(x: d.minX, y: d.minY, width: 190, height: d.height - 41).fill()
        NSGraphicsContext.restoreGraphicsState()
        hex(0xFDE6D6).setFill()
        NSBezierPath(roundedRect: CGRect(x: d.minX + 12, y: d.maxY - 98, width: 166, height: 28), xRadius: 7, yRadius: 7).fill()
        for (i, width) in [96.0, 120, 84, 110, 72, 100].enumerated() {
            line(d.minX + 28, d.maxY - 88 - CGFloat(i) * 38, width, color: i == 0 ? hex(0xF0A47A) : hex(0xD3D6DE))
        }
        let cx = d.minX + 220
        text("本周进展", at: CGPoint(x: cx, y: d.maxY - 96), size: 24, weight: .bold)
        for (i, width) in [500.0, 470, 520, 300].enumerated() { line(cx, d.maxY - 130 - CGFloat(i) * 22, width) }
        text("待办", at: CGPoint(x: cx, y: d.maxY - 248), size: 17, weight: .semibold)
        for (i, width) in [260.0, 330, 220].enumerated() {
            let y = d.maxY - 280 - CGFloat(i) * 30
            (i == 0 ? hex(0xF5935C) : hex(0xC5C9D3)).setStroke()
            let box = NSBezierPath(roundedRect: CGRect(x: cx, y: y - 3, width: 15, height: 15), xRadius: 4, yRadius: 4)
            box.lineWidth = 2
            box.stroke()
            line(cx + 28, y, width)
        }
        hex(0xFFF3EA).setFill()
        NSBezierPath(roundedRect: CGRect(x: cx, y: d.minY + 40, width: 530, height: 90), xRadius: 10, yRadius: 10).fill()
        hex(0xF5935C).setFill()
        NSBezierPath(roundedRect: CGRect(x: cx, y: d.minY + 40, width: 5, height: 90), xRadius: 2.5, yRadius: 2.5).fill()
        for (i, width) in [440.0, 380, 260].enumerated() { line(cx + 24, d.minY + 102 - CGFloat(i) * 22, width, color: hex(0xF2D4C2)) }

        // 便签
        let n = layout.note
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.18)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        hex(0xFFF2B8).setFill()
        NSBezierPath(roundedRect: n, xRadius: 10, yRadius: 10).fill()
        NSGraphicsContext.restoreGraphicsState()
        text("便签", at: CGPoint(x: n.minX + 22, y: n.maxY - 44), size: 18, weight: .bold, color: hex(0x6B5410))
        text("⌥A  截图", at: CGPoint(x: n.minX + 22, y: n.maxY - 92), size: 20, weight: .semibold, color: hex(0x5A4A1A))
        text("⌥S  录屏", at: CGPoint(x: n.minX + 22, y: n.maxY - 130), size: 20, weight: .semibold, color: hex(0x5A4A1A))
        line(n.minX + 22, n.minY + 30, 180, color: hex(0xEADB97))

        // 图表窗口（在最前）
        let c = layout.chart
        window(c, title: "销售数据")
        text("¥128,400", at: CGPoint(x: c.minX + 32, y: c.maxY - 100), size: 32, weight: .bold)
        text("上半年销售额  ↑ 18%", at: CGPoint(x: c.minX + 34, y: c.maxY - 124), size: 13, color: hex(0x7A7D88))
        hex(0xE6E8EE).setFill()
        for i in 0..<4 { CGRect(x: c.minX + 32, y: c.minY + 110 + CGFloat(i) * 55, width: c.width - 64, height: 1).fill() }
        let heights: [CGFloat] = [90, 120, 105, 150, 135, 190]
        let colors = [hex(0x8AA8F5), hex(0x8AA8F5), hex(0x8AA8F5), hex(0x8AA8F5), hex(0x8AA8F5), hex(0xF5935C)]
        for (i, height) in heights.enumerated() {
            let x = c.minX + chartBarX(i)
            colors[i].setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: c.minY + 110, width: 60, height: height), xRadius: 8, yRadius: 8).fill()
            text("\(i + 1)月", at: CGPoint(x: x, y: c.minY + 84), size: 13, color: hex(0x7A7D88), centeredIn: 60)
        }
        text("备注", at: CGPoint(x: c.minX + 32, y: c.minY + 50), size: 12, weight: .semibold, color: hex(0x7A7D88))
        line(c.minX + 70, c.minY + 54, 380)
        line(c.minX + 70, c.minY + 32, 280)
    }

    /// 图表窗口里第 i 根柱子的左边缘（窗口内坐标）
    private static func chartBarX(_ i: Int) -> CGFloat { 52 + CGFloat(i) * 102 }

    // MARK: - 截取

    /// 截取屏幕上 globalRect（单位：点）。onlySnap 为 true 时只截 Snap 自己的窗口，其他任何内容都不会出现
    private static func captureImage(_ globalRect: CGRect, on screen: NSScreen, onlySnap: Bool) async -> CGImage? {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
        let filter = onlySnap
            ? SCContentFilter(display: display, including: content.windows.filter { $0.owningApplication?.processID == pid })
            : SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        guard let full = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        let f = screen.frame
        let rect = globalRect.intersection(f)
        let crop = CGRect(x: (rect.minX - f.minX) * scale, y: (f.maxY - rect.maxY) * scale,
                          width: rect.width * scale, height: rect.height * scale).integral
        return full.cropping(to: crop)
    }

    private static func save(_ image: CGImage, _ name: String, _ dir: URL) {
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }

    /// 只截 Snap 自己的窗口
    private static func capture(_ globalRect: CGRect, on screen: NSScreen, name: String, dir: URL) async {
        if let image = await captureImage(globalRect, on: screen, onlySnap: true) { save(image, name, dir) }
    }

    private static var verifyLog: [String] = []

    /// 演示桌面窗口垫底的画面：「只截 Snap 窗口」时磨砂效果可能与屏幕上不完全一样，
    /// 所以再截一张屏幕上的真实合成画面，与前者逐像素比较——
    /// 任何像素相差都不超过 40（说明没有其他 App、通知等内容混进来）才采用真实画面，否则用只含 Snap 窗口的那张
    private static func captureVerified(_ globalRect: CGRect, on screen: NSScreen, name: String, dir: URL) async {
        guard let own = await captureImage(globalRect, on: screen, onlySnap: true) else { return }
        guard let real = await captureImage(globalRect, on: screen, onlySnap: false),
              let (maxDiff, changed) = difference(own, real) else {
            save(own, name, dir)
            verifyLog.append("\(name)：真实画面截取失败，采用只含 Snap 窗口的截图")
            return
        }
        let safe = maxDiff <= 40
        save(safe ? real : own, name, dir)
        if safe { save(own, "own-" + name, dir) }   // 两种方式都留着，便于对比
        verifyLog.append("\(name)：最大差值 \(maxDiff)，差值超过 12 的像素 \(changed)，" + (safe ? "采用真实画面" : "有其他内容，采用只含 Snap 窗口的截图"))
    }

    /// 两张同尺寸图片逐像素比较：最大通道差值、差值超过 12 的像素数
    private static func difference(_ a: CGImage, _ b: CGImage) -> (Int, Int)? {
        guard a.width == b.width, a.height == b.height else { return nil }
        func pixels(_ image: CGImage) -> [UInt8]? {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            guard let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        guard let pa = pixels(a), let pb = pixels(b) else { return nil }
        var maxDiff = 0, changed = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            let d = max(abs(Int(pa[i]) - Int(pb[i])), abs(Int(pa[i + 1]) - Int(pb[i + 1])), abs(Int(pa[i + 2]) - Int(pb[i + 2])))
            maxDiff = max(maxDiff, d)
            if d > 12 { changed += 1 }
        }
        return (maxDiff, changed)
    }

    /// 单独截取一个 Snap 窗口（设置窗口）
    static func captureWindow(_ window: NSWindow, name: String, dir: URL) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }

    /// 垫在录屏界面、缩略图下面的演示桌面窗口（只给截图用，鼠标可以穿透）
    static func makeBackdrop(for screen: NSScreen, image: CGImage, level: NSWindow.Level) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = level
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = .resize
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    // MARK: - 设置窗口实拍

    /// 只拍设置窗口（用 ScreenCaptureKit 拍 Snap 自己的窗口，能看到真实的毛玻璃和模糊效果）。
    /// 窗口后面垫一张合成的演示桌面，毛玻璃透出来的只有它，不会拍到真实屏幕内容。
    /// 用法：open --env SNAP_SETTINGS_SHOTS=/输出目录 [--env SNAP_SETTINGS_DARK=1] build/Snap.app
    static func runSettingsShotsIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["SNAP_SETTINGS_SHOTS"] else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        let dark = ProcessInfo.processInfo.environment["SNAP_SETTINGS_DARK"] != nil
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard let screen = NSScreen.main, let (image, _) = desktop(for: screen) else { return }
            let backdrop = makeBackdrop(for: screen, image: image, level: .normal)
            for tab in SettingsTab.allCases {
                SettingsWindowController.show(tab)
                try? await Task.sleep(for: .milliseconds(800))
                if let window = NSApp.windows.first(where: { $0.title == tab.title && $0.isVisible }) {
                    await captureWindow(window, name: "settings-\(tab.rawValue)\(dark ? "-dark" : "").png", dir: dir)
                    // 内容超过一屏的页面：再拍一张滚到底的
                    if let scroll = Self.firstScrollView(in: window.contentView),
                       let document = scroll.documentView, document.frame.height > scroll.contentView.bounds.height + 1 {
                        let bottom = document.isFlipped ? document.frame.height - scroll.contentView.bounds.height : 0
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        try? await Task.sleep(for: .milliseconds(400))
                        await captureWindow(window, name: "settings-\(tab.rawValue)-bottom\(dark ? "-dark" : "").png", dir: dir)
                    }
                }
            }
            // 权限设置（独立窗口时）
            OnboardingWindowController.show()
            try? await Task.sleep(for: .milliseconds(800))
            if let window = OnboardingWindowController.debugWindow {
                await captureWindow(window, name: "onboarding\(dark ? "-dark" : "").png", dir: dir)
            }
            backdrop.close()
            NSApp.terminate(nil)
        }
    }

    private static func firstScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews { if let found = firstScrollView(in: subview) { return found } }
        return nil
    }

    // MARK: - 拍摄

    static func runIfRequested() {
        guard let dir = outputDir else { return }
        ScreenshotOutput.dryRun = true
        ScreenshotOutput.dryRunDirectory = dir.appendingPathComponent("output", isDirectory: true)
        NSApp.appearance = NSAppearance(named: .aqua)   // 统一用浅色外观
        // 录制选项条上展示「声音、麦克风、指针都打开」的样子，拍完恢复原来的设置
        let prefs = Preferences.shared
        let saved = (prefs.recordSystemAudio, prefs.recordMicrophone, prefs.recordingShowsCursor)
        (prefs.recordSystemAudio, prefs.recordMicrophone, prefs.recordingShowsCursor) = (true, true, true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            await run(dir: dir)
            (prefs.recordSystemAudio, prefs.recordMicrophone, prefs.recordingShowsCursor) = saved
            ToolStyleMemory.debugCleanUp()
            try? verifyLog.joined(separator: "\n").write(to: dir.appendingPathComponent("verify.txt"), atomically: true, encoding: .utf8)
            Log.capture.notice("界面截图拍摄完成")
            NSApp.terminate(nil)
        }
    }

    private static func run(dir: URL) async {
        guard let screen = NSScreen.underMouse, let (image, layout) = desktop(for: screen) else { return }
        let o = screen.frame.origin
        func g(_ r: CGRect) -> CGRect { r.offsetBy(dx: o.x, dy: o.y) }
        func gp(_ base: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + base.minX + x, y: o.y + base.minY + y) }
        let chart = layout.chart, document = layout.document
        let coordinator = CaptureCoordinator.shared

        // 1. 截图：悬停识别窗口 + 放大镜 + 提示条
        coordinator.beginScreenshot()
        try? await Task.sleep(for: .milliseconds(600))
        guard let session = coordinator.debugSession else { return }
        let hover = gp(chart, chartBarX(3) + 60, 200)   // 第 4 根柱子的右边缘：放大镜里能看到像素级的边界
        session.overlayMouseMoved(to: hover)
        try? await Task.sleep(for: .milliseconds(400))
        var area = g(layout.stage)
        if let hint = session.debugHintFrame { area = area.union(hint) }
        await capture(area.insetBy(dx: -20, dy: -20), on: screen, name: "1-screenshot-select.png", dir: dir)

        // 2. 截图：单击选中图表窗口，画上标注
        session.overlayMouseDown(at: hover)
        session.overlayMouseUp(at: hover)
        func drag(_ a: CGPoint, _ b: CGPoint) {
            session.overlayMouseDown(at: a)
            session.overlayMouseDragged(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
            session.overlayMouseDragged(to: b)
            session.overlayMouseUp(at: b)
        }
        func click(_ p: CGPoint) { session.overlayMouseDown(at: p); session.overlayMouseUp(at: p) }
        var style = AnnotationStyle()
        style.color = AnnotationPalette.colors[0]
        style.size = .medium
        session.debugSetStyle(style)
        let june = chartBarX(5)
        session.debugSelectTool(.mosaic)
        drag(gp(chart, 66, 22), gp(chart, 466, 66))
        session.debugSelectTool(.rectangle)
        drag(gp(chart, june - 12, 98), gp(chart, june + 72, 314))
        session.debugSelectTool(.arrow)
        drag(gp(chart, 470, 340), gp(chart, june - 18, 286))
        session.debugSelectTool(.text)
        click(gp(chart, 330, 372))
        session.debugAnnotator?.debugType("6 月创新高")
        session.debugAnnotator?.debugTextView?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        session.debugSelectTool(.counter)
        click(gp(chart, 250, 386))
        click(gp(chart, 486, 44))
        session.debugSelectTool(.rectangle)   // 展开颜色 / 粗细栏
        try? await Task.sleep(for: .milliseconds(500))
        let bar = session.debugToolbar
        var annotated = g(chart)
        if let host = bar.superview, let window = host.window {
            annotated = annotated.union(window.convertToScreen(host.convert(bar.frame, to: nil)))
        }
        await capture(annotated.insetBy(dx: -40, dy: -40), on: screen, name: "2-screenshot-annotate.png", dir: dir)

        // 3. 缩略图：完成截图 → 截图缩略图；再放一张录屏缩略图（封面用演示桌面里的文档窗口）
        let backdrop = makeBackdrop(for: screen, image: image, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1))
        session.debugComplete()
        try? await Task.sleep(for: .milliseconds(600))
        let scale = screen.backingScaleFactor
        let f = screen.frame
        let posterRect = CGRect(x: (document.minX) * scale, y: (f.height - document.maxY) * scale,
                                width: document.width * scale, height: document.height * scale)
        if let poster = image.cropping(to: posterRect) {
            ThumbnailManager.shared.debugShowRecording(poster: poster, videoSize: document.size, duration: 83, on: screen)
        }
        try? await Task.sleep(for: .milliseconds(500))
        ThumbnailManager.shared.debugHoverNewest()
        try? await Task.sleep(for: .milliseconds(300))
        let thumbnails = ThumbnailManager.shared.debugFrames.reduce(CGRect.null) { $0.union($1) }
        if !thumbnails.isNull {
            await captureVerified(thumbnails.insetBy(dx: -60, dy: -50), on: screen, name: "3-thumbnails.png", dir: dir)
        }
        ThumbnailManager.shared.debugDismissAll()
        try? await Task.sleep(for: .milliseconds(400))

        // 4. 录屏选区：框出文档窗口，下方是录制选项条
        coordinator.beginRecording()
        try? await Task.sleep(for: .milliseconds(600))
        if let recording = coordinator.debugRecordingSession {
            let r = g(document)
            recording.overlayMouseDown(at: CGPoint(x: r.minX, y: r.minY))
            recording.overlayMouseDragged(to: CGPoint(x: r.midX, y: r.midY))
            recording.overlayMouseDragged(to: CGPoint(x: r.maxX, y: r.maxY))
            recording.overlayMouseUp(at: CGPoint(x: r.maxX, y: r.maxY))
            try? await Task.sleep(for: .milliseconds(500))
            var area = g(layout.stage)
            let options = recording.debugOptionsBar
            if let window = options.window {
                area = area.union(window.convertToScreen(options.convert(options.bounds, to: nil)))
            }
            await capture(area.insetBy(dx: -20, dy: -20), on: screen, name: "4-recording-select.png", dir: dir)
            recording.cancel()
        }
        try? await Task.sleep(for: .milliseconds(400))

        // 5. 录制中：红框 + 浮动控制条 + 点击高亮（没有真的开始录制）
        let manager = RecordingManager.shared
        let region = g(document)
        let frameWindow = RecordingFrameWindow(region: region, screen: screen, isFullScreen: false)
        frameWindow.orderFrontRegardless()
        manager.debugElapsedOverride = 12
        let controlBar = RecordingControlBar(manager: manager)
        controlBar.place(near: region, on: screen, isFullScreen: false)
        controlBar.orderFrontRegardless()
        let highlighter = ClickHighlighter(screen: screen)
        highlighter.handle(.leftMouseDown, at: gp(document, 300, 278))
        try? await Task.sleep(for: .milliseconds(400))
        await captureVerified(region.union(controlBar.debugBarFrame).insetBy(dx: -40, dy: -40), on: screen, name: "5-recording-controls.png", dir: dir)
        highlighter.handle(.leftMouseUp, at: gp(document, 300, 278))
        highlighter.stop()
        controlBar.close()
        manager.debugElapsedOverride = nil

        // 6. 倒计时
        let countdown = RecordingCountdown(seconds: 3, region: region, hotkey: coordinator.recordingHotkey) { _ in }
        countdown.run()
        try? await Task.sleep(for: .milliseconds(400))
        await captureVerified(region.insetBy(dx: -40, dy: -40), on: screen, name: "6-countdown.png", dir: dir)
        countdown.finish(.cancelled)
        frameWindow.close()
        backdrop.close()

        // 7. 设置窗口
        for (tab, name) in [(SettingsTab.recording, "7-settings-recording.png"), (.hotkeys, "8-settings-hotkeys.png"),
                            (.general, "9-settings-general.png")] {
            SettingsWindowController.show(tab)
            try? await Task.sleep(for: .milliseconds(700))
            if let window = NSApp.windows.first(where: { $0.title == tab.title && $0.isVisible }) {
                await captureWindow(window, name: name, dir: dir)
            }
        }
    }
}
#endif
