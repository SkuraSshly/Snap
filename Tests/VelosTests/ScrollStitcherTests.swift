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

    /// 边栏里有个一直在变的小东西：不能因为它就把整个边栏当成在滚动
    @Test func 边栏里有转圈图标时仍然认得出边栏() throws {
        var stitcher = ScrollStitcher(axis: .vertical)
        for step in 0...12 { stitcher.add(Self.sidebarFrame(offset: step * 9, height: 100, spinner: step)) }
        try Self.checkSidebarResult(stitcher, scrolled: 12 * 9, height: 100)
    }
}
