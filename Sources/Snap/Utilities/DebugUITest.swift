#if DEBUG
import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SnapOCRKit

/// 截图界面自动化自测（只编进 debug 版本）。
/// 用合成图代替真实屏幕（不读取用户屏幕内容），再用模拟的鼠标、键盘事件走一遍所有交互，自动核对结果。
/// 用法：open --env SNAP_UITEST=/输出目录 build/Snap.app
@MainActor
enum DebugUITest {
    private static var outputDir: URL? {
        ProcessInfo.processInfo.environment["SNAP_UITEST"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// 合成画面中两个「窗口」的位置（屏幕内坐标，单位：点）：B 在前，部分遮住 A
    private static let windowA = CGRect(x: 200, y: 200, width: 600, height: 400)
    private static let windowB = CGRect(x: 500, y: 300, width: 500, height: 300)
    private static let colorB = SRGBColor(red: 0xCC, green: 0x66, blue: 0x33)
    private static var screenOrigin = CGPoint.zero
    /// 截屏翻译自测：在窗口 A 露出来的部分写两行字（其余自测用不到文字）
    private static var drawsText = false
    private static let textRect = CGRect(x: 220, y: 440, width: 260, height: 120)

    struct Synthetic {
        let frozen: FrozenDisplay
        let windows: [CGRect]
    }

    /// 生成合成屏幕：灰色渐变背景、两个纯色「窗口」、一块 1 像素黑白棋盘格（检验放大镜是否锐利）
    static func syntheticScreen(for screen: NSScreen) -> Synthetic? {
        if let showcase = DebugShowcase.syntheticScreen(for: screen) { return showcase }   // README 截图用的演示桌面
        guard outputDir != nil else { return nil }
        let scale = screen.backingScaleFactor
        let width = Int(screen.frame.width * scale), height = Int(screen.frame.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let gradient = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0.85, alpha: 1), CGColor(gray: 0.55, alpha: 1)] as CFArray, locations: nil)!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        ctx.scaleBy(x: scale, y: scale)   // 之后按「点」绘制（CGContext 原点在左下角，与 AppKit 一致）
        ctx.setFillColor(SRGBColor(red: 0x33, green: 0x66, blue: 0xCC).cgColor)
        ctx.fill(windowA)
        ctx.setFillColor(colorB.cgColor)
        ctx.fill(windowB)
        if drawsText {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .medium),
                                                             .foregroundColor: NSColor.white]
            ("Snap translate test" as NSString).draw(at: CGPoint(x: textRect.minX + 10, y: textRect.minY + 70), withAttributes: attributes)
            ("截屏翻译自测" as NSString).draw(at: CGPoint(x: textRect.minX + 10, y: textRect.minY + 25), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.scaleBy(x: 1 / scale, y: 1 / scale)
        for y in 0..<64 { for x in 0..<64 {
            ctx.setFillColor(CGColor(gray: (x + y) % 2 == 0 ? 0 : 1, alpha: 1))
            ctx.fill(CGRect(x: Int(100 * scale) + x, y: Int(700 * scale) + y, width: 1, height: 1))
        } }
        guard let image = ctx.makeImage() else { return nil }

        screenOrigin = screen.frame.origin
        let frozen = FrozenDisplay(displayID: screen.displayID, screen: screen, image: image, scale: scale)
        return Synthetic(frozen: frozen, windows: [windowB, windowA].map { $0.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y) })
    }

    static func runIfRequested() {
        guard let dir = outputDir else { return }
        ScreenshotOutput.dryRun = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            CaptureCoordinator.shared.beginScreenshot()
            try? await Task.sleep(for: .milliseconds(500))
            guard let session = CaptureCoordinator.shared.debugSession else {
                return report(["✗ 截图会话没有启动"], to: dir)
            }
            await run(session, dir: dir)
        }
    }

    private static func run(_ session: ScreenshotSession, dir: URL) async {
        let check = Checks()
        let selector = session.debugSelector
        let o = screenOrigin
        func g(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x, y: o.y + y) }
        func local(_ r: CGRect?) -> CGRect? { r?.offsetBy(dx: -o.x, dy: -o.y) }
        func render(_ label: String) {
            DebugSnapshots.renderOverlay(session.debugActiveOverlay, to: dir.appendingPathComponent("\(label).png"))
        }
        func key(_ code: Int, _ shift: Bool = false, _ chars: String = "") -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                             timestamp: 0, windowNumber: 0, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
        }
        func drag(from a: CGPoint, to b: CGPoint) {
            session.overlayMouseDown(at: a)
            session.overlayMouseDragged(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
            session.overlayMouseDragged(to: b)
            session.overlayMouseUp(at: b)
        }

        // 1. 悬停识别窗口：只露出 A 的地方识别为 A，B 上识别为 B（B 在前）
        session.overlayMouseMoved(to: g(300, 300))
        check("悬停识别后面的窗口 A", local(selector.hoveredWindow) == windowA, "\(String(describing: local(selector.hoveredWindow)))")
        session.overlayMouseMoved(to: g(700, 450))
        check("悬停识别前面的窗口 B", local(selector.hoveredWindow) == windowB, "\(String(describing: local(selector.hoveredWindow)))")
        check("悬停时显示放大镜", session.debugMagnifierVisible)
        render("1-悬停窗口B")
        try? await Task.sleep(for: .milliseconds(200))
        if let hintFrame = session.debugHintFrame {
            await captureComposite(around: hintFrame.insetBy(dx: -20, dy: -16), to: dir.appendingPathComponent("0-提示条实际显示.png"))
        }
        // 真实合成结果：等窗口服务器把这一帧画到屏幕上，再截取放大镜附近的区域
        try? await Task.sleep(for: .milliseconds(300))
        Log.capture.notice("图层顺序：\(session.debugLayerOrder, privacy: .public)")
        if let frame = session.debugMagnifierFrame {
            await captureComposite(around: frame.insetBy(dx: -40, dy: -40), to: dir.appendingPathComponent("1b-屏幕实际显示.png"))
        }

        // 2. 放大镜颜色：B 的颜色
        session.overlayMouseMoved(to: g(700, 450))
        _ = session.overlayKeyDown(key(kVK_ANSI_C, false, "c"))
        let copied = NSPasteboard(name: .init("local.snap.selftest")).string(forType: .string)
        check("C 复制颜色值", copied == colorB.hex, "得到 \(copied ?? "nil")")

        // 3. 放大镜放在棋盘格上，检查锐利度（看图）
        session.overlayMouseMoved(to: g(132, 732))
        render("2-放大镜棋盘格")

        // 4. 单击窗口 A → 选中 A
        session.overlayMouseMoved(to: g(300, 300))
        session.overlayMouseDown(at: g(300, 300))
        session.overlayMouseUp(at: g(300, 300))
        check("单击选中窗口", local(selector.selection) == windowA, "\(String(describing: local(selector.selection)))")
        check("有选区后隐藏放大镜", !session.debugMagnifierVisible)
        render("3-选中窗口A")

        // 5. 拖右下角控制点：右移 50、下移 30
        drag(from: g(800, 200), to: g(850, 170))
        check("右下角控制点调整", local(selector.selection) == CGRect(x: 200, y: 170, width: 650, height: 430),
              "\(String(describing: local(selector.selection)))")

        // 6. 拖左边框：右移 20
        drag(from: g(200, 400), to: g(220, 400))
        check("拖左边框调整", local(selector.selection) == CGRect(x: 220, y: 170, width: 630, height: 430),
              "\(String(describing: local(selector.selection)))")

        // 7. 拖选区内部移动
        drag(from: g(400, 400), to: g(430, 390))
        check("拖动移动选区", local(selector.selection) == CGRect(x: 250, y: 160, width: 630, height: 430),
              "\(String(describing: local(selector.selection)))")

        // 8. 拖出屏幕外：限制在屏幕内
        drag(from: g(400, 400), to: g(-5000, -5000))
        check("移动时限制在屏幕内", local(selector.selection)?.origin == .zero, "\(String(describing: local(selector.selection)))")

        // 9. 方向键微调：→ 1 像素，Shift+↑ 10 像素
        let scale = session.debugScale
        _ = session.overlayKeyDown(key(kVK_RightArrow))
        _ = session.overlayKeyDown(key(kVK_UpArrow, true))
        let expected = CGPoint(x: 1 / scale, y: 10 / scale)
        check("方向键微调 1px / Shift 10px", local(selector.selection)?.origin == expected,
              "期望 \(expected)，得到 \(String(describing: local(selector.selection)?.origin))")

        // 10. 越过对边拖控制点：自动翻转
        // 把左上角控制点拖到原右下角再往外 100 点：左右、上下都越过对边
        let before = selector.selection!
        drag(from: CGPoint(x: before.minX, y: before.maxY), to: CGPoint(x: before.maxX + 100, y: before.minY + 20))
        let flipped = selector.selection ?? .zero
        check("控制点越过对边时翻转", abs(flipped.minX - before.maxX) < 0.01 && abs(flipped.width - 100) < 0.01,
              "原 \(before)，得到 \(flipped)")

        // 11. 右键清除选区，回到窗口识别
        session.overlayRightMouseDown(at: g(300, 300))
        check("右键清除选区", selector.selection == nil && local(selector.hoveredWindow) == windowA)

        // 12. 拖出新选区：拖拽中显示放大镜
        session.overlayMouseDown(at: g(100, 100))
        session.overlayMouseDragged(to: g(200, 180))
        check("拖拽中显示放大镜", session.debugMagnifierVisible)
        render("4-拖拽中")
        session.overlayMouseDragged(to: g(300, 250))
        session.overlayMouseUp(at: g(300, 250))
        check("拖出新选区", local(selector.selection) == CGRect(x: 100, y: 100, width: 200, height: 150),
              "\(String(describing: local(selector.selection)))")
        render("5-选区与控制点")
        try? await Task.sleep(for: .milliseconds(200))
        await captureComposite(around: CGRect(x: g(60, 60).x, y: g(60, 60).y, width: 300, height: 240),
                               to: dir.appendingPathComponent("5b-选区与尺寸标签实际显示.png"))

        // 13. 切到全屏再切回来，选区保留
        session.toggleMode()
        session.toggleMode()
        check("全屏切回区域后保留选区", local(selector.selection) == CGRect(x: 100, y: 100, width: 200, height: 150))
        if ProcessInfo.processInfo.environment["SNAP_UITEST_PAUSE"] != nil {
            Log.capture.notice("自测暂停，便于检查内存")
            try? await Task.sleep(for: .seconds(10))
        }

        // ===== 第 5 阶段：标注 =====
        await runAnnotationChecks(session, dir: dir, check: check, g: g, key: key, render: render)

        // 14. Enter 完成：输出尺寸 = 选区 × 缩放倍数
        let outputDir = dir.appendingPathComponent("output", isDirectory: true)
        ScreenshotOutput.dryRunDirectory = outputDir
        _ = session.overlayKeyDown(key(kVK_Return))
        try? await Task.sleep(for: .milliseconds(400))
        check("Enter 完成并退出", CaptureCoordinator.shared.debugSession == nil)

        // ===== 第 4 阶段：输出 =====
        // Enter 默认不自动保存：只复制 + 显示缩略图
        try? await Task.sleep(for: .milliseconds(800))
        let expectedPixels = CGSize(width: Int(200 * scale), height: Int(150 * scale))
        check("Enter 不自动保存文件", pngFiles(in: outputDir).isEmpty, "\(pngFiles(in: outputDir).map(\.lastPathComponent))")
        check("显示缩略图", ThumbnailManager.shared.visibleCount == 1, "当前 \(ThumbnailManager.shared.visibleCount) 个")
        check("缩略图显示为未保存", ThumbnailManager.shared.debugNewestFileURL == nil)
        // 截取缩略图在屏幕上的实际显示（只截缩略图自身的范围）
        if let frame = ThumbnailManager.shared.debugNewestFrame {
            ThumbnailManager.shared.debugHoverNewest()
            try? await Task.sleep(for: .milliseconds(200))
            await captureComposite(around: frame, to: dir.appendingPathComponent("6-缩略图实际显示.png"))
        }

        // 点缩略图上的「保存」→ 存到保存文件夹，核对文件
        ThumbnailManager.shared.debugSaveNewest()
        try? await Task.sleep(for: .milliseconds(800))
        check("缩略图「保存」后知道文件位置", ThumbnailManager.shared.debugNewestFileURL != nil)
        checkFile(outputDir: outputDir, expectedPixels: expectedPixels, scale: scale, check: check)
        ThumbnailManager.shared.debugSaveNewest()   // 再点一次不应存出第二份
        try? await Task.sleep(for: .milliseconds(500))
        check("重复点「保存」不重复存文件", pngFiles(in: outputDir).count == 1, "\(pngFiles(in: outputDir).count) 个文件")

        // 标注已经合成进输出：第一个红色矩形的左边框在选区内 (120, 145) 处
        if let file = pngFiles(in: outputDir).first {
            let stroke = pixel(in: file, x: Int(20 * scale), y: Int(105 * scale))
            check("输出包含标注（红色矩形边框）", stroke.map { $0.r > 200 && $0.g < 100 && $0.b < 100 } ?? false,
                  "得到 \(String(describing: stroke))")
            // 马赛克区域 (210...290, 205...245)：同一个方块内的像素颜色一致
            let a = pixel(in: file, x: Int(112 * scale), y: Int(10 * scale))
            let b = pixel(in: file, x: Int(114 * scale), y: Int(12 * scale))
            check("输出包含马赛克（方块内颜色一致）", a != nil && a?.r == b?.r && a?.g == b?.g && a?.b == b?.b,
                  "\(String(describing: a)) vs \(String(describing: b))")
        }

        // 单击缩略图：打开重新编辑窗口，再画一个标注，完成后产生新的缩略图
        if let editor = ThumbnailManager.shared.debugOpenNewest() {
            try? await Task.sleep(for: .milliseconds(300))
            check("单击缩略图打开编辑窗口", editor.debugWindow.isVisible && ThumbnailManager.shared.visibleCount == 0)
            check("编辑窗口默认选中矩形工具", editor.debugAnnotator.tool == .rectangle)
            editor.canvasMouseDown(at: CGPoint(x: 150, y: 30))
            editor.canvasMouseDragged(to: CGPoint(x: 190, y: 60))
            editor.canvasMouseUp(at: CGPoint(x: 190, y: 60))
            check("编辑窗口里画标注", editor.debugAnnotator.document.annotations.count == 1)
            // 编辑窗口确实显示在最前：屏幕上画布中心的像素 = 截图本身中心的像素（只比对数值，不保存别的内容）
            let canvas = editor.debugCanvas
            let canvasOnScreen = editor.debugWindow.convertToScreen(canvas.convert(canvas.bounds, to: nil))
            try? await Task.sleep(for: .milliseconds(200))
            let shown = await compositePixel(at: CGPoint(x: canvasOnScreen.midX, y: canvasOnScreen.midY))
            let base = editor.debugAnnotator.renderer.base
            let expected = centerPixel(of: base.image)
            let visibleOnTop = shown != nil && expected != nil
                && abs(Int(shown!.r) - Int(expected!.r)) < 8 && abs(Int(shown!.g) - Int(expected!.g)) < 8
                && abs(Int(shown!.b) - Int(expected!.b)) < 8
            check("编辑窗口显示在最前（不被其他 App 挡住）", visibleOnTop,
                  "屏幕上 \(String(describing: shown))，期望 \(String(describing: expected))")
            if visibleOnTop {
                await captureComposite(around: canvasOnScreen.insetBy(dx: 0, dy: -50).offsetBy(dx: 0, dy: -50),
                                       to: dir.appendingPathComponent("9-编辑窗口画布.png"))
            }
            // 缩放：⌥ + 滚动放大，普通滚动不改大小；⌘0 回到原来大小、⌘= 放大；放大后控制点在屏幕上大小不变
            let zoomView = editor.debugZoomView
            func scroll(_ amount: Int32, option: Bool) -> NSEvent? {
                let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)
                cg?.flags = option ? .maskAlternate : []
                return cg.flatMap(NSEvent.init(cgEvent:))
            }
            check("编辑窗口打开时是原来大小", zoomView.magnification == 1)
            check("比例按原像素算：小图打开时是 100%", editor.zoomPercent == 100, "\(editor.zoomPercent)%")
            if let up = scroll(3, option: true) { zoomView.scrollWheel(with: up) }
            let zoomed = zoomView.magnification
            check("按住 ⌥ 滚轮往上一格：放大 15%（不随滚轮加速变多）", abs(zoomed - 1.15) < 0.001, "\(zoomed)")
            check("触控板：每个事件最多 10%，滑 100 点约 35%",
                  EditorZoomView.zoomFactor(deltaY: 200, precise: true) == 1.1
                  && abs(EditorZoomView.zoomFactor(deltaY: 10, precise: true) - exp(0.03)) < 0.0001
                  && EditorZoomView.zoomFactor(deltaY: -3, precise: false) < 1)
            check("放大后控制点按屏幕大小算", abs(editor.debugAnnotator.canvasUnitsPerPoint - 1 / zoomed) < 0.001,
                  "\(editor.debugAnnotator.canvasUnitsPerPoint)")
            if let plain = scroll(3, option: false) { zoomView.scrollWheel(with: plain) }
            check("不按 ⌥ 滚动：不改变大小", zoomView.magnification == zoomed)
            for _ in 0..<30 { if let up = scroll(10, option: true) { zoomView.scrollWheel(with: up) } }
            check("最多放大到原图 1 个像素 = 屏幕 4 个像素（400%）", editor.zoomPercent == 400
                  && zoomView.magnification == zoomView.maxMagnification, "\(editor.zoomPercent)%")
            await captureComposite(around: editor.debugWindow.convertToScreen(zoomView.convert(zoomView.bounds, to: nil)),
                                   to: dir.appendingPathComponent("9b-编辑窗口放大.png"))
            for _ in 0..<30 { if let down = scroll(-10, option: true) { zoomView.scrollWheel(with: down) } }
            check("最小回到原来大小", zoomView.magnification == 1)
            _ = editor.handleKey(key(kVK_ANSI_Equal, false, "=").withCommand)
            check("⌘= 放大", abs(zoomView.magnification - 1.25) < 0.01, "\(zoomView.magnification)")
            editor.canvasMouseDown(at: CGPoint(x: 20, y: 20))
            editor.canvasMouseDragged(to: CGPoint(x: 60, y: 50))
            editor.canvasMouseUp(at: CGPoint(x: 60, y: 50))
            check("放大后照常画标注（原图坐标）", editor.debugAnnotator.document.annotations.count == 2)
            _ = editor.handleKey(key(kVK_ANSI_0, false, "0").withCommand)
            check("⌘0 回到原来大小", zoomView.magnification == 1)

            // 长截图（300 × 3000）：按宽度 100% 打开、从顶上看起、可以滚动；按住 ⌥ 往下滚能缩小到看全
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let ctx = CGContext(data: nil, width: 300, height: 3000, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 3000))
                ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
                for k in 0..<30 { ctx.fill(CGRect(x: 20, y: k * 100 + 30, width: 200, height: 20)) }
                if let tall = ctx.makeImage(),
                   let long = AnnotationEditorWindowController.open(CapturedImage(image: tall, scale: 1,
                                                                                  sourceRect: CGRect(x: o.x + 100, y: o.y + 100, width: 300, height: 3000))) {
                    try? await Task.sleep(for: .milliseconds(300))
                    let z = long.debugZoomView
                    let visible = z.contentView.documentVisibleRect
                    check("长截图编辑窗口：按宽度原大小打开、只显示一部分", long.debugCanvas.frame.width == 300 && z.frame.height < 3000
                          && z.minMagnification < 1, "\(long.debugCanvas.frame) \(z.frame)")
                    check("长截图编辑窗口：从最上面看起", abs(visible.maxY - 3000) < 1, "\(visible)")
                    for _ in 0..<40 { if let down = scroll(-10, option: true) { z.scrollWheel(with: down) } }
                    let all = z.contentView.documentVisibleRect
                    check("长截图编辑窗口：按住 ⌥ 往下滚能缩小到看全整张", z.magnification == z.minMagnification
                          && all.height >= 2999, "\(all)")
                    long.perform(.cancel)
                }
            }
            editor.perform(.done)
            try? await Task.sleep(for: .milliseconds(600))
            check("编辑完成后关闭窗口并显示新缩略图", !editor.debugWindow.isVisible && ThumbnailManager.shared.visibleCount == 1)
        } else {
            check("单击缩略图打开编辑窗口", false, "没有缩略图")
        }

        // 钉图：钉在原位、原始大小；单击选中后按 Esc 关闭
        if let pin = ThumbnailManager.shared.debugPinNewest() {
            let expected = CGRect(x: o.x + 100, y: o.y + 100, width: 200, height: 150)
            check("钉图钉在原位、原始大小", pin.frame == expected, "期望 \(expected)，得到 \(pin.frame)")
            check("钉图出现后缩略图收起", ThumbnailManager.shared.visibleCount == 0)
            try? await Task.sleep(for: .milliseconds(300))
            await captureComposite(around: pin.frame, to: dir.appendingPathComponent("7-钉图实际显示.png"))
            pin.makeKey()
            check("单击选中钉图（显示杏色边框）", (pin.contentView as? PinView)?.isSelected == true)
            pin.keyDown(with: key(kVK_Escape))
            check("选中后按 Esc 关闭钉图", PinManager.shared.count == 0 && !pin.isVisible)
        } else {
            check("钉图", false, "没有可钉的缩略图")
        }

        // ⌘S：完成并保存；之后「粘贴」（读取剪贴板）应收起缩略图
        CaptureCoordinator.shared.beginScreenshot()
        try? await Task.sleep(for: .milliseconds(500))
        if let second = CaptureCoordinator.shared.debugSession {
            second.overlayMouseDown(at: g(100, 100))
            second.overlayMouseDragged(to: g(200, 150))
            second.overlayMouseDragged(to: g(300, 250))
            second.overlayMouseUp(at: g(300, 250))
            _ = second.overlayKeyDown(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                       windowNumber: 0, context: nil, characters: "s",
                                                       charactersIgnoringModifiers: "s", isARepeat: false,
                                                       keyCode: UInt16(kVK_ANSI_S))!)
            try? await Task.sleep(for: .milliseconds(800))
            check("截图界面 ⌘S 完成并保存", CaptureCoordinator.shared.debugSession == nil && pngFiles(in: outputDir).count == 2,
                  "\(pngFiles(in: outputDir).count) 个文件")
            check("粘贴前缩略图还在", ThumbnailManager.shared.visibleCount == 1)
            checkClipboard(expectedPixels: expectedPixels, check: check)
            try? await Task.sleep(for: .milliseconds(300))
            check("粘贴后缩略图自动收起", ThumbnailManager.shared.visibleCount == 0, "还有 \(ThumbnailManager.shared.visibleCount) 个")
        } else {
            check("截图界面 ⌘S 完成并保存", false, "第二次截图没有启动")
        }

        checkEncoder(check: check)
        await runTranslateChecks(dir: dir, check: check)
        await runLongCaptureChecks(dir: dir, check: check)
        ToolStyleMemory.debugCleanUp()
        report(check.lines, to: dir)
    }

    /// 截屏翻译（⌥D）：快捷键、选区界面、松开即识别、单击窗口、全屏 + Enter、取消、识别不到文字
    private static func runTranslateChecks(dir: URL, check: Checks) async {
        drawsText = true
        // 自测机器上没有下载 Apple 翻译的语言包，也不能弹出下载提示：用假的翻译，检查结果窗口的其余部分
        TranslationModel.debugTranslator = { text, source, target in "[\(source.rawValue)→\(target.rawValue)] \(text)" }
        let testPasteboard = NSPasteboard(name: NSPasteboard.Name("local.snap.uitest.translate"))
        TranslationWindow.pasteboard = testPasteboard
        defer {
            TranslationModel.debugTranslator = nil
            TranslationWindow.pasteboard = .general
            testPasteboard.releaseGlobally()
        }
        defer { drawsText = false }
        let coordinator = CaptureCoordinator.shared
        let controller = ScreenTranslateController.shared
        let o = screenOrigin
        func g(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x, y: o.y + y) }
        func key(_ code: Int, _ modifiers: NSEvent.ModifierFlags = [], _ chars: String = "") -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                             keyCode: UInt16(code))!
        }
        /// 按 ⌥D 开始一次截屏翻译
        func begin() async -> ScreenshotSession? {
            if let window = controller.debugPreview, !window.model.isPinned { window.close() }
            controller.debugHUD?.close()
            coordinator.handleHotkey(.translate)
            try? await Task.sleep(for: .milliseconds(600))
            return coordinator.debugSession
        }

        // 快捷键
        check("截屏翻译默认快捷键 ⌥D", coordinator.hotkey(for: .translate) == .defaultTranslate
              && Hotkey.defaultTranslate.displayString == "⌥D")
        check("⌥D 已注册为全局快捷键", HotkeyManager.shared.hotkey(for: .translate) == .defaultTranslate
              && !HotkeyManager.shared.failedActions.contains(.translate))
        let clash1 = HotkeyConflicts.problem(with: .defaultScreenshot, for: .translate) ?? ""
        let clash2 = HotkeyConflicts.problem(with: .defaultTranslate, for: .recording) ?? ""
        check("冲突检测：⌥A、⌥S、⌥D 互相不能重复", clash1.contains("截图") && clash2.contains("截屏翻译"), "\(clash1) / \(clash2)")

        // 选区界面
        guard let session = await begin(), session.purpose == .translate else { return check("⌥D 打开截屏翻译界面", false) }
        check("⌥D 打开截屏翻译界面（冻屏）", session.debugActiveOverlay != nil)
        check("截屏翻译没有标注工具栏", session.debugToolbar.superview == nil)
        session.overlayMouseMoved(to: g(300, 250))
        check("截屏翻译不显示放大镜", !session.debugMagnifierVisible)
        check("悬停高亮窗口", session.debugSelector.hoveredWindow == CGRect(origin: g(200, 200), size: CGSize(width: 600, height: 400)))
        check("截屏翻译期间 ⌥A 不打断", { coordinator.handleHotkey(.screenshot); return coordinator.debugSession === session }())
        DebugSnapshots.renderOverlay(session.debugActiveOverlay, to: dir.appendingPathComponent("11-截屏翻译选区.png"))
        _ = session.overlayKeyDown(key(kVK_ANSI_D, .option, "∂"))
        check("⌥D 切换到全屏识别", session.mode == .fullscreen)
        _ = session.overlayKeyDown(key(kVK_ANSI_D, .option, "∂"))
        check("再按 ⌥D 切回框选", session.mode == .region)

        // 拖出选区，松开立即识别
        let selection = CGRect(x: g(210, 430).x, y: g(210, 430).y, width: 280, height: 140)
        session.overlayMouseDown(at: CGPoint(x: selection.minX, y: selection.maxY))
        session.overlayMouseDragged(to: CGPoint(x: selection.midX, y: selection.midY))
        session.overlayMouseDragged(to: CGPoint(x: selection.maxX, y: selection.minY))
        session.overlayMouseUp(at: CGPoint(x: selection.maxX, y: selection.minY))
        check("松开鼠标立即开始识别（界面关闭，不用按 Enter）", coordinator.debugSession == nil)
        check("松开鼠标立即出现结果窗口（识别中显示占位、不用转圈）", controller.debugPreview?.isVisible == true
              && controller.debugPreview?.model.isRecognizing == true)
        let started = ContinuousClock.now
        await controller.debugWait()
        let elapsed = ContinuousClock.now - started
        let text = controller.debugPreview?.text ?? ""
        // 识别结束后焦点会还给原来的 App：结果面板出现时 Snap 可能还在前台，随后失去前台，面板不能跟着消失。
        // 模拟这个顺序：先让 Snap 到前台，再让它失去前台
        check("截屏翻译的结果窗口不会被截到（下次冻屏时排除）", controller.debugPreview.map {
            !ScreenFreezer.capturableOwnWindows.contains(CGWindowID($0.debugWindow.windowNumber)) } == true)
        check("结果面板不会随 Snap 失去前台而隐藏", controller.debugPreview?.hidesOnDeactivate == false)
        NSApp.activate()
        try? await Task.sleep(for: .milliseconds(400))
        let wasActive = NSApp.isActive
        NSApp.deactivate()
        try? await Task.sleep(for: .milliseconds(400))
        check("Snap 从前台切走后结果面板仍然显示", controller.debugPreview?.isVisible == true,
              wasActive ? "面板消失了" : "（Snap 没能切到前台，无法模拟）")
        if !wasActive { check.note("Snap 没能切到前台，「切走后仍显示」只检查了设置项") }
        check("识别出选区里的英文和中文", text.contains("Snap translate test") && text.contains("截屏翻译自测"),
              "\(text.debugDescription)，耗时 \(elapsed)")
        // 新编译的程序第一次识别时，系统要为它准备识别模型（十几秒，只有一次），所以速度看下一次识别
        check.note("第一次识别耗时（含模型准备）：\(elapsed)")
        if let frame = controller.debugPreview?.frame, let screen = NSScreen.screen(containing: g(300, 300)) {
            let panel = frame
            check("结果面板有实际大小（不是 0×0）", panel.width >= 300 && panel.height >= 60, "\(frame)")
            check("结果放在选区旁边、不挡住选区", !panel.isEmpty && !panel.intersects(selection)
                  && screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(panel), "面板 \(panel)，选区 \(selection)")
        } else {
            check("结果放在选区旁边、不挡住选区", false, "没有结果面板")
        }
        if let window = controller.debugPreview {
            await runTranslationWindowChecks(window, dir: dir, check: check, pasteboard: testPasteboard)
        }

        // 单击窗口：识别整个窗口
        if let session = await begin() {
            session.overlayMouseMoved(to: g(300, 250))
            session.overlayMouseDown(at: g(300, 250))
            session.overlayMouseUp(at: g(300, 250))
            let clickStarted = ContinuousClock.now
            await controller.debugWait()
            let clickElapsed = ContinuousClock.now - clickStarted
            check("单击窗口：识别整个窗口", coordinator.debugSession == nil
                  && controller.debugPreview?.text.contains("Snap translate test") == true)
            check("识别耗时 < 1 秒（模型就绪后）", clickElapsed < .seconds(1), "\(clickElapsed)")
        }

        // 识别不到文字：结果窗口里提示「未识别到文字」，1.5 秒后自己关闭
        if let session = await begin() {
            session.overlayMouseDown(at: g(600, 560))
            session.overlayMouseDragged(to: g(800, 400))
            session.overlayMouseUp(at: g(900, 350))
            let window = controller.debugPreview
            try? await Task.sleep(for: .milliseconds(600))
            check("识别不到文字：窗口里提示「未识别到文字」", window?.model.recognitionFailure == "未识别到文字"
                  && window?.isVisible == true, String(describing: window?.model.recognitionFailure))
            await controller.debugWait()
            try? await Task.sleep(for: .milliseconds(200))
            check("识别不到文字：提示 1.5 秒后窗口自己关闭", window?.isVisible == false && controller.debugPreview == nil)
        }

        // 全屏模式 + Enter
        if let session = await begin() {
            _ = session.overlayKeyDown(key(kVK_ANSI_D, .option, "∂"))
            _ = session.overlayKeyDown(key(kVK_Return, [], "\r"))
            await controller.debugWait()
            // 整屏图片很大，Vision 内部会缩小后识别，小字（尤其笔画多的汉字）可能认错；这里只检查流程和英文
            check("全屏模式按 Enter 识别整屏", coordinator.debugSession == nil
                  && controller.debugPreview?.text.contains("Snap translate test") == true,
                  (controller.debugPreview?.text ?? "没有结果").debugDescription)
            check.note("全屏识别结果：\((controller.debugPreview?.text ?? "").debugDescription)")
        }
        controller.debugPreview?.debugPressEscape()
        check("结果面板按 Esc 关闭", controller.debugPreview == nil)

        // 钉住：点别处不关闭；新的截屏翻译不影响钉住的窗口；可以调整大小；窗口快捷键
        func translateText() async -> TranslationWindow? {
            guard let session = await begin() else { return nil }
            session.overlayMouseDown(at: g(210, 570))
            session.overlayMouseDragged(to: g(350, 500))
            session.overlayMouseDragged(to: g(490, 430))
            session.overlayMouseUp(at: g(490, 430))
            await controller.debugWait()
            return controller.debugPreview
        }
        if let first = await translateText() {
            check("⌘P 钉住：图钉高亮、可以调整大小", first.debugPress("p", .command) && first.model.isPinned
                  && first.debugWindow.styleMask.contains(.resizable) && controller.debugPinned.count == 1)
            check("钉住后左上角不出现红绿灯（不挡住语言栏）", [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .allSatisfy { first.debugWindow.standardWindowButton($0)?.isHidden != false })
            first.debugClickOutside()
            check("钉住的窗口点别处不关闭", first.isVisible)
            if let second = await translateText() {
                check("再次截屏翻译生成新窗口，钉住的窗口保留", second !== first && first.isVisible && second.isVisible
                      && !second.model.isPinned && controller.debugPinned.count == 1)
                second.debugClickOutside()
                check("没钉住的窗口点别处关闭", !second.isVisible && first.isVisible)
            }
            // 拖边缘调整大小：之后内容变化不再改窗口高度
            first.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification))
            var big = first.frame
            big.size = CGSize(width: 560, height: 520)
            first.debugWindow.setFrame(big, display: true)
            first.model.translate()
            try? await Task.sleep(for: .milliseconds(400))
            check("钉住的窗口调整大小后保持用户设的大小", abs(first.frame.width - 560) < 1 && abs(first.frame.height - 520) < 1,
                  "\(first.frame)")
            // 快捷键
            testPasteboard.clearContents()
            check("⇧⌘C 复制原文", first.debugPress("c", [.command, .shift])
                  && testPasteboard.string(forType: .string) == first.model.sourceText)
            check("⌘C 复制译文", first.debugPress("c", .command)
                  && testPasteboard.string(forType: .string) == first.model.translation && !first.model.translation.isEmpty)
            first.debugPress("r", .command)
            check("⌘R 重新翻译", first.model.isPending || first.model.status == .done)
            try? await Task.sleep(for: .milliseconds(300))
            check("⌘P 取消钉住：回到默认宽度、不能调整大小", first.debugPress("p", .command) && !first.model.isPinned
                  && !first.debugWindow.styleMask.contains(.resizable) && abs(first.frame.width - TranslationView.width) < 1
                  && controller.debugPinned.isEmpty)
            first.debugPress("p", .command)
            first.debugPressEscape()
            check("钉住的窗口按 Esc 也关闭", !first.isVisible && controller.debugPinned.isEmpty)
        }
        let savedPinned = Preferences.shared.translateWindowPinnedByDefault
        Preferences.shared.translateWindowPinnedByDefault = true
        if let window = await translateText() {
            check("设置「默认钉住」后新窗口直接钉住", window.model.isPinned && controller.debugPinned.contains { $0 === window })
        }
        Preferences.shared.translateWindowPinnedByDefault = savedPinned
        controller.debugCloseAll()

        // 取消
        if let session = await begin() {
            _ = session.overlayKeyDown(key(kVK_Escape))
            check("Esc 取消截屏翻译", coordinator.debugSession == nil && controller.debugPreview == nil)
        }
        if let session = await begin() {
            session.overlayRightMouseDown(at: g(300, 250))
            check("右键取消截屏翻译", coordinator.debugSession == nil)
        }
        check("截屏翻译结束后恢复 ⌥D 全局快捷键", HotkeyManager.shared.debugRegisteredCount == 3)
        controller.debugHUD?.close()

        // 识别在单独的服务进程里做：识别后服务在运行，空闲 30 秒后自己退出（释放内存），之后再识别会自动重新启动
        check("识别服务进程在运行（识别不在 Snap 进程里做）", ocrServiceRunning())
        let waitStarted = ContinuousClock.now
        while ocrServiceRunning(), ContinuousClock.now - waitStarted < .seconds(45) {
            try? await Task.sleep(for: .seconds(1))
        }
        let waited = ContinuousClock.now - waitStarted
        check("识别服务空闲 30 秒后自动退出", !ocrServiceRunning(), "等了 \(waited) 仍在运行")
        check.note("识别服务在最后一次识别后约 \(Int(waited.components.seconds)) 秒退出")
        if let session = await begin() {
            let restarted = ContinuousClock.now
            session.overlayMouseDown(at: g(210, 570))
            session.overlayMouseDragged(to: g(350, 500))
            session.overlayMouseDragged(to: g(490, 430))
            session.overlayMouseUp(at: g(490, 430))
            await controller.debugWait()
            check("服务退出后再识别：自动重新启动服务", controller.debugPreview?.text.contains("Snap translate test") == true
                  && ocrServiceRunning(), "结果 \((controller.debugPreview?.text ?? "无").debugDescription)，服务在运行：\(ocrServiceRunning())")
            check.note("服务重新启动后的识别耗时（含启动）：\(ContinuousClock.now - restarted)")
            controller.debugPreview?.close()
        }
    }

    /// 结果窗口：语言规则、译文、编辑原文自动重新翻译、交换语言、复制、高度变化时顶边不动
    private static func runTranslationWindowChecks(_ window: TranslationWindow, dir: URL, check: Checks,
                                                   pasteboard: NSPasteboard) async {
        let model = window.model
        func settle() async { try? await Task.sleep(for: .milliseconds(250)) }
        await settle()
        check("中英混排、中文为主：原文按中文，目标语言英文", model.sourceLanguage.isChinese && model.targetLanguage == .english,
              "\(model.sourceLanguage) → \(model.targetLanguage)")
        check("显示译文", model.translation.hasPrefix("[\(model.sourceLanguage.rawValue)→en]") && model.status == .done,
              model.translation.debugDescription)
        // 截一张结果窗口的实际显示（后面垫合成桌面，不拍到真实屏幕）
        if let screen = NSScreen.screen(containing: CGPoint(x: window.frame.midX, y: window.frame.midY)),
           let image = DebugShowcase.desktopImage(for: screen) {
            let backdrop = DebugShowcase.makeBackdrop(for: screen, image: image, level: .normal)
            try? await Task.sleep(for: .milliseconds(400))
            await DebugShowcase.captureWindow(window.debugWindow, name: "12-翻译结果窗口.png", dir: dir)
            window.setPinned(true)
            try? await Task.sleep(for: .milliseconds(400))
            await DebugShowcase.captureWindow(window.debugWindow, name: "12c-钉住.png", dir: dir)
            window.setPinned(false)
            // 识别中的样子（占位线）
            let waiting = TranslationWindow(model: TranslationModel(recognizing: ()), near: window.frame.offsetBy(dx: -500, dy: 0))
            waiting.show()
            try? await Task.sleep(for: .milliseconds(500))
            await DebugShowcase.captureWindow(waiting.debugWindow, name: "12b-识别中.png", dir: dir)
            waiting.close(reason: "自测")
            backdrop.close()
        }
        let top = window.frame.maxY
        model.sourceText = "Hello world. This is a longer English sentence that should wrap onto several lines in the result window, so the window grows."
        try? await Task.sleep(for: .milliseconds(1000))
        check("编辑原文后自动重新翻译：英文 → 简体中文", model.sourceLanguage == .english && model.targetLanguage == .simplifiedChinese
              && model.translation.hasPrefix("[en→zh-Hans] Hello world."), model.translation.debugDescription)
        check("内容变多时窗口向下长、顶边不动", abs(window.frame.maxY - top) < 1 && window.frame.height > 200,
              "顶边 \(top) → \(window.frame.maxY)，高 \(window.frame.height)")
        model.targetChoice = .english
        await settle()
        check("目标语言和原文相同时自动换成另一种", model.targetLanguage == .simplifiedChinese)
        model.targetChoice = .japanese
        await settle()
        check("手动选目标语言", model.translation.hasPrefix("[en→ja]"), model.translation.debugDescription)
        model.swapLanguages()
        await settle()
        check("交换语言", model.sourceLanguage == .japanese && model.targetLanguage == .english
              && model.translation.hasPrefix("[ja→en]"), "\(model.sourceLanguage) → \(model.targetLanguage)")
        window.debugCopyBoth()
        let copied = pasteboard.string(forType: .string) ?? ""
        check("复制原文和译文", copied.hasPrefix("Hello world.") && copied.contains("\n\n[ja→en]"), copied.debugDescription)
        let copyHUD = window.debugCopyHUD
        check("复制后显示「已复制」提示", copyHUD?.isVisible == true)
        model.sourceChoice = nil
        model.targetChoice = nil
        await settle()
        check("改回自动检测", model.sourceLanguage == .english && model.targetLanguage == .simplifiedChinese)
        // 真实的 Apple 翻译（直接通道，不经过窗口）：只在这台机器已经下载了英→简中语言包时测，绝不触发下载提示
        if #available(macOS 26.0, *), await AppleTranslator.shared.status(from: .english, to: .simplifiedChinese) == .installed {
            let started = ContinuousClock.now
            let output = try? await AppleTranslator.shared.translate("Good morning. The weather is nice today.", from: .english, to: .simplifiedChinese)
            let first = ContinuousClock.now - started
            let again = ContinuousClock.now
            _ = try? await AppleTranslator.shared.translate("Screen translation should feel instant.", from: .english, to: .simplifiedChinese)
            let second = ContinuousClock.now - again
            check("真实 Apple 翻译（直接通道）：有中文结果", output?.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } == true,
                  output ?? "失败")
            check("直接通道翻译一句 < 0.3 秒（复用会话）", second < .milliseconds(300), "\(second)")
            check.note("真实 Apple 翻译耗时：第一次 \(first)，复用会话 \(second)")
            // 长文逐段出来：第一段很快就能显示，整篇的段落分隔保留，结果是简体
            let paragraph = "A screen capture utility spends almost all of its life waiting. For that reason, the most important decision is how little it costs while doing nothing at all."
            let long = Array(repeating: paragraph, count: 5).joined(separator: "\n\n")
            let streamStarted = ContinuousClock.now
            var firstProgress: Duration?
            var progressCount = 0
            let whole = try? await AppleTranslator.shared.translateByParagraph(long, from: .english, to: .simplifiedChinese) { _ in
                progressCount += 1
                if firstProgress == nil { firstProgress = ContinuousClock.now - streamStarted }
            }
            let total = ContinuousClock.now - streamStarted
            check("长文逐段显示：第一段 < 0.3 秒就出来", (firstProgress ?? .seconds(9)) < .milliseconds(300) && progressCount == 4,
                  "第一段 \(String(describing: firstProgress))，回调 \(progressCount) 次")
            check("逐段翻译保留段落、结果是简体", whole?.components(separatedBy: "\n\n").count == 5
                  && whole.map { $0 == LanguageRules.normalizedChinese($0, target: .simplifiedChinese) } == true)
            check.note("5 段长文：第一段 \(String(describing: firstProgress))，全部 \(total)")
        } else {
            check.note("这台机器没有英→简中语言包，跳过真实翻译测试")
        }
        // 查词：单个单词或短语时显示系统词典的音标、词性、释义
        await runEngineChecks(check: check)
        check("只有单词或短语才查词典", DictionaryLookup.shouldLookUp("ubiquitous") && DictionaryLookup.shouldLookUp("take off")
              && DictionaryLookup.shouldLookUp("电脑") && !DictionaryLookup.shouldLookUp("This is a whole sentence.")
              && !DictionaryLookup.shouldLookUp("one two three four five"))
        if let entry = DictionaryLookup.lookUp("ubiquitous") {
            check("查词：音标、词性、释义", entry.headword == "ubiquitous" && entry.phonetics.map(\.label) == ["英", "美"]
                  && entry.parts.first?.name == "形容词" && entry.parts.first?.senses.first?.gloss.contains("普遍") == true,
                  "\(entry)")
            let dictModel = TranslationModel(result: OCRResult(text: "ubiquitous", language: .english, confidence: 1, lines: []),
                                             recognitionTime: .milliseconds(120))
            let dictWindow = TranslationWindow(model: dictModel, near: window.frame.offsetBy(dx: -480, dy: 0))
            dictWindow.show()
            try? await Task.sleep(for: .milliseconds(500))
            check("结果窗口里显示词典卡片", dictModel.dictionaryEntry?.headword == "ubiquitous")
            if let screen = NSScreen.screen(containing: CGPoint(x: dictWindow.frame.midX, y: dictWindow.frame.midY)),
               let image = DebugShowcase.desktopImage(for: screen) {
                let backdrop = DebugShowcase.makeBackdrop(for: screen, image: image, level: .normal)
                try? await Task.sleep(for: .milliseconds(400))
                await DebugShowcase.captureWindow(dictWindow.debugWindow, name: "12d-查词.png", dir: dir)
                backdrop.close()
            }
            dictModel.sourceText = "This is a whole sentence, not a single word."
            try? await Task.sleep(for: .milliseconds(900))
            check("改成句子后不再显示词典", dictModel.dictionaryEntry == nil)
            dictWindow.close(reason: "自测")
        } else {
            check.note("这台机器的「词典」App 里没有启用英汉词典，跳过查词测试")
        }
        check("译文混入繁体字时统一成简体", LanguageRules.normalizedChinese("傳統字符與簡化字符不同", target: .simplifiedChinese) == "传统字符与简化字符不同"
              && LanguageRules.normalizedChinese("Hello 世界", target: .simplifiedChinese) == "Hello 世界"
              && LanguageRules.normalizedChinese("简体中文", target: .traditionalChinese) == "簡體中文")
        check("Apple 翻译支持的语言都在列表里", LanguageRules.appleSupported.count == 20
              && LanguageRules.appleSupported.allSatisfy { $0.localeLanguage.languageCode != nil })

        // 「已复制」提示：结果窗口关闭后会被释放，连同它显示的提示对象一起。提示对象没了也要按时淡出，
        // 不能一直留在屏幕上。这里模拟：显示提示后，只留住提示的窗口，提示对象本身立即释放
        window.close(reason: "自测")
        var hudWindow: NSWindow?
        do {
            let hud = RecognitionHUD(around: window.frame)
            hud.showMessage("已复制译文", symbol: "checkmark.circle.fill")
            hudWindow = hud.debugWindow
        }
        try? await Task.sleep(for: .milliseconds(2300))
        check("结果窗口关闭后，「已复制」提示仍会自动消失", hudWindow != nil && hudWindow?.isVisible == false,
              "提示仍在屏幕上")
    }

    /// 在线翻译引擎：签名算法对照官方文档的例子、钥匙串读写、默认引擎失败时自动切换（不联网，用假的在线引擎）
    private static func runEngineChecks(check: Checks) async {
        // 腾讯 TC3：文档例子（CVM DescribeInstances）的请求体哈希和规范请求哈希
        let payload = #"{"Limit": 1, "Filters": [{"Values": ["\u672a\u547d\u540d"], "Name": "instance-name"}]}"#
        let canonical = Tencent.canonicalRequest(host: "cvm.tencentcloudapi.com", action: "DescribeInstances", payload: payload)
        check("腾讯签名：规范请求与官方文档例子一致",
              EngineCrypto.sha256Hex(payload) == "35e9c5b0e3ae67532d3c9f17ead6c90222632e5b1ff7f6e89887f1398934f064"
              && EngineCrypto.sha256Hex(canonical) == "7019a55be8395899b900fb5564e4200d984910f34794a27cb3fb7d10ff6a1e84")
        // 百度：文档例子 appid=2015063000000001 q=apple salt=1435660288 密钥=12345678
        check("百度签名与官方文档例子一致",
              Baidu.sign("apple", appid: "2015063000000001", salt: "1435660288", secret: "12345678") == "f89f9594663708c1605f3d736d01d2d4")
        // 有道：超过 20 个字符时 input = 前 10 + 长度 + 后 10
        let long = "abcdefghijKLMNOPQRSTUVWXYZ0123456789"
        let expectedInput: String = "k" + "abcdefghij" + "36" + "0123456789" + "s1x"
        let youdaoSign: String = Youdao.sign(long, appKey: "k", salt: "s", curtime: "1", secret: "x")
        check("有道签名：长文本按「前 10 + 长度 + 后 10」计算", youdaoSign == EngineCrypto.sha256Hex(expectedInput))
        check("DeepL：Free 版 Key（:fx 结尾）用 api-free", DeepL.endpoint(for: "abc:fx").host == "api-free.deepl.com"
              && DeepL.endpoint(for: "abc").host == "api.deepl.com")

        // 钥匙串：写入、读出、删除
        let saved = EngineID.youdao.fields.map { ($0.key, EngineID.youdao.credential($0.key)) }
        EngineID.youdao.setCredential("test-app-key", for: "appKey")
        EngineID.youdao.setCredential("test-secret", for: "appSecret")
        check("Key 保存在钥匙串里，读得回来", EngineID.youdao.credential("appKey") == "test-app-key" && EngineID.youdao.hasCredentials)

        // 默认引擎（有道）失败 → 自动换到下一个（Apple 翻译，自测里是假的），译文区说明
        let prefs = Preferences.shared
        let savedEnabled = prefs.enabledEngines, savedDefault = prefs.defaultEngine
        prefs.enabledEngines = ["youdao"]
        prefs.defaultEngine = "youdao"
        check("启用并填了 Key 的引擎可以选为默认", EngineRouting.available == [.apple, .youdao] && EngineRouting.preferred == .youdao)
        EngineID.debugOnline = { engine, _ in throw EngineError.quotaExceeded }
        let model = TranslationModel(result: OCRResult(text: "Hello world", language: .english, confidence: 1, lines: []),
                                     recognitionTime: .milliseconds(100))
        check("新窗口用默认引擎", model.engine == .youdao)
        model.translate()
        try? await Task.sleep(for: .milliseconds(400))
        check("默认引擎失败时自动切换，并说明原因", model.engine == .apple && model.status == .done
              && model.engineNotice?.contains("有道智云 失败（额度用完了或账户欠费）") == true
              && model.engineNotice?.contains("已切换到 Apple 翻译") == true, String(describing: model.engineNotice))
        EngineID.debugOnline = { engine, text in "[\(engine.rawValue)] \(text)" }
        model.use(.youdao)
        try? await Task.sleep(for: .milliseconds(300))
        check("在结果窗口里换引擎重新翻译", model.engine == .youdao && model.translation == "[youdao] Hello world"
              && model.engineNotice == nil)
        EngineID.debugOnline = nil

        await runLLMChecks(check: check)

        // 结果窗口的设置：默认目标语言、自动复制译文
        let savedTarget = prefs.defaultTargetLanguage, savedAutoCopy = prefs.translateAutoCopy
        prefs.enabledEngines = []
        prefs.defaultEngine = "apple"
        prefs.defaultTargetLanguage = "ja"
        let english = TranslationModel(result: OCRResult(text: "Good morning", language: .english, confidence: 1, lines: []),
                                       recognitionTime: .milliseconds(100))
        let japanese = TranslationModel(result: OCRResult(text: "おはよう", language: .japanese, confidence: 1, lines: []),
                                        recognitionTime: .milliseconds(100))
        check("默认目标语言：设为日语后英文译成日语", english.targetLanguage == .japanese)
        check("默认目标语言：原文就是日语时改译成简体中文", japanese.targetLanguage == .simplifiedChinese)
        prefs.defaultTargetLanguage = ""
        check("默认目标语言：自动时英文译成简体中文", english.targetLanguage == .simplifiedChinese)
        prefs.translateAutoCopy = true
        TranslationWindow.pasteboard.clearContents()
        english.translate()
        try? await Task.sleep(for: .milliseconds(300))
        check("翻译完成后自动复制译文", TranslationWindow.pasteboard.string(forType: .string) == english.translation
              && !english.translation.isEmpty, String(describing: TranslationWindow.pasteboard.string(forType: .string)))
        prefs.translateAutoCopy = false
        TranslationWindow.pasteboard.clearContents()
        english.sourceText = "Good night"
        english.translate()
        try? await Task.sleep(for: .milliseconds(300))
        check("关闭自动复制时不复制", TranslationWindow.pasteboard.string(forType: .string) == nil)
        prefs.defaultTargetLanguage = savedTarget
        prefs.translateAutoCopy = savedAutoCopy

        // 恢复
        prefs.enabledEngines = savedEnabled
        prefs.defaultEngine = savedDefault
        for (key, value) in saved { EngineID.youdao.setCredential(value, for: key) }
        check("自测写入的 Key 已从钥匙串删除", EngineID.youdao.credential("appKey") == saved.first { $0.0 == "appKey" }?.1)
    }

    /// 大模型翻译：提示词、Base URL、流式解析、请求头（用假的服务端，不联网）
    private static func runLLMChecks(check: Checks) async {
        let prompt = LLMTranslation.systemPrompt(source: .english, target: .simplifiedChinese, custom: "")
        check("大模型默认提示词：只输出译文、填入语言", prompt.contains("从英语翻译成简体中文") && prompt.contains("只输出译文"))
        check("自定义提示词替换 {source} {target}",
              LLMTranslation.systemPrompt(source: .japanese, target: .english, custom: "把{source}译成{target}") == "把日语译成英语")
        check("Base URL 自动补全 /chat/completions",
              OpenAICompatible.endpoint("https://api.deepseek.com/v1/")?.absoluteString == "https://api.deepseek.com/v1/chat/completions"
              && OpenAICompatible.endpoint("https://x.test/v1/chat/completions")?.absoluteString == "https://x.test/v1/chat/completions"
              && OpenAICompatible.endpoint("ftp://x") == nil)

        LLMTranslation.debugProtocol = MockLLMServer.self
        var partials: [String] = []
        let claude = try? await ClaudeAPI.translate("Hello, world.", .english, .simplifiedChinese, apiKey: "sk-test",
                                                    model: "", prompt: "") { partials.append($0) }
        try? await Task.sleep(for: .milliseconds(100))
        let claudeRequest = MockLLMServer.lastRequest
        check("Claude：流式输出拼成完整译文", claude == "你好，世界。", String(describing: claude))
        check("Claude：译文一边生成一边显示", partials.count >= 2 && partials.first == "你好", "\(partials)")
        let body = claudeRequest.flatMap { $0.body }.flatMap { EngineHTTP.json($0) }
        check("Claude 请求：版本头、默认模型、低强度、拒答回退",
              claudeRequest?.headers["x-api-key"] == "sk-test" && claudeRequest?.headers["anthropic-version"] == "2026-10-21"
              && claudeRequest?.headers["anthropic-beta"] == "server-side-fallback-2026-07-01"
              && body?["model"] as? String == "claude-opus-5-5" && body?["fallbacks"] as? String == "default"
              && (body?["output_config"] as? [String: Any])?["effort"] as? String == "low" && body?["stream"] as? Bool == true
              && body?["temperature"] == nil, String(describing: body))
        let haiku = try? await ClaudeAPI.translate("Hello", .english, .simplifiedChinese, apiKey: "sk-test",
                                                   model: "claude-haiku-5-5", prompt: "") { _ in }
        let haikuBody = MockLLMServer.lastRequest?.body.flatMap { EngineHTTP.json($0) }
        check("不支持拒答回退的模型不带 fallbacks", haiku != nil && haikuBody?["fallbacks"] == nil
              && MockLLMServer.lastRequest?.headers["anthropic-beta"] == nil)

        partials = []
        let openAI = try? await OpenAICompatible.translate("Hello, world.", .english, .simplifiedChinese,
                                                          baseURL: "https://llm.test/v1", model: "test-model", apiKey: "sk-o",
                                                          prompt: "") { partials.append($0) }
        try? await Task.sleep(for: .milliseconds(100))
        let openAIBody = MockLLMServer.lastRequest?.body.flatMap { EngineHTTP.json($0) }
        check("OpenAI 兼容：流式拼接、[DONE] 结束", openAI == "你好，世界。" && partials.count >= 2, String(describing: openAI))
        check("OpenAI 兼容请求：Bearer、模型、系统提示词", MockLLMServer.lastRequest?.headers["Authorization"] == "Bearer sk-o"
              && openAIBody?["model"] as? String == "test-model"
              && ((openAIBody?["messages"] as? [[String: Any]])?.first?["content"] as? String)?.contains("只输出译文") == true)

        do {
            _ = try await ClaudeAPI.translate("Hello", .english, .simplifiedChinese, apiKey: "bad", model: "", prompt: "") { _ in }
            check("Key 无效时给出简短原因", false)
        } catch {
            check("Key 无效时给出简短原因", (error as? EngineError) == .invalidKey, "\(error)")
        }
        do {
            _ = try await OpenAICompatible.translate("Hello", .english, .simplifiedChinese, baseURL: "https://quota.test",
                                                     model: "m", apiKey: "k", prompt: "") { _ in }
            check("额度用完（429 insufficient_quota）", false)
        } catch {
            check("额度用完（429 insufficient_quota）", (error as? EngineError) == .quotaExceeded, "\(error)")
        }
    }

    /// 长截图：拼接算法（合成的长页面，带顶部标题栏、底部输入框）、界面（喂合成画面，不截真实屏幕）
    private static func runLongCaptureChecks(dir: URL, check: Checks) async {
        check("编辑窗口的工具栏没有「长截图」", AnnotationToolbar().debugLongCaptureEnabled == nil)

        // 合成的长页面：每行是随机的「文字」，每 17 行里有 3 行空白（段落间距）
        func content(_ count: Int, _ cross: Int, seed: UInt32) -> [[UInt32]] {
            var g = seed
            func next() -> UInt32 { g = g &* 1_664_525 &+ 1_013_904_223; return g }
            return (0..<count).map { i in
                i % 17 >= 14 ? [UInt32](repeating: 0xFFFF_FFFF, count: cross)
                    : (0..<cross).map { _ in next() % 5 == 0 ? 0xFF00_0000 | (next() & 0x00FF_FFFF) : 0xFFFF_FFFF }
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func frame(_ lines: [[UInt32]], cross: Int, axis: ScrollAxis) -> PixelFrame {
            let n = lines.count
            let (w, h) = axis == .vertical ? (cross, n) : (n, cross)
            var data = Data(count: w * h * 4)
            data.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt32.self)
                for y in 0..<h { for x in 0..<w { p[y * w + x] = axis == .vertical ? lines[y][x] : lines[x][y] } }
            }
            return PixelFrame(width: w, height: h, bytesPerRow: w * 4, data: data, colorSpace: space)
        }
        func lines(of image: CGImage, cross: Int, axis: ScrollAxis) -> [[UInt32]] {
            guard let f = PixelFrame(image: image, colorSpace: space) else { return [] }
            return f.data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt32.self)
                let n = axis == .vertical ? f.height : f.width
                return (0..<n).map { i in (0..<cross).map { j in axis == .vertical ? p[i * f.width + j] : p[j * f.width + i] } }
            }
        }

        // 1. 拼接算法：竖向、横向各一遍
        let cross = 120, header = 20, footer = 30, viewport = 300, area = 250
        let page = content(1600, cross, seed: 7)
        let top = content(header, cross, seed: 99).map { $0.map { $0 ^ 0x0012_3456 } }
        let bottom = content(footer, cross, seed: 55).map { $0.map { $0 ^ 0x0065_4321 } }
        func view(_ pos: Int) -> [[UInt32]] { top + Array(page[pos..<(pos + area)]) + bottom }
        _ = viewport
        for axis in [ScrollAxis.vertical, .horizontal] {
            let tag = axis == .vertical ? "竖向" : "横向"
            var s = ScrollStitcher(axis: axis)
            var events: [ScrollStitcher.Event] = []
            for pos in [0, 0, 40, 90, 60, 150, 500, 330] { events.append(s.add(frame(view(pos), cross: cross, axis: axis))) }
            check("长截图\(tag)：开始、不动、接上、往回滚不重复、滚太远对不上、回来继续",
                  events == [.started, .unchanged, .appended(40), .appended(50), .moved, .appended(60), .lost, .appended(180)],
                  "\(events)")
            for pos in stride(from: 400, through: 1200, by: 70) { s.add(frame(view(pos), cross: cross, axis: axis)) }
            let expected = top + Array(page[0..<(1170 + area)]) + bottom
            let got = s.makeImage().map { lines(of: $0, cross: cross, axis: axis) } ?? []
            check("长截图\(tag)：结果与原页面逐像素一致，底部输入框只出现一次", got == expected, "\(got.count) / \(expected.count) 行")
            var limited = ScrollStitcher(axis: axis, maxLength: 600)
            var last = limited.add(frame(view(0), cross: cross, axis: axis))
            for pos in stride(from: 60, through: 900, by: 60) { last = limited.add(frame(view(pos), cross: cross, axis: axis)) }
            check("长截图\(tag)：到长度上限停止", last == .limitReached && limited.length == 600, "\(last) \(limited.length)")
        }

        // 容差：每帧随机抖动一些像素（模拟滚动时抗锯齿的细微差别），精确比对全部失效，靠亮度轮廓接上
        func jittered(_ f: PixelFrame, seed: UInt32) -> PixelFrame {
            var g = seed
            var data = f.data
            data.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                for i in 0..<p.count where i % 4 != 3 {
                    g = g &* 1_664_525 &+ 1_013_904_223
                    if g % 7 == 0 { p[i] = UInt8(clamping: Int(p[i]) + Int(g >> 29) - 3) }
                }
            }
            return PixelFrame(width: f.width, height: f.height, bytesPerRow: f.bytesPerRow, data: data, colorSpace: f.colorSpace)
        }
        for axis in [ScrollAxis.vertical, .horizontal] {
            let tag = axis == .vertical ? "竖向" : "横向"
            var s = ScrollStitcher(axis: axis)
            var events: [ScrollStitcher.Event] = []
            for (k, pos) in [0, 0, 40, 90, 60, 150, 330].enumerated() {
                events.append(s.add(jittered(frame(view(pos), cross: cross, axis: axis), seed: UInt32(k + 1))))
            }
            check("长截图\(tag)：像素有细微差别也能接上", events == [.started, .unchanged, .appended(40), .appended(50), .moved,
                                                         .appended(60), .appended(180)], "\(events)")
            var hinted = ScrollStitcher(axis: axis)
            hinted.add(jittered(frame(view(0), cross: cross, axis: axis), seed: 9))
            let e = hinted.add(jittered(frame(view(120), cross: cross, axis: axis), seed: 10), hint: 110)
            check("长截图\(tag)：有滚轮提示时在附近找到", e == .appended(120), "\(e)")
        }

        // 滚动条：每帧右侧有个跟着移动的滑块，比对时忽略右边缘，照常精确接上；结果右边缘以外和原页面一致
        func withScrollbar(_ lines: [[UInt32]], knobAt: Int) -> [[UInt32]] {
            lines.enumerated().map { i, line in
                var l = line
                for x in (cross - 10)..<cross { l[x] = (i >= knobAt && i < knobAt + 60) ? 0xFF7F_7F7F : line[x] }
                return l
            }
        }
        // 没画完：刚滚到时内容区最下面 40 行是空白，下一帧才画好
        func unrendered(_ pos: Int) -> [[UInt32]] {
            var lines = view(pos)
            for i in (header + area - 40)..<(header + area) { lines[i] = [UInt32](repeating: 0xFFFF_FFFF, count: cross) }
            return lines
        }
        for axis in [ScrollAxis.vertical, .horizontal] {
            let tag = axis == .vertical ? "竖向" : "横向"
            var s = ScrollStitcher(axis: axis, edgeMargin: (0, 16))
            var events: [ScrollStitcher.Event] = []
            for (k, pos) in [0, 40, 90, 150, 330].enumerated() {
                events.append(s.add(frame(withScrollbar(view(pos), knobAt: 20 + k * 30), cross: cross, axis: axis)))
            }
            let trimmed = (top + Array(page[0..<(330 + area)]) + bottom).map { Array($0[0..<(cross - 16)]) }
            let got = s.makeImage().map { lines(of: $0, cross: cross, axis: axis).map { Array($0[0..<(cross - 16)]) } } ?? []
            check("长截图\(tag)：滚动条在动也照常接上，内容一致", events == [.started, .appended(40), .appended(50), .appended(60), .appended(180)]
                  && got == trimmed, "\(events)")
            var r = ScrollStitcher(axis: axis)
            r.add(frame(view(0), cross: cross, axis: axis))
            for pos in stride(from: 60, through: 600, by: 60) {
                r.add(frame(unrendered(pos), cross: cross, axis: axis))
                r.add(frame(view(pos), cross: cross, axis: axis))
            }
            let full = r.makeImage().map { lines(of: $0, cross: cross, axis: axis) } ?? []
            check("长截图\(tag)：刚滚到时没画完的部分，画好后自动换上", full == top + Array(page[0..<(600 + area)]) + bottom)
        }

        // 两侧不动的边栏：左 20、右 15 像素不滚动，只有中间在滚；边栏只出现在第一屏，往下用背景色延伸
        let sideL = content(viewport, 20, seed: 71), sideR = content(viewport, 15, seed: 72)
        func withSides(_ pos: Int) -> [[UInt32]] {
            view(pos).enumerated().map { i, line in sideL[i] + Array(line[20..<(cross - 15)]) + sideR[i] }
        }
        for axis in [ScrollAxis.vertical, .horizontal] {
            let tag = axis == .vertical ? "竖向" : "横向"
            var s = ScrollStitcher(axis: axis)
            var events: [ScrollStitcher.Event] = []
            for pos in [0, 40, 90, 150, 330] { events.append(s.add(frame(withSides(pos), cross: cross, axis: axis))) }
            let white = [UInt32](repeating: 0xFFFF_FFFF, count: 20), whiteR = [UInt32](repeating: 0xFFFF_FFFF, count: 15)
            let expected = Array(withSides(0)[0..<(header + area)])
                + page[area..<(330 + area)].map { white + Array($0[20..<(cross - 15)]) + whiteR }
                + Array(withSides(330)[(viewport - footer)..<viewport])
            let got = s.makeImage().map { lines(of: $0, cross: cross, axis: axis) } ?? []
            check("长截图\(tag)：两侧边栏不动也照常接上，边栏不重复", events == [.started, .appended(40), .appended(50), .appended(60),
                                                                .appended(180)] && got == expected, "\(events) \(got.count)/\(expected.count)")
        }

        // 限速：每帧最多 100 点；猛甩 2000 点，先放行 100，其余积压（最多 1200）在之后每帧补发 100
        var throttle = ScrollThrottle(maxPerFrame: 100, frameInterval: 0.1, maxPending: 1200, now: 0)
        let first = throttle.take(2000, now: 0)
        var drained: [Double] = []
        for k in 1...14 { drained.append(throttle.drain(now: Double(k) * 0.1)) }
        check("限速：猛甩时每帧都不超过 100 点", first == 100 && drained.allSatisfy { $0 <= 100.001 }, "\(first) \(drained)")
        check("限速：积压最多 1200 点，之后全部补发", abs(drained.reduce(0, +) - 1200) < 0.01 && throttle.pending == 0,
              "\(drained.reduce(0, +))")
        _ = throttle.take(500, now: 2.0)
        let reverse = throttle.take(-30, now: 2.0)
        // 这一帧的额度已经用完：反向的 30 点留到下一帧发，原来积压的 400 点丢掉
        check("限速：反向滚动时丢掉没补发的部分", reverse == 0 && throttle.pending == -30, "\(throttle.pending) \(reverse)")
        var gentle = ScrollThrottle(maxPerFrame: 100, frameInterval: 0.1, maxPending: 1200, now: 0)
        let slow = (1...10).map { gentle.take(40, now: Double($0) * 0.1) }
        check("限速：正常速度的滚动原样放行", slow.allSatisfy { $0 == 40 } && gentle.pending == 0)

        // 2. 界面：屏幕中间 320×240 的选区，下面垫合成的桌面；画面直接喂合成的，不截真实屏幕
        guard let screen = NSScreen.main, let desktop = DebugShowcase.desktopImage(for: screen) else {
            return check("长截图界面：准备合成桌面", false)
        }
        let backdrop = DebugShowcase.makeBackdrop(for: screen, image: desktop, level: .floating)
        defer { backdrop.close() }
        let visible = screen.visibleFrame
        let region = CGRect(x: (visible.midX - 260).rounded(), y: (visible.midY - 100).rounded(), width: 320, height: 240)
        let session = LongCaptureSession(region: region, screen: screen)
        var finished = false
        session.onFinish = { finished = true }
        session.debugStartWithoutCapture()
        try? await Task.sleep(for: .milliseconds(200))
        check("长截图开始：提示「请缓慢向下滚动页面」", session.debugOverlay.message?.contains("向下滚动") == true)
        check("控制条在选区下方，预览在选区右边", session.debugBar.barFrame.maxY <= region.minY
              && session.debugPreview.isVisible && session.debugPreview.frame.minX >= region.maxX)

        let scale = screen.backingScaleFactor
        let px = Int(region.width * scale), viewLines = Int(region.height * scale)
        let longPage = content(viewLines * 7, px, seed: 3)
        func screenFrame(_ pos: Int) -> PixelFrame { frame(Array(longPage[pos..<(pos + viewLines)]), cross: px, axis: .vertical) }
        let step = viewLines / 4
        for k in 0..<10 { session.debugFeed(screenFrame(k * step)) }
        try? await Task.sleep(for: .milliseconds(600))
        let expectedLength = viewLines + 9 * step
        check("喂 10 帧：拼好的长度正确，控制条显示「已拼接」", session.debugLength == expectedLength
              && session.debugBar.debugLengthText == "已拼接 \(expectedLength) 像素", "\(session.debugLength) / \(expectedLength)")
        check("开始滚动后提示消失、预览有内容", session.debugOverlay.message == nil && session.debugPreview.debugPartCount >= 1)
        if let image = await session.debugImage() {
            check("长截图结果：宽 \(px) 像素、高 \(expectedLength) 像素", image.width == px && image.height == expectedLength)
        }
        let area2 = region.union(session.debugBar.barFrame).union(session.debugPreview.frame).insetBy(dx: -30, dy: -30)
        await captureComposite(around: area2, to: dir.appendingPathComponent("12-长截图界面实际显示.png"))

        session.debugFeed(screenFrame(9 * step + viewLines * 2))
        try? await Task.sleep(for: .milliseconds(300))
        check("一下滚太远：提示往回滚", session.debugOverlay.message?.contains("滚动太快") == true)

        session.debugSetAxis(.horizontal)
        try? await Task.sleep(for: .milliseconds(200))
        check("换成横向：从头开始，提示「向右滚动」", session.debugOverlay.message?.contains("向右滚动") == true
              && session.debugLength == 0 && session.debugBar.debugLengthText == "等待滚动…")

        // Esc：长截图期间注册成临时全局快捷键（焦点在被截的 App 里），按下就取消；结束后注销
        let escape = session.debugInstallEscape()
        check("长截图期间 Esc 已注册", escape != nil && HotkeyManager.shared.debugTemporaryCount == 1)
        if let escape { HotkeyManager.shared.debugPressTemporary(escape) }
        try? await Task.sleep(for: .milliseconds(300))
        check("按 Esc 取消长截图，Esc 随即注销", HotkeyManager.shared.debugTemporaryCount == 0)
        check("取消：长截图界面全部关闭", finished && !session.debugBar.isVisible && !session.debugOverlay.isVisible
              && !session.debugPreview.isVisible)
    }

    /// 识别服务进程（SnapOCR.xpc）是否在运行
    private static func ocrServiceRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // 只认这一份 App 里的服务（/Applications 里正式版的服务可能也在运行）
        process.arguments = ["-f", Bundle.main.bundlePath + "/Contents/XPCServices/SnapOCR.xpc/Contents/MacOS/SnapOCR"]
        process.standardOutput = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// 第 5 阶段：在选区 (100, 100, 200, 150) 上测试各种标注
    private static func runAnnotationChecks(_ session: ScreenshotSession, dir: URL, check: Checks,
                                            g: (CGFloat, CGFloat) -> CGPoint, key: (Int, Bool, String) -> NSEvent,
                                            render: (String) -> Void) async {
        let toolbar = session.debugToolbar
        check("遮罩层级高于程序坞和菜单栏", session.debugOverlayLevel == NSWindow.Level.screenSaver.rawValue,
              "当前层级 \(session.debugOverlayLevel)")
        check("选好区域后显示工具栏", toolbar.superview != nil)
        check("工具栏在选区下方", toolbar.frame.maxY <= 100 - 4, "工具栏 \(toolbar.frame)")
        func drag(_ a: CGPoint, _ b: CGPoint) {
            session.overlayMouseDown(at: a)
            session.overlayMouseDragged(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
            session.overlayMouseDragged(to: b)
            session.overlayMouseUp(at: b)
        }

        session.debugSelectTool(.rectangle)
        guard let annotator = session.debugAnnotator else { return check("创建标注控制器", false) }
        check("选择工具后隐藏放大镜", !session.debugMagnifierVisible)
        check("没画标注时「长截图」可用", session.debugToolbar.debugLongCaptureEnabled == true)
        drag(g(120, 120), g(180, 170))
        check("画矩形", annotator.document.annotations.count == 1)
        session.debugToolbarRefresh()
        check("画了标注后「长截图」不可用（要在标注之前开始）", session.debugToolbar.debugLongCaptureEnabled == false)
        let before = session.debugSelector.selection
        drag(g(400, 400), g(450, 450))
        check("选区外拖动不画标注、不改选区", annotator.document.annotations.count == 1 && session.debugSelector.selection == before)

        // 序号：连续点两下得到 1、2；撤销后下一个是 2，重做回来
        session.debugSelectTool(.counter)
        session.overlayMouseDown(at: g(260, 120)); session.overlayMouseUp(at: g(260, 120))
        session.overlayMouseDown(at: g(280, 120)); session.overlayMouseUp(at: g(280, 120))
        check("序号自动递增", annotator.document.nextCounterNumber == 3)
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        check("⌘Z 撤销", annotator.document.annotations.count == 2 && annotator.document.nextCounterNumber == 2)
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, true, "z").withCommand)
        check("⌘⇧Z 重做", annotator.document.annotations.count == 3)

        // 文字：Enter 确认文字而不是完成截图；Esc 只结束输入
        session.debugSelectTool(.text)
        session.overlayMouseDown(at: g(110, 240)); session.overlayMouseUp(at: g(110, 240))
        annotator.debugType("Snap 标注")
        check("文字输入时 ⌥A 由截图界面处理（不会打出 å）",
              session.overlayShouldIntercept(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
                                                              timestamp: 0, windowNumber: 0, context: nil, characters: "å",
                                                              charactersIgnoringModifiers: "a", isARepeat: false,
                                                              keyCode: UInt16(kVK_ANSI_A))!))
        annotator.debugTextView?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check("文字输入时 Enter 确认文字、不完成截图",
              annotator.document.annotations.count == 4 && !annotator.isEditingText && CaptureCoordinator.shared.debugSession != nil)
        session.overlayMouseDown(at: g(110, 200)); session.overlayMouseUp(at: g(110, 200))
        annotator.debugType("Esc")
        annotator.debugTextView?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        check("文字输入时 Esc 只结束输入（保留文字）",
              annotator.document.annotations.count == 5 && CaptureCoordinator.shared.debugSession != nil)

        // 马赛克、模糊和其余形状
        session.debugSelectTool(.mosaic)
        drag(g(210, 205), g(290, 245))
        session.debugSelectTool(.blur)
        drag(g(230, 130), g(290, 190))
        var style = AnnotationStyle()
        style.color = AnnotationPalette.colors[3]
        session.debugSetStyle(style, level: 2)
        for (tool, a, b) in [(AnnotationTool.arrow, g(155, 183), g(190, 220)), (.line, g(200, 110), g(250, 110)),
                             (.ellipse, g(295, 200), g(240, 150)), (.pen, g(145, 205), g(190, 235)),
                             (.highlighter, g(105, 160), g(200, 160))] {
            // 按在已有标注上会拖动它而不是画新的：起点都选在空白处
            check("\(tool.title)的起点在空白处", annotator.annotation(at: CGPoint(x: a.x - g(0, 0).x, y: a.y - g(0, 0).y)) == nil)
            session.debugSelectTool(tool)
            drag(a, b)
        }
        check("马赛克、模糊、箭头、直线、椭圆、画笔、荧光笔", annotator.document.annotations.count == 12,
              "共 \(annotator.document.annotations.count) 个")
        check("颜色和粗细生效", annotator.document.annotations.last?.size == AnnotationTool.highlighter.presetSizes[2]
              && annotator.document.annotations.last?.color == AnnotationPalette.colors[3])
        // 选中矩形工具（展开颜色 / 粗细栏），截取工具栏的实际显示
        session.debugSelectTool(.rectangle)
        try? await Task.sleep(for: .milliseconds(300))
        let bar = session.debugToolbar
        if let host = bar.superview, let window = host.window {
            let onScreen = window.convertToScreen(host.convert(bar.frame, to: nil))
            await captureComposite(around: onScreen.insetBy(dx: -24, dy: -24),
                                   to: dir.appendingPathComponent("10b-工具栏实际显示.png"))
        }
        // 录制选项条与麦克风下拉菜单：放在合成画面上看外观（磨砂虚化的是合成画面，不涉及真实屏幕）
        if let host = bar.superview, let window = host.window {
            let optionsBar = RecordingOptionsBar(blending: .withinWindow)
            optionsBar.setFrameOrigin(CGPoint(x: 700, y: 260))
            host.addSubview(optionsBar)
            optionsBar.debugShowDeviceMenu()
            try? await Task.sleep(for: .milliseconds(300))
            var area = optionsBar.frame
            if let menuFrame = optionsBar.debugMenuFrame { area = area.union(menuFrame) }
            check("麦克风下拉菜单为自绘的温暖风格菜单", optionsBar.debugMenuFrame != nil)
            await captureComposite(around: window.convertToScreen(host.convert(area.insetBy(dx: -24, dy: -24), to: nil)),
                                   to: dir.appendingPathComponent("10c-录制选项条与菜单实际显示.png"))
            optionsBar.removeFromSuperview()
        }
        session.debugSelectTool(nil)
        render("10-标注")

        // 选中已有标注：拖动、方向键微移、Delete 删除、撤销恢复；最后全部撤销，回到原样
        let document = annotator.document
        let first = document.annotations[0]
        let firstID = first.id
        func rectOfFirst() -> CGRect? {
            if case .rectangle(let r)? = document.annotation(withID: firstID)?.shape { return r }
            return nil
        }
        let originalRect = rectOfFirst()
        // 精准：只有正好在线条上才算「在标注上」（矩形线宽 4 点，边框在 x = 120）。
        // annotation(at:) 用画布坐标（屏幕内坐标），overlayCursor 用全局坐标
        check("鼠标在矩形边框上：变成四向移动光标", annotator.annotation(at: CGPoint(x: 121, y: 145))?.id == firstID
              && session.overlayCursor(at: g(121, 145)) == .snapMove)
        NSCursor.debugRenderMovePreview(to: dir.appendingPathComponent("10g-移动光标.png"))
        check("离边框 5 点：不算在标注上，仍是十字", annotator.annotation(at: CGPoint(x: 115, y: 145)) == nil
              && annotator.annotation(at: CGPoint(x: 126, y: 145)) == nil && session.overlayCursor(at: g(115, 145)) != .arrow)
        check("方框内部：不算在标注上", annotator.annotation(at: CGPoint(x: 150, y: 135)) == nil)
        session.overlayMouseDown(at: g(121, 145))
        check("单击矩形边框：选中这个矩形", annotator.selectedID == firstID)
        session.overlayMouseDragged(to: g(131, 150))
        session.overlayMouseDragged(to: g(141, 155))
        session.overlayMouseUp(at: g(141, 155))
        check("拖动标注：整体平移 (20, 10)", rectOfFirst() == originalRect?.offsetBy(dx: 20, dy: 10), "\(String(describing: rectOfFirst()))")
        render("10d-选中并拖动标注")
        _ = session.overlayKeyDown(key(kVK_RightArrow, false, ""))
        check("方向键微移选中的标注 1 点", rectOfFirst() == originalRect?.offsetBy(dx: 21, dy: 10))
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        check("⌘Z 两次撤销微移和拖动，回到原位", rectOfFirst() == originalRect, "\(String(describing: rectOfFirst()))")
        check("撤销后仍保持选中", annotator.selectedID == firstID)
        _ = session.overlayKeyDown(key(kVK_Delete, false, ""))
        check("Delete 删除选中的标注，截图界面还在", document.annotations.count == 11 && document.annotation(withID: firstID) == nil
              && CaptureCoordinator.shared.debugSession != nil && annotator.selectedID == nil)
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        check("⌘Z 恢复删除的标注", document.annotations.count == 12 && rectOfFirst() == originalRect)
        session.overlayMouseDown(at: g(121, 145))
        session.overlayMouseUp(at: g(121, 145))
        _ = session.overlayKeyDown(key(kVK_Escape, false, ""))
        check("Esc 先取消选中，不退出截图", annotator.selectedID == nil && CaptureCoordinator.shared.debugSession != nil)
        _ = session.overlayKeyDown(key(kVK_Delete, false, ""))
        check("没有选中时 Delete 不删除任何标注", document.annotations.count == 12)

        // 选着矩形工具：在方框内部可以画新的标注，点边框才是选中
        session.debugSelectTool(.rectangle)
        drag(g(140, 130), g(165, 150))
        check("选着工具时在方框内部画新的标注（不会误选中）", document.annotations.count == 13 && annotator.selectedID == nil)
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        session.overlayMouseDown(at: g(121, 145))
        session.overlayMouseUp(at: g(121, 145))
        check("选着工具时单击方框边框：选中它（不画新的）", annotator.selectedID == firstID && document.annotations.count == 12)
        // 按在边框上、避开边中点的控制点（那里是调整大小）
        session.overlayMouseDown(at: g(121, 135))
        session.overlayMouseDragged(to: g(126, 135))
        session.overlayMouseDragged(to: g(131, 135))
        session.overlayMouseUp(at: g(131, 135))
        check("选着工具时拖动已选中的标注：移动它", rectOfFirst() == originalRect?.offsetBy(dx: 10, dy: 0)
              && document.annotations.count == 12, "\(String(describing: rectOfFirst()))")
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        _ = session.overlayKeyDown(key(kVK_Escape, false, ""))
        // 选着工具时从没选中的标注上直接按住拖：移动它（不用先单击选中），不画新的
        check("没选中时：标注上是四向移动光标", annotator.selectedID == nil && session.overlayCursor(at: g(121, 135)) == .snapMove)
        drag(g(121, 135), g(111, 125))
        check("选着工具时从没选中的标注上直接拖：移动它，不画新的", document.annotations.count == 12
              && rectOfFirst() == originalRect?.offsetBy(dx: -10, dy: -10) && annotator.selectedID == firstID,
              "\(String(describing: rectOfFirst()))")
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        _ = session.overlayKeyDown(key(kVK_Escape, false, ""))

        // 序号：删掉第 1 个后，下一个是 3（不会和现有的 2 重复）
        session.debugSelectTool(nil)
        session.overlayMouseDown(at: g(260, 120))
        session.overlayMouseUp(at: g(260, 120))
        _ = session.overlayKeyDown(key(kVK_Delete, false, ""))
        check("删掉序号 1 后下一个序号是 3", document.nextCounterNumber == 3 && document.annotations.count == 11)
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        check("测试操作全部撤销后，标注恢复原样", document.annotations.count == 12 && rectOfFirst() == originalRect)

        // 选中后不显示虚线框，方框内部也不能拖（要按在线条上才能拖）；选着工具时在里面拖是画新的标注
        session.overlayMouseDown(at: g(121, 135))
        session.overlayMouseUp(at: g(121, 135))
        check("选中后方框内部：不能拖，不显示移动光标", annotator.selectedID == firstID
              && annotator.grabbableAnnotation(at: CGPoint(x: 150, y: 135)) == nil
              && session.overlayCursor(at: g(150, 135)) != .snapMove)
        session.debugSelectTool(.rectangle)
        drag(g(140, 130), g(165, 150))
        check("选着工具时在已选中标注的方框内拖：画新的，不移动它", document.annotations.count == 13 && rectOfFirst() == originalRect)
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        session.debugSelectTool(nil)

        // 控制点：选中后拖控制点调整大小（可撤销），拖太小时停住；Shift 等比、端点 45°（直接测几何）
        if let r0 = originalRect {
            session.overlayMouseDown(at: g(r0.minX + 1, r0.midY))
            session.overlayMouseUp(at: g(r0.minX + 1, r0.midY))
            check("选中矩形：8 个控制点", annotator.selectedID == firstID && annotator.selectedAnnotation?.resizeHandles.count == 8)
            let corner = CGPoint(x: r0.maxX, y: r0.maxY)
            check("右上角控制点上：调整大小的光标", annotator.resizeHandle(at: CGPoint(x: corner.x + 3, y: corner.y - 2)) == .frame(.topRight)
                  && session.overlayCursor(at: g(corner.x, corner.y)) != .arrow
                  && session.overlayCursor(at: g(corner.x, corner.y)) != .crosshair)
            session.overlayMouseDown(at: g(corner.x, corner.y))
            session.overlayMouseDragged(to: g(corner.x + 10, corner.y + 5))
            session.overlayMouseDragged(to: g(corner.x + 20, corner.y + 10))
            session.overlayMouseUp(at: g(corner.x + 20, corner.y + 10))
            check("拖右上角：变大 (20, 10)，左下角不动",
                  rectOfFirst() == CGRect(x: r0.minX, y: r0.minY, width: r0.width + 20, height: r0.height + 10),
                  "\(String(describing: rectOfFirst()))")
            render("10e-拖控制点调整大小")
            session.overlayMouseDown(at: g(r0.minX, r0.midY))
            session.overlayMouseDragged(to: g(r0.minX + 30, r0.midY))
            session.overlayMouseUp(at: g(r0.minX + 30, r0.midY))
            check("拖左边中点：只改宽度", rectOfFirst() == CGRect(x: r0.minX + 30, y: r0.minY, width: r0.width - 10, height: r0.height + 10),
                  "\(String(describing: rectOfFirst()))")
            let beforeTiny = rectOfFirst()
            let bottomRight = CGPoint(x: r0.maxX + 20, y: r0.minY)
            session.overlayMouseDown(at: g(bottomRight.x, bottomRight.y))
            session.overlayMouseDragged(to: g(r0.minX + 31, r0.minY + 1))
            session.overlayMouseUp(at: g(r0.minX + 31, r0.minY + 1))
            check("拖得太小时停在上一个大小（也不记撤销点）", rectOfFirst() == beforeTiny,
                  "\(String(describing: rectOfFirst())) 之前 \(String(describing: beforeTiny))")
            _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
            _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
            check("调整大小可以撤销，恢复原样（仍保持选中）", rectOfFirst() == r0 && document.annotations.count == 12
                  && annotator.selectedID == firstID, "\(String(describing: rectOfFirst()))")
        }
        let square = Annotation(shape: .ellipse(CGRect(x: 0, y: 0, width: 40, height: 20)), color: .red, size: 4, opacity: 1)
        if case .ellipse(let r) = square.resized(.frame(.topRight), to: CGPoint(x: 100, y: 25), keepRatio: true).shape {
            check("Shift 拖角：保持宽高比", r == CGRect(x: 0, y: 0, width: 100, height: 50), "\(r)")
        }
        let line = Annotation(shape: .line(from: .zero, to: CGPoint(x: 50, y: 0)), color: .red, size: 4, opacity: 1)
        check("直线和箭头：两个端点控制点", line.resizeHandles.count == 2)
        if case .line(let a, let b) = line.resized(.end, to: CGPoint(x: 40, y: 38), keepRatio: true).shape {
            check("拖端点：起点不动；Shift 沿 45°", a == .zero && abs(b.x - b.y) < 0.001 && b.x > 30, "\(b)")
        }
        let scribble = Annotation(shape: .pen([.zero, CGPoint(x: 10, y: 10)]), color: .red, size: 4, opacity: 1)
        check("画笔没有控制点（只能移动）", scribble.resizeHandles.isEmpty)

        // 选着标注工具时，仍然可以拖选区的控制点调整截图范围（标注保留）
        session.debugSelectTool(.rectangle)
        if let region = session.debugSelector.selection {
            let corner = CGPoint(x: region.maxX, y: region.minY)
            let count = document.annotations.count
            check("选着工具时选区控制点上：调整大小的光标", session.overlayCursor(at: corner) != .crosshair
                  && session.overlayCursor(at: corner) != .arrow)
            session.overlayMouseDown(at: corner)
            session.overlayMouseDragged(to: CGPoint(x: corner.x + 10, y: corner.y - 5))
            session.overlayMouseDragged(to: CGPoint(x: corner.x + 20, y: corner.y - 10))
            session.overlayMouseUp(at: CGPoint(x: corner.x + 20, y: corner.y - 10))
            check("选着工具时拖选区右下角：选区变大，不画新标注",
                  session.debugSelector.selection == CGRect(x: region.minX, y: region.minY - 10,
                                                           width: region.width + 20, height: region.height + 10)
                  && document.annotations.count == count && annotator.tool == .rectangle,
                  "\(String(describing: session.debugSelector.selection))")
            render("10f-选着工具时调整选区")
            session.overlayMouseDown(at: CGPoint(x: corner.x + 20, y: corner.y - 10))
            session.overlayMouseDragged(to: corner)
            session.overlayMouseUp(at: corner)
            check("拖回去：选区恢复原样", session.debugSelector.selection == region)

            // 缩小选区：标注实时按选区裁剪（看到的就是输出的），露在外面的部分点不中；标注本身不删改，放大选区后又出现
            let o = g(0, 0)
            let shrunk = CGPoint(x: region.minX + 50, y: region.minY)
            session.overlayMouseDown(at: corner)
            session.overlayMouseDragged(to: CGPoint(x: corner.x - 100, y: corner.y))
            session.overlayMouseDragged(to: shrunk)
            let liveBounds = annotator.canvasBounds
            session.overlayMouseUp(at: shrunk)
            let localRegion = session.debugSelector.selection?.offsetBy(dx: -o.x, dy: -o.y)
            check("缩小选区：拖动中标注范围就跟着变（实时裁剪）", localRegion != nil && liveBounds == localRegion
                  && annotator.canvasBounds == localRegion, "\(liveBounds) / \(String(describing: localRegion))")
            check("选区外的部分点不中，选区内的部分照常", annotator.annotation(at: CGPoint(x: 179, y: 145)) == nil
                  && annotator.annotation(at: CGPoint(x: 121, y: 145))?.id == firstID
                  && session.overlayCursor(at: g(179, 145)) != .snapMove)
            check("缩小选区不删改标注", document.annotations.count == count && rectOfFirst() == originalRect)
            render("10h-缩小选区后标注按选区裁剪")
            session.overlayMouseDown(at: shrunk)
            session.overlayMouseDragged(to: corner)
            session.overlayMouseUp(at: corner)
            check("放大回去：标注完整出现，又能点中", session.debugSelector.selection == region
                  && annotator.annotation(at: CGPoint(x: 179, y: 145))?.id == firstID)
        }
        session.debugSelectTool(nil)

        // 不透明度：没选工具时选中标注也显示属性栏；拖滑块改选中的标注，连续拖动合并成一次撤销
        let originalColor = document.annotation(withID: firstID)?.color ?? .clear
        check("没选工具、选中标注时显示属性栏和不透明度", toolbar.debugPropertyBarVisible && toolbar.debugShowsOpacity
              && annotator.selectedID == firstID)
        toolbar.debugOpacitySlider.set(0.5)
        toolbar.debugOpacitySlider.set(0.4)
        check("拖不透明度滑块：选中的标注变成 40%", document.annotation(withID: firstID)?.opacity == 0.4
              && ToolStyleMemory.style(for: .rectangle).opacity == 0.4)
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        check("连续拖动的不透明度一次撤销回 100%", document.annotation(withID: firstID)?.opacity == 1
              && toolbar.debugOpacitySlider.value == 1)

        // 调色盘：剪贴板里有 C 键复制的颜色代码时，一键使用
        let testPasteboard = NSPasteboard(name: NSPasteboard.Name("local.snap.uitest.colors"))
        testPasteboard.clearContents()
        testPasteboard.setString("#33AA77", forType: .string)
        ColorPickerView.pasteboard = testPasteboard
        toolbar.debugToggleColorPicker()
        check("打开任意颜色调色盘", toolbar.isShowingColorPicker && session.overlayCursor(at: g(150, 135)) == .arrow)
        check("剪贴板里有颜色代码：显示「使用剪贴板颜色」", toolbar.colorPicker?.debugClipboardButton != nil)
        if let picker = toolbar.colorPicker, let host = picker.superview, let window = host.window {
            try? await Task.sleep(for: .milliseconds(300))
            let area = picker.frame.union(host.convert(toolbar.bounds, from: toolbar))
            await captureComposite(around: window.convertToScreen(host.convert(area.insetBy(dx: -24, dy: -24), to: nil)),
                                   to: dir.appendingPathComponent("10e-任意颜色调色盘实际显示.png"))
        }
        toolbar.colorPicker?.debugClipboardButton?.action?()
        check("使用剪贴板颜色：选中的标注变成 #33AA77，调色盘关闭",
              document.annotation(withID: firstID).map { ColorCode.hex($0.color) } == "#33AA77" && !toolbar.isShowingColorPicker)
        check("自定义颜色显示在任意颜色按钮上", toolbar.debugCustomColorButton.customColor.map(ColorCode.hex) == "#33AA77")
        // 输入颜色代码：实时生效；#RRGGBBAA 带不透明度；不合法的代码不改
        toolbar.debugToggleColorPicker()
        toolbar.colorPicker?.debugType("#FF000080")
        let afterAlpha = document.annotation(withID: firstID)
        check("输入 #FF000080：红色、不透明度 50%", afterAlpha.map { ColorCode.hex($0.color) } == "#FF0000"
              && abs((afterAlpha?.opacity ?? 0) - 128.0 / 255) < 0.001)
        toolbar.colorPicker?.debugType("rgb(0, 128, 255)")
        toolbar.colorPicker?.debugType("#12G")
        check("输入 rgb(0, 128, 255) 生效，不合法的 #12G 不改",
              document.annotation(withID: firstID).map { ColorCode.hex($0.color) } == "#0080FF")
        toolbar.colorPicker?.debugPickHue(1.0 / 3, saturation: 1, brightness: 1)
        check("在色相条 / 方块上选颜色：变成纯绿，输入框同步",
              document.annotation(withID: firstID).map { ColorCode.hex($0.color) } == "#00FF00"
              && toolbar.colorPicker?.debugFieldText == "#00FF00")
        _ = session.overlayKeyDown(key(kVK_Escape, false, ""))
        check("Esc 先关调色盘，选中和截图界面都还在", !toolbar.isShowingColorPicker && annotator.selectedID == firstID
              && CaptureCoordinator.shared.debugSession != nil)
        check("颜色代码解析", ColorCode.parse("#F53").map { ColorCode.hex($0.color) } == "#FF5533"
              && ColorCode.parse("0x123456").map { ColorCode.hex($0.color) } == "#123456"
              && ColorCode.parse(" ff5733\n").map { ColorCode.hex($0.color) } == "#FF5733"
              && ColorCode.parse("rgba(255, 0, 0, 0.25)")?.opacity == 0.25
              && ColorCode.parse("12AB3") == nil && ColorCode.parse("rgb(300, 0, 0)") == nil)
        testPasteboard.releaseGlobally()
        ColorPickerView.pasteboard = .general
        // 撤销颜色修改（剪贴板颜色、输入代码、调色盘在 1 秒内连续修改，合并成一次撤销）
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        let restored = document.annotation(withID: firstID)
        check("一次撤销恢复原来的颜色和不透明度", restored.map { $0.color.isSameColor(as: originalColor) } == true
              && restored?.opacity == 1, "\(String(describing: restored.map { ColorCode.hex($0.color) }))")
        annotator.deselect()
        // 不透明度调低后再用马赛克 / 模糊：仍然完全不透明（否则会几乎看不见，像失效了一样）
        var faint = AnnotationStyle()
        faint.opacity = 0.3
        session.debugSetStyle(faint)
        // 起点选在空白处（按在已有标注上是拖动它）
        session.debugSelectTool(.mosaic)
        drag(g(150, 140), g(175, 152))
        session.debugSelectTool(.blur)
        drag(g(190, 140), g(215, 152))
        let lastTwo = document.annotations.suffix(2)
        check("不透明度 30% 时画的马赛克、模糊仍完全不透明", document.annotations.count == 14
              && lastTwo.allSatisfy { $0.opacity == 1 } && lastTwo.map(\.tool) == [.mosaic, .blur])
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        session.debugSelectTool(nil)

        // 每个工具各自记住上次用的颜色、粗细和不透明度
        session.debugSetStyle(AnnotationStyle())
        let green = AnnotationPalette.colors[2], yellow = AnnotationPalette.colors[1]
        session.debugSelectTool(.rectangle)
        toolbar.onSelectSize?(2)
        toolbar.onSelectColor?(green)
        session.debugSelectTool(.arrow)
        check("换到箭头：还是箭头自己的样式（不跟矩形走）", annotator.style.size == 4
              && annotator.style.color.isSameColor(as: AnnotationPalette.colors[0]))
        toolbar.onSelectSize?(7)
        toolbar.onSelectColor?(yellow)
        toolbar.debugOpacitySlider.set(0.6)
        session.debugSelectTool(.rectangle)
        check("换回矩形：恢复矩形上次的粗细 2、绿色、100%", annotator.style.size == 2
              && annotator.style.color.isSameColor(as: green) && annotator.style.opacity == 1)
        session.debugSelectTool(.arrow)
        check("换回箭头：恢复箭头上次的粗细 7、黄色、60%", annotator.style.size == 7
              && annotator.style.color.isSameColor(as: yellow) && annotator.style.opacity == 0.6)
        drag(g(150, 140), g(172, 152))
        let newArrow = document.annotations.last
        check("新画的箭头用箭头的样式", newArrow?.tool == .arrow && newArrow?.size == 7 && newArrow?.opacity == 0.6)
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        // 选着箭头工具时改选中的矩形：记到矩形上，箭头的样式不变
        session.overlayMouseDown(at: g(121, 145))
        session.overlayMouseUp(at: g(121, 145))
        toolbar.onSelectSize?(2)
        check("改选中的矩形：记作矩形的样式，箭头工具的样式不变", annotator.selectedID == firstID
              && document.annotation(withID: firstID)?.size == 2
              && ToolStyleMemory.style(for: .rectangle).size == 2 && annotator.style.size == 7)
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        annotator.deselect()
        ToolStyleMemory.debugReload()
        let reloadedArrow = ToolStyleMemory.style(for: .arrow)
        check("重新启动后仍记得每个工具的样式", reloadedArrow.size == 7 && reloadedArrow.opacity == 0.6
              && reloadedArrow.color.isSameColor(as: yellow) && ToolStyleMemory.style(for: .rectangle).size == 2,
              "箭头 \(reloadedArrow.size) \(reloadedArrow.opacity) \(ColorCode.hex(reloadedArrow.color))，矩形 \(ToolStyleMemory.style(for: .rectangle).size)")

        // 大小拉条：按工具显示名称和范围，精确到 1 点；滚动一次 1 点；超出范围的值被限制
        session.debugSelectTool(.rectangle)
        let sizeSlider = toolbar.debugSizeSlider
        check("矩形：拉条是「粗细 1–30」", sizeSlider.title == "粗细" && sizeSlider.minimum == 1 && sizeSlider.maximum == 30
              && sizeSlider.value == annotator.style.size, "\(String(describing: sizeSlider.title)) \(sizeSlider.minimum)–\(sizeSlider.maximum)")
        sizeSlider.set(12.4)
        check("拖到 12：当前粗细就是 12 点", annotator.style.size == 12 && sizeSlider.value == 12, "\(annotator.style.size)")
        drag(g(150, 140), g(172, 152))
        check("新画的矩形线宽 12 点", document.annotations.last?.lineWidth == 12)
        _ = session.overlayKeyDown(key(kVK_ANSI_Z, false, "z").withCommand)
        sizeSlider.set(99)
        check("超出范围时限制在 30", annotator.style.size == 30)
        if let up = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0)
            .flatMap(NSEvent.init(cgEvent:)) { sizeSlider.scrollWheel(with: up) }
        check("在拉条上滚动一次：减 1 点", annotator.style.size == 29, "\(annotator.style.size)")
        session.debugSelectTool(.text)
        check("文字：拉条是「字号 10–120」", sizeSlider.title == "字号" && sizeSlider.minimum == 10 && sizeSlider.maximum == 120)
        // 旧版本保存的三档（size: 0 / 1 / 2）读出来换算成数值
        ToolStyleMemory.debugStoreRaw(["rectangle": ["color": "#FF3B30", "size": 2, "opacity": 1.0],
                                      "text": ["color": "#FF3B30", "size": 0, "opacity": 1.0]])
        check("旧设置的「大 / 小」换算成 7 点线宽、14 号字", ToolStyleMemory.style(for: .rectangle).size == 7
              && ToolStyleMemory.style(for: .text).size == 14 && ToolStyleMemory.style(for: .arrow).size == 4)
        session.debugSelectTool(.rectangle)
        try? await Task.sleep(for: .milliseconds(200))
        if let host = toolbar.superview, let window = host.window {
            await captureComposite(around: window.convertToScreen(host.convert(toolbar.frame.insetBy(dx: -16, dy: -16), to: nil)),
                                   to: dir.appendingPathComponent("10i-粗细拉条.png"))
        }
        session.debugSelectTool(nil)
        session.debugSetStyle(AnnotationStyle())

        // 全屏模式：工具栏在屏幕底部中央，标注保留
        session.toggleMode()
        check("全屏模式工具栏在底部中央", abs(toolbar.frame.midX - (toolbar.superview?.bounds.midX ?? 0)) < 2 && toolbar.frame.minY < 60,
              "\(toolbar.frame)")
        session.toggleMode()
        check("切换模式后标注保留", annotator.document.annotations.count == 12, "\(annotator.document.annotations.count) 个")
    }

    private static func pngFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
    }

    /// 检查保存的文件
    private static func checkFile(outputDir: URL, expectedPixels: CGSize, scale: CGFloat, check: Checks) {
        guard let file = pngFiles(in: outputDir).first else {
            return check("保存 PNG 文件", false, "输出目录里没有 PNG")
        }
        check("文件名带日期时间", file.lastPathComponent.hasPrefix("截图 20"), file.lastPathComponent)
        let info = imageInfo(try? Data(contentsOf: file))
        check("文件为原生像素尺寸", info?.size == expectedPixels, "期望 \(expectedPixels)，得到 \(String(describing: info?.size))")
        check("文件写入色彩配置文件", info?.profile?.contains("sRGB") == true, "得到 \(info?.profile ?? "无")")
        check("文件 DPI = 72 × 倍数", info?.dpi == 72 * scale, "得到 \(String(describing: info?.dpi))")
        check("文件不含多余的 alpha 通道", info?.hasAlpha == false)
    }

    /// 检查剪贴板内容（读取剪贴板相当于「粘贴」）
    private static func checkClipboard(expectedPixels: CGSize, check: Checks) {
        let pasteboard = NSPasteboard(name: .init("local.snap.selftest"))
        let png = imageInfo(pasteboard.data(forType: .png))
        check("剪贴板 PNG 为原生像素尺寸", png?.size == expectedPixels, "得到 \(String(describing: png?.size))")
        check("剪贴板按需提供 TIFF", imageInfo(pasteboard.data(forType: .tiff))?.size == expectedPixels)
    }

    /// 屏幕上某一点实际显示的颜色（sRGB）
    private static func compositePixel(at point: CGPoint) async -> (r: UInt8, g: UInt8, b: UInt8)? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snap-probe.png")
        await captureComposite(around: CGRect(x: point.x, y: point.y, width: 1, height: 1), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return pixel(in: url, x: 0, y: 0)
    }

    private static func centerPixel(of image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8)? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snap-center.png")
        guard let data = ImageEncoder.encode(image, format: .png, quality: 1, scale: 1) else { return nil }
        try? data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return pixel(in: url, x: image.width / 2, y: image.height / 2)
    }

    /// 读取文件中某个像素的 sRGB 颜色（x、y 以图像左上角为原点）
    private static func pixel(in file: URL, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        return (bytes[0], bytes[1], bytes[2])
    }

    /// 检查 JPEG / HEIC 编码、Display P3 配置文件、1x 缩小
    private static func checkEncoder(check: Checks) {
        // 合成一张 400×300 像素、Display P3、2x 的图
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.setFillColor(CGColor(colorSpace: p3, components: [1, 0.2, 0.1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        guard let image = ctx.makeImage() else { return }

        for format in [ImageFormat.jpeg, .heic, .png] {
            let info = imageInfo(ImageEncoder.encode(image, format: format, quality: 0.95, scale: 2))
            check("\(format.title) 编码：尺寸、P3 配置文件、DPI 144",
                  info?.size == CGSize(width: 400, height: 300) && info?.profile?.contains("P3") == true && info?.dpi == 144,
                  "得到 \(String(describing: info))")
        }
        let small = ImageEncoder.downscaled(image, by: 2)
        check("按 1x 输出：400×300 → 200×150，保留 P3", small?.width == 200 && small?.height == 150
              && (small?.colorSpace?.name as String?) == (CGColorSpace.displayP3 as String))
    }

    private struct ImageInfo: CustomStringConvertible {
        let size: CGSize
        let profile: String?
        let dpi: CGFloat?
        let hasAlpha: Bool
        var description: String { "\(Int(size.width))×\(Int(size.height)) \(profile ?? "无配置文件") dpi=\(dpi ?? 0) alpha=\(hasAlpha)" }
    }

    private static func imageInfo(_ data: Data?) -> ImageInfo? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return ImageInfo(size: CGSize(width: width, height: height),
                         profile: props[kCGImagePropertyProfileName] as? String,
                         dpi: (props[kCGImagePropertyDPIWidth] as? NSNumber).map { CGFloat($0.doubleValue) },
                         hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false)
    }

    /// 截取屏幕上某块区域的「实际显示结果」（包含 Snap 自己的遮罩），只保存这一小块
    static func captureComposite(around globalRect: CGRect, to url: URL) async {
        // 测内存时关掉：每次都要截整屏，会把峰值内存撑高，不代表真实使用
        if ProcessInfo.processInfo.environment["SNAP_UITEST_NOCAPTURE"] != nil { return }
        guard let screen = NSScreen.screen(containing: CGPoint(x: globalRect.midX, y: globalRect.midY)),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        guard let full = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return }
        let f = screen.frame
        let crop = CGRect(x: (globalRect.minX - f.minX) * scale, y: (f.maxY - globalRect.maxY) * scale,
                          width: globalRect.width * scale, height: globalRect.height * scale).integral
        guard let image = full.cropping(to: crop) else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// 记录每一项检查的结果（同时记下当时的内存占用，用来定位哪一步占内存）
    final class Checks {
        private(set) var lines: [String] = []
        func callAsFunction(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            lines.append("\(ok ? "✓" : "✗") \(name)\(ok ? "" : "：\(detail())")  [\(DebugUITest.footprintMB()) MB]")
        }
        /// 只记录信息，不算通过或失败
        func note(_ text: String) {
            lines.append("ℹ︎ \(text)")
        }
    }

    /// 当前进程的内存占用（与活动监视器的「内存」一致）
    nonisolated static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    private static func report(_ lines: [String], to dir: URL) {
        let text = lines.joined(separator: "\n")
        try? text.write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        Log.capture.notice("界面自测完成：\(lines.filter { $0.hasPrefix("✓") }.count)/\(lines.count) 通过")
        quitAfterTest()
    }

    /// 自测结束后退出这份调试版，菜单栏里不留下多余的 Snap 图标。
    /// 要留着检查（例如看内存）时加 --env SNAP_TEST_KEEP_RUNNING=1
    static func quitAfterTest() {
        guard ProcessInfo.processInfo.environment["SNAP_TEST_KEEP_RUNNING"] == nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            NSApp.terminate(nil)
        }
    }
}
#endif

