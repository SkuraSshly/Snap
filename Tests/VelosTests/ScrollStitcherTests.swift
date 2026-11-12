import CoreGraphics
import Foundation
import Testing
@testable import Velos

/// 长截图拼接的行为基线：用合成的「页面」（每一行像素都不一样）切出一帧帧画面喂给拼接器，
/// 检查每一步报告的事件和最终拼出来的图（逐行和页面比对）
@Suite struct ScrollStitcherTests {
    static let width = 64

    /// 页面的第 row 行：每 6 个像素换一种颜色，颜色由行号和列号算出（相邻行、不同行都不一样，也不是纯色）
    static func pageRow(_ row: Int, seed: Int = 0) -> [UInt32] {
        (0..<width).map { x in
            var h = UInt32(truncatingIfNeeded: (row &* 2654435761) ^ ((x / 6 + seed * 97) &* 40503))
            h ^= h >> 15
            return 0xFF00_0000 | (h & 0x00FF_FFFF)
        }
    }

    /// 由若干行组成一帧（BGRA、不透明）
    static func frame(_ rows: [[UInt32]]) -> PixelFrame {
        var data = Data(capacity: rows.count * width * 4)
        for row in rows {
            row.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        return PixelFrame(width: width, height: rows.count, bytesPerRow: width * 4, data: data,
                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// 页面从 offset 行开始、可见 height 行的画面；上面可以有固定的 header 行，下面有固定的 footer 行
    static func window(offset: Int, height: Int, header: Int = 0, footer: Int = 0) -> PixelFrame {
        let top = (0..<header).map { pageRow($0, seed: 1) }
        let body = (offset..<(offset + height)).map { pageRow($0) }
        let bottom = (0..<footer).map { pageRow($0, seed: 2) }
        return frame(top + body + bottom)
    }

    /// 拼好的图读回成行（和合成时一样的格式）
    static func rows(of image: CGImage) -> [[UInt32]] {
        guard let frame = PixelFrame(image: image) else { return [] }
        return frame.data.withUnsafeBytes { raw in
            (0..<frame.height).map { y in
                (0..<frame.width).map { x in raw.load(fromByteOffset: y * frame.bytesPerRow + x * 4, as: UInt32.self) }
            }
        }
    }

    @Test func 第一帧报告开始长度是一屏() {
        var stitcher = ScrollStitcher(axis: .vertical)
        #expect(stitcher.add(Self.window(offset: 0, height: 100)) == .started)
        #expect(stitcher.length == 100)
    }

    @Test func 一路往下滚每一步都接上滚过的行数() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        stitcher.add(Self.window(offset: 0, height: 100))
        for step in 1...15 {
            #expect(stitcher.add(Self.window(offset: step * 7, height: 100)) == .appended(7))
        }
        #expect(stitcher.length == 100 + 15 * 7)
        let image = try #require(stitcher.makeImage())
        let expected = (0..<(100 + 15 * 7)).map { Self.pageRow($0) }
        #expect(Self.rows(of: image) == expected)
    }

    @Test func 画面没变报告未变化() {
        var stitcher = ScrollStitcher(axis: .vertical)
        stitcher.add(Self.window(offset: 0, height: 100))
        stitcher.add(Self.window(offset: 20, height: 100))
        #expect(stitcher.add(Self.window(offset: 20, height: 100)) == .unchanged)
    }

    @Test func 往回滚报告移动而不拼接() {
        var stitcher = ScrollStitcher(axis: .vertical)
        stitcher.add(Self.window(offset: 0, height: 100))
        stitcher.add(Self.window(offset: 40, height: 100))
        let before = stitcher.length
        #expect(stitcher.add(Self.window(offset: 25, height: 100)) == .moved)
        #expect(stitcher.length == before)
    }

    @Test func 一下滚过整屏对不上() {
        var stitcher = ScrollStitcher(axis: .vertical)
        stitcher.add(Self.window(offset: 0, height: 100))
        stitcher.add(Self.window(offset: 10, height: 100))
        #expect(stitcher.add(Self.window(offset: 400, height: 100)) == .lost)
    }

    @Test func 顶部和底部固定的部分只出现一次() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let header = 20, footer = 12, visible = 70
        stitcher.add(Self.window(offset: 0, height: visible, header: header, footer: footer))
        for step in 1...10 {
            stitcher.add(Self.window(offset: step * 9, height: visible, header: header, footer: footer))
        }
        let image = try #require(stitcher.makeImage())
        let expected = (0..<header).map { Self.pageRow($0, seed: 1) }
            + (0..<(visible + 90)).map { Self.pageRow($0) }
            + (0..<footer).map { Self.pageRow($0, seed: 2) }
        #expect(stitcher.length == expected.count)
        #expect(Self.rows(of: image) == expected)
    }

    @Test func 到长度上限后不再拼接() {
        var stitcher = ScrollStitcher(axis: .vertical, maxLength: 130)
        stitcher.add(Self.window(offset: 0, height: 100))
        var events: [ScrollStitcher.Event] = []
        for step in 1...10 { events.append(stitcher.add(Self.window(offset: step * 10, height: 100))) }
        #expect(events.contains(.limitReached))
        #expect(stitcher.length <= 130)
    }

    /// 刚滚到时最下面一段还没画完（空白），下一帧画好了：拼出来的图里要换成画好的内容，不能留下空白
    @Test func 刚滚到时没画完的部分画好后自动换上() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let header = 10, visible = 80, footer = 10
        func unrendered(_ offset: Int) -> PixelFrame {
            var rows = (0..<header).map { Self.pageRow($0, seed: 1) } + (offset..<(offset + visible)).map { Self.pageRow($0) }
                + (0..<footer).map { Self.pageRow($0, seed: 2) }
            for i in (header + visible - 20)..<(header + visible) { rows[i] = [UInt32](repeating: 0xFFFF_FFFF, count: Self.width) }
            return Self.frame(rows)
        }
        stitcher.add(Self.window(offset: 0, height: visible, header: header, footer: footer))
        for offset in stride(from: 30, through: 300, by: 30) {
            stitcher.add(unrendered(offset))
            stitcher.add(Self.window(offset: offset, height: visible, header: header, footer: footer))
        }
        let image = try #require(stitcher.makeImage())
        let expected = (0..<header).map { Self.pageRow($0, seed: 1) } + (0..<(300 + visible)).map { Self.pageRow($0) }
            + (0..<footer).map { Self.pageRow($0, seed: 2) }
        #expect(Self.rows(of: image) == expected)
    }

    /// 选区里大部分区域不动、只有中间一条在滚（框了整个窗口，只有对话栏在滚）：真实的滚动不能被当成「没变」
    @Test func 大部分区域不动时仍能认出滚动() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let header = 120, footer = 120, visible = 60
        stitcher.add(Self.window(offset: 0, height: visible, header: header, footer: footer))
        for step in 1...8 {
            #expect(stitcher.add(Self.window(offset: step * 5, height: visible, header: header, footer: footer)) == .appended(5))
        }
        let image = try #require(stitcher.makeImage())
        #expect(Self.rows(of: image).count == header + visible + 40 + footer)
    }

    // MARK: - 一下滚太远

    /// 选区里大片不动（上下各有很高的固定区域），中间只有一窄条在滚：一下滚太远、和上一帧没有重叠时，
    /// 不能因为「大部分行没变」就当成原地重画，把错位的画面写进去——之后会接错位置，已经截过的内容又被接一遍。
    /// 应该报告对不上；用户往回滚到能对上的位置后，接着正常拼接
    @Test func 大片不动时一下滚太远不会拼错() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let header = 120, footer = 120, visible = 60
        func at(_ offset: Int) -> PixelFrame { Self.window(offset: offset, height: visible, header: header, footer: footer) }
        stitcher.add(at(0))
        stitcher.add(at(5))
        stitcher.add(at(10))
        #expect(stitcher.add(at(300)) == .lost)
        #expect(stitcher.add(at(305)) == .lost)
        #expect(stitcher.add(at(15)) == .appended(5))
        #expect(stitcher.add(at(20)) == .appended(5))
        let image = try #require(stitcher.makeImage())
        let expected = (0..<header).map { Self.pageRow($0, seed: 1) } + (0..<(visible + 20)).map { Self.pageRow($0) }
            + (0..<footer).map { Self.pageRow($0, seed: 2) }
        #expect(Self.rows(of: image) == expected)
    }

    /// 还没开始滚动时第一下就滚太远：也是对不上，不能把那一帧当成新的起点（否则开头和后面接不上）
    @Test func 第一下就滚太远时等滚回来再接() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let header = 120, footer = 120, visible = 60
        func at(_ offset: Int) -> PixelFrame { Self.window(offset: offset, height: visible, header: header, footer: footer) }
        stitcher.add(at(0))
        #expect(stitcher.add(at(400)) == .lost)
        #expect(stitcher.add(at(8)) == .appended(8))
        let image = try #require(stitcher.makeImage())
        let expected = (0..<header).map { Self.pageRow($0, seed: 1) } + (0..<(visible + 8)).map { Self.pageRow($0) }
            + (0..<footer).map { Self.pageRow($0, seed: 2) }
        #expect(Self.rows(of: image) == expected)
    }

    // MARK: - 跟丢后接回

    /// 往下滚时一下甩得太远、和上一次对上的画面没有重叠，而且还在继续往下滚：不用往回滚，
    /// 过一小会儿自动从当前画面接着拼，中间没截到的部分直接跳过（不重复、不错位）
    @Test func 往下甩太远时自动从当前画面接回() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let height = 100
        for offset in [0, 10, 20] { stitcher.add(Self.window(offset: offset, height: height)) }
        var events: [ScrollStitcher.Event] = []
        let far = (0..<ScrollStitcher.outrunFrames).map { 600 + $0 * 4 }
        for offset in far { events.append(stitcher.add(Self.window(offset: offset, height: height))) }
        #expect(events.dropLast().allSatisfy { $0 == .lost })
        #expect(events.last == .appended(height))
        let resumed = far.last!
        #expect(stitcher.add(Self.window(offset: resumed + 7, height: height)) == .appended(7))
        let image = try #require(stitcher.makeImage())
        let expected = (0..<(height + 20)).map { Self.pageRow($0) } + (resumed..<(resumed + height + 7)).map { Self.pageRow($0) }
        #expect(Self.rows(of: image) == expected)
    }

    /// 往回甩太远（回到已经拼过的地方）：不能从当前画面接上（那样会重复），一直等到滚回能对上的位置
    @Test func 往回甩太远时不接() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let height = 100
        for offset in stride(from: 0, through: 400, by: 20) { stitcher.add(Self.window(offset: offset, height: height)) }
        let length = stitcher.length
        for offset in stride(from: 150, to: 150 - ScrollStitcher.outrunFrames * 2 * 3, by: -3) {
            #expect(stitcher.add(Self.window(offset: offset, height: height)) != .appended(height))
        }
        #expect(stitcher.length == length)
        #expect(stitcher.add(Self.window(offset: 420, height: height)) == .appended(20))
        let image = try #require(stitcher.makeImage())
        #expect(Self.rows(of: image) == (0..<(420 + height)).map { Self.pageRow($0) })
    }

    /// 开头截到的是过渡画面（刚从调度中心回来、切换桌面的动画）：之后页面在正常滚动、却一直对不上它。
    /// 不能一直卡着不拼——换成正常的画面重新开始
    @Test func 开头截到过渡画面时换成正常画面重新开始() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let height = 100
        stitcher.add(Self.frame((0..<height).map { Self.pageRow($0, seed: 9) }))   // 和页面毫无关系的一张
        var events: [ScrollStitcher.Event] = []
        for step in 0...6 { events.append(stitcher.add(Self.window(offset: 300 + step * 10, height: height))) }
        #expect(events.contains { if case .appended = $0 { return true } else { return false } })
        let image = try #require(stitcher.makeImage())
        let rows = Self.rows(of: image)
        // 从某一张正常画面开始，后面连续、不重复
        let start = try #require((0..<400).first { rows[0] == Self.pageRow($0) })
        #expect(rows == (start..<(start + rows.count)).map { Self.pageRow($0) })
        #expect(start + rows.count == 300 + 60 + height)
    }

    /// 调度中心、切换桌面这类画面：和页面毫无关系，彼此之间又「像是在移动」（窗口缩略图缩放、上下移动），
    /// 像素有细微差别。拼到一半时打开、再回到原来的页面：不能把它接进长图，回来后接着正常拼
    static func missionControl(_ k: Int) -> PixelFrame {
        jittered(frame((0..<100).map { pageRow(5000 + k * 6 + $0, seed: 9) }), seed: k)
    }

    @Test func 拼到一半打开调度中心再回来接着拼() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let height = 100
        for offset in stride(from: 0, through: 60, by: 10) { stitcher.add(Self.window(offset: offset, height: height)) }
        for k in 0..<40 {
            let event = stitcher.add(Self.missionControl(k))
            #expect(event == .lost || event == .unchanged, "调度中心的画面被当成了页面：\(event)")
        }
        #expect(stitcher.add(Self.window(offset: 60, height: height)) == .unchanged)
        for offset in stride(from: 70, through: 120, by: 10) { #expect(stitcher.add(Self.window(offset: offset, height: height)) == .appended(10)) }
        let rows = Self.rows(of: try #require(stitcher.makeImage()))
        #expect(rows == (0..<(120 + height)).map { Self.pageRow($0) })
    }

    @Test func 还没开始拼时打开调度中心再回来照常拼() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let height = 100
        stitcher.add(Self.window(offset: 0, height: height))
        for k in 0..<40 { _ = stitcher.add(Self.missionControl(k)) }
        for offset in stride(from: 10, through: 50, by: 10) { stitcher.add(Self.window(offset: offset, height: height)) }
        let rows = Self.rows(of: try #require(stitcher.makeImage()))
        #expect(rows == (0..<(50 + height)).map { Self.pageRow($0) })
    }

    // MARK: - 半透明的顶栏、底栏

    /// 页面从 offset 行开始、可见 height 行；最上面 top 行、最下面 bottom 行被半透明的栏盖住：
    /// 栏不跟着滚动，但底下的内容透上来，每一帧都不一样（和哪一帧的内容也对不上）
    static func translucentWindow(offset: Int, height: Int, top: Int, bottom: Int) -> PixelFrame {
        frame((0..<height).map { i in
            if i < top { return pageRow(i * 13 + offset * 101, seed: 7) }
            if i >= height - bottom { return pageRow(i * 17 + offset * 103, seed: 8) }
            return pageRow(offset + i)
        })
    }

    /// 半透明的顶栏（例如聊天软件对话区上方的磨砂标题栏）只在最上面出现一次，不会每滚一下就在长图里留下一段
    @Test func 半透明的顶栏不会一段段重复() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let top = 10, height = 100
        for step in 0...12 { stitcher.add(Self.translucentWindow(offset: step * 9, height: height, top: top, bottom: 0)) }
        let image = try #require(stitcher.makeImage())
        let expected = (0..<top).map { Self.pageRow($0 * 13, seed: 7) } + (top..<(height + 12 * 9)).map { Self.pageRow($0) }
        #expect(stitcher.length == expected.count)
        #expect(Self.rows(of: image) == expected)
    }

    /// 平滑滚动每帧只滚 2 个像素：半透明标题栏里的文字，相邻几行本来就很像，错开 2 个像素也「对得上」——
    /// 不能因此把它当成正文，每一帧留下一条（选区很大、滚得很细时最明显）
    @Test func 每帧只滚几个像素时半透明顶栏也不重复() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let top = 12, height = 100
        // 栏里的「文字」：每 6 行一样（磨砂模糊后相邻几行很像），底下透上来的内容让每帧有一点点不同（三分之一的像素差 1 级）
        func bar(_ i: Int) -> [UInt32] { Self.pageRow(i / 6, seed: 7) }
        func frame(_ offset: Int) -> PixelFrame {
            Self.jittered(Self.frame((0..<height).map { i in i < top ? bar(i) : Self.pageRow(offset + i) }), seed: offset, columns: 0)
        }
        for step in 0...40 {
            var f = frame(step * 2)
            if step > 0 {   // 顶栏有一点点变化（透上来的内容），正文不变
                var data = f.data
                data.withUnsafeMutableBytes { raw in
                    let p = raw.bindMemory(to: UInt32.self)
                    for i in 0..<(top * Self.width) where (i + step) % 3 == 0 {
                        let b = p[i] & 0xFF
                        p[i] = (p[i] & ~0xFF) | (b == 0xFF ? 0xFE : b + 1)
                    }
                }
                f = PixelFrame(width: f.width, height: f.height, bytesPerRow: f.bytesPerRow, data: data, colorSpace: f.colorSpace)
            }
            stitcher.add(f)
        }
        let rows = Self.rows(of: try #require(stitcher.makeImage()))
        #expect(rows.count == height + 40 * 2)
        let content = rows.dropFirst(top).map { $0.map { $0 & 0xFFFF_FF00 } }
        let expected = (top..<(height + 80)).map { Self.pageRow($0).map { $0 & 0xFFFF_FF00 } }
        #expect(Array(content) == expected, "标题栏被拼进了正文")
    }

    /// 半透明的底栏（例如磨砂的输入框）只在末尾出现一次（取最后一帧的样子）
    @Test func 半透明的底栏只在末尾出现一次() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let bottom = 12, height = 100
        for step in 0...12 { stitcher.add(Self.translucentWindow(offset: step * 9, height: height, top: 0, bottom: bottom)) }
        let image = try #require(stitcher.makeImage())
        let last = 12 * 9
        let expected = (0..<(height - bottom + last)).map { Self.pageRow($0) }
            + ((height - bottom)..<height).map { Self.pageRow($0 * 17 + last * 103, seed: 8) }
        #expect(stitcher.length == expected.count)
        #expect(Self.rows(of: image) == expected)
    }

    // MARK: - 固定的边栏

    /// 左边 40 列是滚动的正文，右边 24 列是不动的边栏（每行内容不同）；
    /// spinner 不为 nil 时，边栏里有一小块每帧都在变的东西（转圈的加载图标、闪烁的光标之类）
    static func sidebarFrame(offset: Int, height: Int, spinner: Int?) -> PixelFrame {
        var rows = (0..<height).map { y -> [UInt32] in
            let page = pageRow(offset + y), side = pageRow(y, seed: 3)
            return Array(page[0..<40]) + Array(side[40..<64])
        }
        if let spinner {
            for y in 5..<9 { for x in 58..<62 { rows[y][x] = 0xFF00_0000 | UInt32(truncatingIfNeeded: (spinner &* 7919) & 0xFFFFFF) } }
        }
        return frame(rows)
    }

    /// 检查：正文那几列逐行等于页面；边栏那几列在第一屏之后不再出现边栏的内容（每列是一个颜色，不是一段段重复的边栏）
    static func checkSidebarResult(_ stitcher: ScrollStitcher, scrolled: Int, height: Int) throws {
        let image = try #require(stitcher.makeImage())
        let rows = Self.rows(of: image)
        #expect(rows.count == height + scrolled)
        guard rows.count == height + scrolled else { return }
        for (y, row) in rows.enumerated() where Array(row[0..<40]) != Array(pageRow(y)[0..<40]) {
            Issue.record("正文第 \(y) 行和页面不一致")
            break
        }
        let below = rows[height...]
        for x in 40..<58 where Set(below.map { $0[x] }).count > 1 {
            Issue.record("边栏第 \(x) 列在第一屏之后还有变化的内容（边栏被当成正文重复拼上了）")
            break
        }
    }

    @Test func 右边不动的边栏不会一段段重复() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        for step in 0...12 { stitcher.add(Self.sidebarFrame(offset: step * 9, height: 100, spinner: nil)) }
        try Self.checkSidebarResult(stitcher, scrolled: 12 * 9, height: 100)
    }

    /// 前 columns 列里三分之一的像素蓝色通道差 1 级（平滑滚动让正文停在半个像素上，文字的像素和上一帧有细微差别）：
    /// 逐像素比对对不上，只能容差比对。不动的边栏不受影响
    static func jittered(_ frame: PixelFrame, seed: Int, columns: Int = .max) -> PixelFrame {
        var data = frame.data
        let width = frame.width
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt32.self)
            for i in 0..<p.count where (i + seed) % 3 == 0 && i % width < columns {
                let b = p[i] & 0xFF
                p[i] = (p[i] & ~0xFF) | (b == 0xFF ? 0xFE : b + 1)
            }
        }
        return PixelFrame(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, data: data,
                          colorSpace: frame.colorSpace)
    }

    /// 正文像素有细微差别（逐像素对不上）、旁边的边栏完全不动：照样认出边栏，边栏不会一段段重复
    @Test func 像素有细微差别时也认得出边栏() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        for step in 0...12 {
            stitcher.add(Self.jittered(Self.sidebarFrame(offset: step * 9, height: 100, spinner: nil), seed: step, columns: 40))
        }
        let image = try #require(stitcher.makeImage())
        let rows = Self.rows(of: image)
        #expect(rows.count == 100 + 12 * 9)
        let below = rows.dropFirst(100)
        let repeated = (40..<58).contains { x in Set(below.map { $0[x] & 0xFFFF_FF00 }).count > 1 }
        #expect(!repeated, "边栏被当成正文重复拼上了")
    }

    /// 正文中间浮着一块不跟着滚动的东西（悬浮按钮、提示条）：边栏照样认得出来，不会一段段重复
    @Test func 正文上浮着不动的东西时也认得出边栏() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        for step in 0...12 {
            let base = Self.sidebarFrame(offset: step * 9, height: 100, spinner: nil)
            var data = base.data
            data.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt32.self)
                for y in 40..<56 { for x in 8..<32 { p[y * Self.width + x] = 0xFF2E_211A } }
            }
            stitcher.add(PixelFrame(width: base.width, height: base.height, bytesPerRow: base.bytesPerRow, data: data,
                                    colorSpace: base.colorSpace))
        }
        let image = try #require(stitcher.makeImage())
        let rows = Self.rows(of: image)
        let below = rows.dropFirst(100)
        let repeated = (40..<58).contains { x in Set(below.map { $0[x] }).count > 1 }
        #expect(!repeated, "边栏被当成正文重复拼上了")
    }

    /// 边栏先跟着整页一起滚，滚到一定位置后停住不动（网页里吸顶的侧栏）：一开始认不出边栏，
    /// 停住后滚几下就认出来，之后边栏不再一段段重复
    @Test func 边栏后来才停住也能认出来() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        let height = 100, stick = 3
        func frame(_ step: Int) -> PixelFrame {
            let sideOffset = min(step, stick) * 9
            return Self.frame((0..<height).map { y in
                Array(Self.pageRow(step * 9 + y)[0..<40]) + Array(Self.pageRow(sideOffset + y, seed: 3)[40..<64])
            })
        }
        for step in 0...30 { stitcher.add(frame(step)) }
        let rows = Self.rows(of: try #require(stitcher.makeImage()))
        #expect(rows.count == height + 30 * 9)
        // 停住后再滚几下（认出边栏要连续 3 次）之后，边栏那几列不再有新内容
        let settled = rows.dropFirst(height + (stick + 6) * 9)
        let repeated = (40..<58).contains { x in Set(settled.map { $0[x] }).count > 1 }
        #expect(!repeated, "边栏停住以后还在被当成正文拼上")
        for (y, row) in rows.enumerated() where Array(row[0..<40]) != Array(Self.pageRow(y)[0..<40]) {
            Issue.record("正文第 \(y) 行和页面不一致")
            break
        }
    }

    /// 边栏里有个一直在变的小东西：不能因为它就把整个边栏当成在滚动
    @Test func 边栏里有转圈图标时仍然认得出边栏() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        for step in 0...12 { stitcher.add(Self.sidebarFrame(offset: step * 9, height: 100, spinner: step)) }
        try Self.checkSidebarResult(stitcher, scrolled: 12 * 9, height: 100)
    }
}