#if DEBUG
extension NSEvent {
    /// 自测用：同一个按键加上 ⌘
    var withCommand: NSEvent {
        NSEvent.keyEvent(with: type, location: locationInWindow, modifierFlags: modifierFlags.union(.command),
                         timestamp: timestamp, windowNumber: windowNumber, context: nil,
                         characters: characters ?? "", charactersIgnoringModifiers: charactersIgnoringModifiers ?? "",
                         isARepeat: isARepeat, keyCode: keyCode)!
    }
}
#endif

#if DEBUG
import AVFoundation

/// 录屏流程自测（只编进 debug 版本）：选区交互、选项条、⌥S 切换 / 停止，并真实录制 2 秒后核对文件参数。
/// 录到的视频只读取尺寸、编码等参数，核对完立即删除，不查看画面内容。
/// 用法：open --env SNAP_RECTEST=/输出目录 build/Snap.app
@MainActor
enum DebugRecordingTest {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["SNAP_RECTEST"] else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        RecordingManager.debugOutputDirectory = dir
        snapshotDirectory = dir
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let check = DebugUITest.Checks()
            await run(check: check)
            try? check.lines.joined(separator: "\n").write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            Log.capture.notice("录屏自测完成：\(check.lines.filter { $0.hasPrefix("✓") }.count)/\(check.lines.count) 通过")
            DebugUITest.quitAfterTest()
        }
    }

    private static func key(_ code: Int, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code))!
    }

    private static var snapshotDirectory: URL?

    /// 把 Snap 自己的视图画成 PNG 检查布局（离屏绘制：磨砂只画出暖色底，不包含后面的屏幕画面）
    private static func snapshot(_ view: NSView?, _ name: String) {
        guard let dir = snapshotDirectory else { return }
        DebugSnapshots.renderOverlay(view, to: dir.appendingPathComponent(name))
    }

    /// 录屏缩略图的布局图：封面用合成的渐变图，不用真实录屏画面
    private static func snapshotRecordingThumbnail(scale: CGFloat) async {
        let width = Int(240 * scale), height = Int(135 * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: [CGColor(srgbRed: 0.35, green: 0.45, blue: 0.6, alpha: 1),
                                                 CGColor(srgbRed: 0.85, green: 0.6, blue: 0.45, alpha: 1)] as CFArray,
                                        locations: [0, 1]) else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        guard let image = context.makeImage() else { return }
        let view = ThumbnailView(image: image, size: CGSize(width: 240, height: 135), scale: scale, kind: .recording(duration: 83))
        let window = NSPanel(contentRect: CGRect(x: -20_000, y: -20_000, width: 240, height: 135),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        view.debugSetHovered(true)
        try? await Task.sleep(for: .milliseconds(300))
        snapshot(view, "rec-3-录屏缩略图（合成封面）.png")
        window.close()
    }

    /// 用 AVAssetReader 解出音轨，计算峰值和第一次超过阈值的时间（秒，从视频起点算）
    private static func loudness(of track: AVAssetTrack, in asset: AVAsset) async -> (peak: Float, onset: Double?) {
        guard let reader = try? AVAssetReader(asset: asset) else { return (0, nil) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { return (0, nil) }
        let videoStart = (try? await asset.loadTracks(withMediaType: .video).first?.load(.timeRange).start) ?? .zero
        var peak: Float = 0
        var onset: Double?
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / 4)
            _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            let start = CMTimeGetSeconds(CMTimeSubtract(buffer.presentationTimeStamp, videoStart))
            for (i, sample) in samples.enumerated() where abs(sample) > peak {
                peak = abs(sample)
                if onset == nil, peak > 0.02 { onset = start + Double(i / 2) / 48_000 }
            }
        }
        return (peak, onset)
    }

    /// 混音器单元测试：用合成的正弦波（不用真实声音）验证混音、单声道转立体声、重采样、静音、时间戳连续
    private static func testMixer(check: DebugUITest.Checks) {
        let start = CMTime(seconds: 100, preferredTimescale: 1_000_000_000)
        func sine(_ format: AVAudioFormat, frames: Int, from index: Int, frequency: Double, amplitude: Float) -> CMSampleBuffer? {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
            pcm.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<Int(format.channelCount) {
                for i in 0..<frames {
                    let value = amplitude * Float(sin(2 * .pi * frequency * Double(index + i) / format.sampleRate))
                    if let data = pcm.floatChannelData { data[channel][i] = value }
                    if let data = pcm.int16ChannelData { data[channel][i] = Int16(value * 32767) }
                }
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
                                            presentationTimeStamp: CMTimeAdd(start, CMTime(value: CMTimeValue(index), timescale: CMTimeScale(format.sampleRate))),
                                            decodeTimeStamp: .invalid)
            var buffer: CMSampleBuffer?
            guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                       refcon: nil, formatDescription: format.formatDescription, sampleCount: frames,
                                       sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                       sampleSizeArray: nil, sampleBufferOut: &buffer) == noErr, let buffer,
                  CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault,
                                                                 blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                                                                 bufferList: pcm.audioBufferList) == noErr else { return nil }
            return buffer
        }
        // 系统声音：与 ScreenCaptureKit 相同的 48kHz 立体声浮点；麦克风：44.1kHz 单声道 16 位整数
        let systemFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 1, interleaved: false)!

        func mix(_ sources: Set<AudioMixer.Source>, feed: Set<AudioMixer.Source>, muted: Bool = false)
            -> (frames: Int, contiguous: Bool, peakL: Float, peakR: Float, beforeFinal: Int) {
            var outputs: [CMSampleBuffer] = []
            guard let mixer = try? AudioMixer(startTime: start, sources: sources, onOutput: { outputs.append($0) }) else {
                return (0, false, 0, 0, 0)
            }
            mixer.isMicrophoneMuted = muted
            // 交错送入 1 秒：系统声音每块 1024 帧，麦克风每块 882 帧（20ms）
            var systemIndex = 0, micIndex = 0
            while systemIndex < 48_000 || micIndex < 44_100 {
                let systemTime = Double(systemIndex) / 48_000, micTime = Double(micIndex) / 44_100
                if systemIndex < 48_000, systemTime <= micTime || micIndex >= 44_100 {
                    let frames = min(1024, 48_000 - systemIndex)
                    if feed.contains(.system), let b = sine(systemFormat, frames: frames, from: systemIndex, frequency: 440, amplitude: 0.25) {
                        mixer.add(b, from: .system, at: b.presentationTimeStamp)
                    }
                    systemIndex += frames
                } else {
                    let frames = min(882, 44_100 - micIndex)
                    if feed.contains(.microphone), let b = sine(micFormat, frames: frames, from: micIndex, frequency: 440, amplitude: 0.25) {
                        mixer.add(b, from: .microphone, at: b.presentationTimeStamp)
                    }
                    micIndex += frames
                }
            }
            let beforeFinal = outputs.reduce(0) { $0 + $1.numSamples }
            mixer.flush(final: true, until: CMTimeAdd(start, CMTime(value: 1, timescale: 1)))
            var expected = start, contiguous = true, peakL: Float = 0, peakR: Float = 0, frames = 0
            for buffer in outputs {
                if buffer.presentationTimeStamp != expected { contiguous = false }
                expected = CMTimeAdd(buffer.presentationTimeStamp, CMTime(value: CMTimeValue(buffer.numSamples), timescale: 48_000))
                frames += buffer.numSamples
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var samples = [Float](repeating: 0, count: buffer.numSamples * 2)
                _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                // 跳过开头 50ms（重采样器的起始延迟）
                let skip = max(0, 2400 - Int(CMTimeGetSeconds(CMTimeSubtract(buffer.presentationTimeStamp, start)) * 48_000))
                for i in stride(from: skip * 2, to: samples.count, by: 2) {
                    peakL = max(peakL, abs(samples[i]))
                    peakR = max(peakR, abs(samples[i + 1]))
                }
            }
            return (frames, contiguous, peakL, peakR, beforeFinal)
        }

        let both = mix([.system, .microphone], feed: [.system, .microphone])
        check("混音：两路叠加成一路（峰值 \(String(format: "%.2f", both.peakL))，单路 0.25）",
              both.peakL > 0.42 && both.peakL < 0.52 && abs(both.peakL - both.peakR) < 0.02)
        check("混音：输出正好 1 秒（48000 帧）且时间戳连续", both.frames == 48_000 && both.contiguous, "\(both.frames) 帧")
        let micOnly = mix([.microphone], feed: [.microphone])
        check("混音：44.1kHz 单声道麦克风 → 48kHz，左右声道相同", micOnly.frames == 48_000
              && micOnly.peakL > 0.22 && micOnly.peakL < 0.27 && abs(micOnly.peakL - micOnly.peakR) < 0.001,
              "\(micOnly.frames) 帧，峰值 \(micOnly.peakL) / \(micOnly.peakR)")
        let muted = mix([.system, .microphone], feed: [.system, .microphone], muted: true)
        check("混音：麦克风静音后只剩系统声音", muted.peakL > 0.22 && muted.peakL < 0.27, "峰值 \(muted.peakL)")
        let stalled = mix([.system, .microphone], feed: [.system])
        check("混音：麦克风一直没数据时不卡住系统声音（落后 0.5 秒后照常输出）",
              stalled.beforeFinal >= 20_000 && stalled.frames == 48_000, "停止前已输出 \(stalled.beforeFinal) 帧")
    }

    private static func run(check: DebugUITest.Checks) async {
        testMixer(check: check)
        let coordinator = CaptureCoordinator.shared
        let manager = RecordingManager.shared
        guard let screen = NSScreen.underMouse else { return check("找到屏幕", false) }
        let o = screen.frame.origin
        let scale = screen.backingScaleFactor
        func g(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x, y: o.y + y) }
        let option2 = key(kVK_ANSI_S, .option, "ß")

        // 1. 选区界面
        coordinator.beginRecording()
        try? await Task.sleep(for: .milliseconds(600))
        guard let session = coordinator.debugRecordingSession else { return check("⌥S 打开录屏选区", false) }
        check("⌥S 打开录屏选区（每块屏幕一个遮罩）", session.debugOverlayCount == NSScreen.screens.count)
        check("提示条：区域录屏", session.debugHintText.hasPrefix("区域录屏 · ⌥S 切换全屏 · Enter 开始 · Esc 取消"),
              session.debugHintText)

        // 2. 拖出选区 → 选项条出现在选区下方
        session.overlayMouseDown(at: g(100, 100))
        session.overlayMouseDragged(to: g(200, 180))
        session.overlayMouseDragged(to: g(300, 250))
        session.overlayMouseUp(at: g(300, 250))
        let selection = session.debugSelector.selection?.offsetBy(dx: -o.x, dy: -o.y)
        check("拖出录屏选区", selection == CGRect(x: 100, y: 100, width: 200, height: 150), "\(String(describing: selection))")
        let bar = session.debugOptionsBar
        check("选项条出现在选区下方", bar.superview != nil && bar.frame.maxY <= 100 - 4, "\(bar.frame)")

        // 3. ⌥S 在区域 / 全屏之间切换，选区保留；忽略按住不放的重复
        _ = session.overlayKeyDown(option2)
        check("⌥S 切到全屏录屏", session.mode == .fullscreen && session.debugHintText.hasPrefix("全屏录屏 · ⌥S 切换区域"))
        check("全屏模式选项条在底部中央", abs(bar.frame.midX - (bar.superview?.bounds.midX ?? 0)) < 2, "\(bar.frame)")
        let repeatEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: "ß", charactersIgnoringModifiers: "s", isARepeat: true,
                                           keyCode: UInt16(kVK_ANSI_S))!
        _ = session.overlayKeyDown(repeatEvent)
        check("按住不放的重复被忽略", session.mode == .fullscreen)
        _ = session.overlayKeyDown(option2)
        check("再按 ⌥S 切回区域，选区保留", session.mode == .region
              && session.debugSelector.selection?.offsetBy(dx: -o.x, dy: -o.y) == CGRect(x: 100, y: 100, width: 200, height: 150))

        // 4. 选项条：切换后写入设置（测完恢复原值）
        let cursorBefore = Preferences.shared.recordingShowsCursor
        bar.debugToggleCursor()
        check("选项条切换「显示指针」并记住", Preferences.shared.recordingShowsCursor == !cursorBefore)
        bar.debugToggleCursor()
        let fpsBefore = Preferences.shared.recordingFrameRate
        bar.debugSetFrameRate(.fps60)

        // 5. 录屏选区进行中按 ⌥A 不截图
        coordinator.handleHotkey(.screenshot)
        check("录屏选区中 ⌥A 不会开始截图", coordinator.debugSession == nil)

        // 6. 麦克风：自测不录真实的麦克风声音。
        //    没有权限时临时打开「录制麦克风」，验证「没有权限照常录屏 + 控制条提示」；有权限时临时关掉。测完恢复。
        let microphoneBefore = Preferences.shared.recordMicrophone
        PermissionManager.shared.refresh()
        let microphoneAuthorized = PermissionManager.shared.microphoneGranted
        Preferences.shared.recordMicrophone = !microphoneAuthorized
        // 系统声音：临时打开，测完恢复
        let systemAudioBefore = Preferences.shared.recordSystemAudio
        Preferences.shared.recordSystemAudio = true
        defer {
            Preferences.shared.recordMicrophone = microphoneBefore
            Preferences.shared.recordSystemAudio = systemAudioBefore
        }
        let pasteboard = NSPasteboard(name: .init("local.snap.selftest"))
        ThumbnailManager.shared.pasteboard = pasteboard

        // 7. Enter 开始录制 → 控制条 + 红框
        let region = CGRect(x: o.x + 100, y: o.y + 100, width: 200, height: 150)
        let wallStart = Date()
        _ = session.overlayKeyDown(key(kVK_Return))
        try? await Task.sleep(for: .milliseconds(1500))
        check("Enter 开始录制", manager.isRecording, "状态 \(manager.state)")
        check("开始录制后选区界面关闭", coordinator.debugRecordingSession == nil)
        guard let controlBar = manager.debugControlBar, let frameWindow = manager.debugFrameWindow else {
            return check("录制中显示控制条和红框", false)
        }
        check("录制中显示浮动控制条", controlBar.isVisible)
        check("控制条不挡住录制区域", !controlBar.debugBarFrame.intersects(region), "\(controlBar.debugBarFrame)")
        check("控制条不抢键盘焦点", !controlBar.canBecomeKey)
        check("红框贴在录制区域外侧", frameWindow.isVisible && frameWindow.frame == region.insetBy(dx: -3, dy: -3), "\(frameWindow.frame)")
        check("红框不拦截鼠标", frameWindow.ignoresMouseEvents)
        check("录制中计时在走", manager.elapsed > 0.3, "\(manager.elapsed)")
        snapshot(controlBar.contentView, "rec-1-控制条.png")
        if microphoneAuthorized {
            check("麦克风未打开时控制条不显示麦克风按钮", !controlBar.debugMicrophoneVisible)
        } else {
            check("没有麦克风权限：照常录屏，控制条显示麦克风不可用", manager.microphoneUnavailable && controlBar.debugMicrophoneVisible
                  && !manager.capturesMicrophone)
        }

        // 8. 录 1.5 秒 → 暂停 1.5 秒 → 继续，同时用另一个进程播放系统提示音「Tink」→ 1.2 秒后 ⌥S 停止
        try? await Task.sleep(for: .milliseconds(1500))
        controlBar.debugClickPause()
        check("控制条暂停：状态变为暂停，红框变虚线", manager.state == .paused && frameWindow.debugIsDashed)
        let pausedElapsed = manager.elapsed
        try? await Task.sleep(for: .milliseconds(300))
        snapshot(controlBar.contentView, "rec-2-控制条-暂停.png")
        try? await Task.sleep(for: .milliseconds(1500))
        check("暂停期间计时停住", abs(manager.elapsed - pausedElapsed) < 0.05, "\(pausedElapsed) → \(manager.elapsed)")
        check("控制条显示的时长与实际一致", controlBar.debugTimeText == StatusBarController.format(manager.elapsed),
              controlBar.debugTimeText)
        controlBar.debugClickPause()
        check("再点继续录制，红框恢复实线", manager.state == .recording && !frameWindow.debugIsDashed)
        let soundStart = manager.elapsed
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["/System/Library/Sounds/Tink.aiff"]
        try? player.run()
        try? await Task.sleep(for: .milliseconds(1200))
        let wallDuration = Date().timeIntervalSince(wallStart)
        let elapsedBeforeStop = manager.elapsed
        coordinator.handleHotkey(.recording)
        try? await Task.sleep(for: .milliseconds(1500))
        check("录制中 ⌥S 停止录制", manager.state == .idle, "状态 \(manager.state)")
        check("停止后控制条和红框消失", manager.debugControlBar == nil && manager.debugFrameWindow == nil
              && !controlBar.isVisible && !frameWindow.isVisible)
        bar.debugSetFrameRate(fpsBefore)

        // 9. 核对文件参数（不看画面，声音只计算响度和时间点），然后删除
        guard let url = manager.debugLastOutput else { return check("录屏文件已保存", false) }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let track = try? await asset.loadTracks(withMediaType: .video).first
        let size = (try? await track?.load(.naturalSize)) ?? .zero
        let formats = (try? await track?.load(.formatDescriptions)) ?? []
        let codec = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
        let extensions = formats.first.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] } ?? [:]
        let primaries = extensions[kCVImageBufferColorPrimariesKey as String] as? String ?? "无"
        let fps = (try? await track?.load(.nominalFrameRate)) ?? 0
        let videoRange = (try? await track?.load(.timeRange)) ?? .zero
        let expectedSize = CGSize(width: CGFloat(Int(200 * scale) & ~1), height: CGFloat(Int(150 * scale) & ~1))
        check("MP4 为原生像素尺寸", size == expectedSize, "期望 \(expectedSize)，得到 \(size)")
        let expectedCodec = Preferences.shared.videoCodec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        check("编码与设置一致（\(Preferences.shared.videoCodec == .hevc ? "HEVC" : "H.264")）", codec == expectedCodec)
        check("写入色彩信息", primaries != "无", primaries)
        check("暂停的 1.5 秒不在视频里（从按 Enter 起经过 \(String(format: "%.1f", wallDuration)) 秒，视频 \(String(format: "%.2f", duration)) 秒）",
              duration < wallDuration - 1.2 && abs(duration - elapsedBeforeStop) < 0.3, "计时 \(elapsedBeforeStop) 秒")
        Log.capture.notice("录屏文件参数：\(Int(size.width))×\(Int(size.height))，\(String(format: "%.2f", duration)) 秒，平均 \(String(format: "%.1f", fps)) fps，色域 \(primaries, privacy: .public)")

        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        if Preferences.shared.recordSystemAudio {
            check("只有一条音轨（系统声音与麦克风混在一起）", audioTracks.count == 1, "\(audioTracks.count) 条")
            if let audio = audioTracks.first {
                let description = (try? await audio.load(.formatDescriptions))?.first
                let asbd = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                check("音轨为 AAC 48kHz 立体声", asbd?.mFormatID == kAudioFormatMPEG4AAC && asbd?.mSampleRate == 48_000
                      && asbd?.mChannelsPerFrame == 2, "\(String(describing: asbd))")
                let rate = (try? await audio.load(.estimatedDataRate)) ?? 0
                check("音轨码率 256kbps（实测 \(Int(rate / 1000)) kbps）", rate > 230_000 && rate < 280_000)
                let audioRange = (try? await audio.load(.timeRange)) ?? .zero
                let startGap = abs(CMTimeGetSeconds(audioRange.start) - CMTimeGetSeconds(videoRange.start))
                let lengthGap = abs(CMTimeGetSeconds(audioRange.duration) - CMTimeGetSeconds(videoRange.duration))
                check("音画对齐：起点相差 < 30ms，长度相差 < 150ms", startGap < 0.03 && lengthGap < 0.15,
                      "起点差 \(Int(startGap * 1000))ms，长度差 \(Int(lengthGap * 1000))ms")
                let (peak, onset) = await Self.loudness(of: audio, in: asset)
                check("录到了系统声音（提示音峰值 \(String(format: "%.2f", peak))）", peak > 0.02)
                // 提示音在「继续」之后才播放；如果暂停没有从声音里扣掉，它会晚 1.5 秒出现
                check("声音也扣掉了暂停时长：提示音出现在 \(String(format: "%.2f", onset ?? -1)) 秒（继续录制时为 \(String(format: "%.2f", soundStart)) 秒）",
                      onset.map { $0 >= soundStart - 0.1 && $0 < soundStart + 0.8 } ?? false)
                Log.capture.notice("音轨：码率约 \(Int(rate / 1000)) kbps，峰值 \(peak)，起点差 \(startGap)，长度差 \(lengthGap)")
            }
        } else {
            check("系统声音关闭时没有音轨", audioTracks.isEmpty)
        }

        // 10. 录屏缩略图：时长标签、按钮、拷贝文件、单击预览
        let thumbnails = ThumbnailManager.shared
        check("停止后右下角出现录屏缩略图", thumbnails.debugNewestVideoURL == url)
        if let view = thumbnails.debugNewestView {
            check("缩略图显示时长", view.debugDurationText.hasSuffix(StatusBarController.format(duration.rounded())), view.debugDurationText)
            thumbnails.debugHoverNewest()
            check("悬停出现：关闭、移到废纸篓、导出为 GIF、拷贝文件、在访达中显示",
                  Set(view.debugVisibleButtons) == ["关闭", "移到废纸篓", "导出为 GIF", "拷贝文件", "在访达中显示"], "\(view.debugVisibleButtons)")
            view.onCopy?()
            let copied = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
            check("拷贝文件：剪贴板里是这个视频文件", copied?.first?.standardizedFileURL == url.standardizedFileURL && view.debugCopySymbol == "checkmark")
            view.onOpen?()
            try? await Task.sleep(for: .milliseconds(800))
            check("单击缩略图打开预览窗口并开始播放", VideoPreviewWindowController.debugOpenCount == 1
                  && thumbnails.debugNewestVideoURL == nil)
            VideoPreviewWindowController.close(for: url)
            try? await Task.sleep(for: .milliseconds(300))
            check("预览窗口关闭后释放", VideoPreviewWindowController.debugOpenCount == 0)
        }
        thumbnails.debugDismissAll()
        await snapshotRecordingThumbnail(scale: scale)
        thumbnails.pasteboard = .general
        pasteboard.clearContents()
        try? FileManager.default.removeItem(at: url)
        check("自测录屏文件已删除", !FileManager.default.fileExists(atPath: url.path))

        // 11. 选区阶段按 Esc 取消
        coordinator.beginRecording()
        try? await Task.sleep(for: .milliseconds(600))
        if let again = coordinator.debugRecordingSession {
            _ = again.overlayKeyDown(key(kVK_Escape))
            check("选区阶段 Esc 取消", coordinator.debugRecordingSession == nil && manager.state == .idle)
        }

        // 12. 全屏录制 3 秒：测录制中的内存，核对尺寸后删除
        guard ProcessInfo.processInfo.environment["SNAP_RECTEST_FULL"] != nil else { return }
        let before = DebugUITest.footprintMB()
        coordinator.beginRecording()
        try? await Task.sleep(for: .milliseconds(600))
        guard let full = coordinator.debugRecordingSession else { return check("全屏录制", false) }
        _ = full.overlayKeyDown(option2)
        _ = full.overlayKeyDown(key(kVK_Return))
        try? await Task.sleep(for: .seconds(3))
        let during = DebugUITest.footprintMB()
        if let frameWindow = manager.debugFrameWindow, let controlBar = manager.debugControlBar {
            check("全屏录制：红框沿屏幕边缘", frameWindow.frame == screen.frame, "\(frameWindow.frame)")
            check("全屏录制：控制条在屏幕底部中央", abs(controlBar.debugBarFrame.midX - screen.visibleFrame.midX) < 2
                  && controlBar.debugBarFrame.minY < screen.visibleFrame.minY + 60, "\(controlBar.debugBarFrame)")
        }
        coordinator.handleHotkey(.recording)
        try? await Task.sleep(for: .milliseconds(2000))
        ThumbnailManager.shared.debugDismissAll()
        try? await Task.sleep(for: .milliseconds(500))
        let after = DebugUITest.footprintMB()
        check("全屏录制内存：录制前 \(before) MB，录制中 \(during) MB，结束后 \(after) MB", during < 150 && after < 60)
        if let url = manager.debugLastOutput {
            let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
            let size = (try? await track?.load(.naturalSize)) ?? .zero
            let expected = CGSize(width: CGFloat(Int(screen.frame.width * scale) & ~1), height: CGFloat(Int(screen.frame.height * scale) & ~1))
            check("全屏录制为原生分辨率 \(Int(expected.width))×\(Int(expected.height))", size == expected, "得到 \(size)")
            // 全屏录屏转 GIF（15fps，最宽 960）：测耗时和内存峰值
            let sampler = Task.detached { () -> Int in
                var peak = 0
                while !Task.isCancelled {
                    peak = max(peak, DebugUITest.footprintMB())
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return peak
            }
            let gifStart = Date()
            let gif = try? await GIFExporter.export(video: url, options: .init(fps: 15, maxWidth: 960)) { _ in }
            let gifTime = Date().timeIntervalSince(gifStart)
            sampler.cancel()
            let gifPeak = await sampler.value
            try? await Task.sleep(for: .milliseconds(500))
            let gifSize = gif.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
            check("全屏录屏转 GIF：\(String(format: "%.1f", gifTime)) 秒，\(gifSize / 1024) KB，内存峰值 \(gifPeak) MB，结束后 \(DebugUITest.footprintMB()) MB",
                  gif != nil && gifPeak < 120)
            if let gif { try? FileManager.default.removeItem(at: gif) }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// 自测用的假大模型服务端：按 Claude / OpenAI 的流式格式分几段返回「你好，世界。」
final class MockLLMServer: URLProtocol, @unchecked Sendable {
    struct Captured { let headers: [String: String]; let body: Data? }
    nonisolated(unsafe) static var lastRequest: Captured?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable { let n = stream.read(buffer, maxLength: 4096); if n <= 0 { break }; data.append(buffer, count: n) }
            buffer.deallocate()
            stream.close()
            body = data
        }
        Self.lastRequest = Captured(headers: request.allHTTPHeaderFields ?? [:], body: body)
        let url = request.url!
        let isClaude = url.host == "api.anthropic.com"
        if request.value(forHTTPHeaderField: "x-api-key") == "bad" {
            return respond(401, [#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#])
        }
        if url.host == "quota.test" {
            return respond(429, [#"{"error":{"message":"You exceeded your current quota","code":"insufficient_quota"}}"#])
        }
        let chunks: [String] = isClaude ? [
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"你好\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"，世界。\"}}\n\n",
            "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n",
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
        ] : [
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"，世界。\"}}]}\n\n",
            "data: [DONE]\n\n",
        ]
        respond(200, chunks, contentType: "text/event-stream")
    }

    private func respond(_ status: Int, _ chunks: [String], contentType: String = "application/json") {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: Data(chunk.utf8))
            Thread.sleep(forTimeInterval: 0.02)   // 模拟一段一段地来
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif