import CoreGraphics
import Foundation

/// 长截图的一帧画面：BGRA 8 位（与 ScreenCaptureKit 的输出一致），一行 bytesPerRow 字节
struct PixelFrame: @unchecked Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: Data
    let colorSpace: CGColorSpace

    init(width: Int, height: Int, bytesPerRow: Int, data: Data, colorSpace: CGColorSpace) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.data = data
        self.colorSpace = colorSpace
    }

    /// 把一张图画成 BGRA 帧（自测用合成画面时）
    init?(image: CGImage, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) {
        let width = image.width, height = image.height, bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: PixelFrame.bitmapInfo) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        self.init(width: width, height: height, bytesPerRow: bytesPerRow, data: data, colorSpace: colorSpace)
    }

    /// BGRA、预乘透明度（与 kCVPixelFormatType_32BGRA 一致）
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
}

/// 滚动方向
enum ScrollAxis: Sendable {
    case vertical, horizontal
}

/// 长截图拼接：每来一帧选区的新画面，算出页面相对上一帧滚动了多少，把新露出来的部分接到结果后面。
///
/// 做法：
/// - 每一行（横向滚动时是每一列）算一个指纹（像素哈希），纯色的行不参与比较（空白处到处都一样，会误判）。
///   两侧边缘一小条不参与：滚动时 macOS 会在右侧浮出滚动条、并且跟着移动，算进去会让每一行都对不上
/// - 新帧的每一行去上一帧里找指纹相同的行，按「位置差」投票，票最多、且重叠部分核对得上的就是滚动距离
/// - 像素不完全一致时（有的 App 滚动时文字抗锯齿、图片缩放有细微差别）：每行再记一个亮度轮廓（分 16 段的平均亮度），
///   找轮廓最接近的位置；有滚轮提供的大致滚动量时只在它附近找。附近有几个差不多像的位置时不冒险，算对不上
/// - 左右不动的边栏（例如聊天软件的会话列表）：第一次滚动时比较前后两帧，找出真正在滚动的那一段，
///   只用这一段比对、拼接；边栏只保留第一帧的样子，往下延伸的部分用边栏自己的背景色填满，不会一段段重复
/// - 顶部、底部固定不动的部分（标题栏、聊天输入框）：在原位置不变、又和滚动后的内容对不上的行。
///   顶部的只来自第一帧，底部的最后只在末尾接一次
/// - 还在选区里的内容，每来一帧就用最新的画面覆盖：快速滚动时刚露出来的部分常常还没画完（空白、模糊），
///   等它画好了会自动换成画好的样子；滚出选区后才定下来
/// - 往回滚：只移动当前位置，不重复拼接；再往下滚到没拼过的地方才继续接
/// - 一次滚得太远（新旧画面没有重叠）：对不上，提示用户往回滚一点，回到能对上的位置后继续
/// - 长度有上限，避免占用过多内存
struct ScrollStitcher {
    enum Event: Equatable, Sendable {
        /// 第一帧
        case started
        /// 画面没有滚动（可能有局部变化，比如动图）
        case unchanged
        /// 往前滚了，新接上了这么多像素
        case appended(Int)
        /// 往回滚了，或者在已经拼过的范围内滚动
        case moved
        /// 和上一帧对不上（滚得太快）
        case lost
        /// 到了长度上限，后面的不再拼接
        case limitReached
    }

    let axis: ScrollAxis
    /// 沿滚动方向的最大长度（像素）
    let maxLength: Int
    /// 比对时不看的两侧边缘（像素，沿每一行的方向）：前面一小条、后面一条（滚动条）
    let edgeMargin: (leading: Int, trailing: Int)

    /// 拼好的长度（像素，沿滚动方向，含末尾固定部分）
    var length: Int { isMoving ? contentEnd + footerLength : (first.map { lineCount($0) } ?? 0) }
    /// 已经开始拼接（至少滚动过一次）
    var isMoving: Bool { first == nil && last != nil }
    private(set) var reachedLimit = false

    /// 还没滚动过时的第一帧（第一次滚动时才知道顶部、底部固定部分有多高，再把它切好放进结果）
    private var first: PixelFrame?
    /// 上一帧和它每一行的指纹
    private var last: PixelFrame?
    private var lastLines: [Line] = []
    /// 当前帧第 0 行在拼好的内容里的位置
    private var position = 0
    /// 已经拼好的内容的末尾位置（不含末尾固定部分）
    private var committedEnd = 0
    /// 顶部固定部分的长度（第一次滚动时定下来）
    private var headerLength = 0
    /// 顶部不跟着滚动、但每帧都在变的部分（半透明的磨砂标题栏：底下滚过的内容会透上来）的长度。
    /// 只增不减：某一帧碰巧对得上也不缩回去，免得那一帧把栏拼进长图
    private var movingHeader = 0
    /// 最近一次真实的滚动距离（往前为正）：内容很像、几个距离都说得通时，选和刚才的滚动一致的那个
    private var recentShift: Int?
    /// 连续对不上的帧数、这些帧之间页面移动的总距离、上一帧对不上的帧的指纹：判断是不是滚得太快、被甩开了
    private var lostFrames = 0
    private var lostMotion = 0
    private var lostLines: [Line]?
    private var lostFrame: PixelFrame?
    /// 末尾固定部分的长度（按最近一次滚动算）
    private var footerLength = 0
    /// 拼好的内容：一行接一行（横向时是一列接一列，每列的像素连续存放），每行 cross × 4 字节
    private var content = Data()
    /// 一行有多少像素（竖向是宽度，横向是高度）
    private var cross = 0
    /// 真正在滚动的那一段（沿每一行，像素）；nil 表示整行都在滚动
    private var band: Range<Int>?
    /// 已经找过滚动的那一段（第一次滚动时找，之后不再变）
    private var bandResolved = false
    /// 边栏往下延伸的部分用的颜色：每个位置一个（边栏的背景色）
    private var sideFill: [UInt32] = []
    /// 每一列（横向时是每一行）目前算边栏还是正文，以及连续几次滚动看到它「不跟着滚动」「跟着滚动」
    private var sideColumn: [Bool] = []
    private var sideStreak: [Int] = []
    private var contentStreak: [Int] = []

    private struct Line: Equatable {
        let hash: UInt64
        /// 纯色（或几乎纯色）的行：不参与匹配
        let flat: Bool
    }

    /// 亮度轮廓：每行分成 16 段，每段的平均亮度（0~255），容差比对用。只在精确比对失败时才算
    private typealias Profile = SIMD16<Float>
    /// 上一帧的亮度轮廓（算过就留着，换帧时清掉）
    private var lastProfiles: [Profile]?

    init(axis: ScrollAxis, maxLength: Int = 20_000, edgeMargin: (leading: Int, trailing: Int) = (0, 0)) {
        self.axis = axis
        self.maxLength = maxLength
        self.edgeMargin = edgeMargin
    }

    // MARK: - 加入一帧

    /// 只看画面：不需要、也不读取滚轮事件（滚动方式、滚动工具都不影响）
    @discardableResult
    mutating func add(_ frame: PixelFrame) -> Event {
        let event = stitch(frame)
        if event == .lost {
            if let recovered = recoverIfOutrun(frame) { return recovered }
        } else {
            lostFrames = 0
            lostMotion = 0
            lostLines = nil
            lostFrame = nil
        }
        return event
    }

    private mutating func stitch(_ frame: PixelFrame) -> Event {
        var lines = Self.lines(of: frame, axis: axis, span: span(for: frame))
        guard let previous = last else {
            first = frame
            last = frame
            lastLines = lines
            lastProfiles = nil
            cross = axis == .vertical ? frame.width : frame.height
            return .started
        }
        guard previous.width == frame.width, previous.height == frame.height else { return .lost }
        if reachedLimit { return .limitReached }

        // 还没滚动过：画面变了的话，看是不是只有一段在滚动（两侧是不动的边栏）；是的话以后只用这一段
        if !bandResolved, first != nil, let found = adoptScrollingBand(previous, frame) {
            bandResolved = true
            lines = found
        }

        var shift = Self.shift(from: lastLines, to: lines)
        var profiles: [Profile]?
        if shift == nil {
            // 像素对不上：用亮度轮廓再找一次
            let previousProfiles = lastProfiles ?? Self.profiles(of: previous, axis: axis, span: span(for: previous))
            lastProfiles = previousProfiles
            profiles = Self.profiles(of: frame, axis: axis, span: span(for: frame))
            // 滚动的那部分（去掉顶部、底部固定的部分）：判断「原地重画」时只看这里。还没滚动过时不知道哪些是固定的，不判原地重画
            let inner: Range<Int>? = first == nil && headerLength < lines.count - footerLength
                ? headerLength..<(lines.count - footerLength) : nil
            shift = Self.tolerantShift(previous: (lastLines, previousProfiles), current: (lines, profiles!), prior: recentShift,
                                       frames: (previous, frame), axis: axis, span: span(for: frame), inner: inner)
        }
        // 刚才一直往下滚，这一帧却「往回跳了大半屏」（或者反过来）：多半是相似的内容在很窄的重叠里凑巧对上，不可信
        func implausible(_ d: Int) -> Bool {
            guard let p = recentShift else { return false }
            return (p > 0 && d < -lines.count / 2) || (p < 0 && d > lines.count / 2)
        }
        if let d = shift, implausible(d) { shift = nil }
        // 整行对不上：也许是两侧有边栏（或者边栏刚停住、范围变了），整行比对被它拖住了。
        // 找出这一对画面里真正在滚动的那几列，只用它们再比对一次；对上了就以后都按这个范围
        if shift == nil, first == nil {
            let saved = (band, sideFill, lastLines, lastProfiles)
            if let found = adoptScrollingBand(previous, frame), let d = Self.shift(from: lastLines, to: found)
                ?? Self.tolerantShift(previous: (lastLines, Self.profiles(of: previous, axis: axis, span: span(for: previous))),
                                      current: (found, Self.profiles(of: frame, axis: axis, span: span(for: frame))), prior: recentShift,
                                      frames: (previous, frame), axis: axis, span: span(for: frame), inner: nil),
               d != 0, !implausible(d) {
                lines = found
                profiles = nil
                shift = d
            } else {
                (band, sideFill, lastLines, lastProfiles) = saved
            }
        }
        guard let shift else {
            // 对不上：保留上一帧，等用户滚回能对上的位置
            return Self.mostlySame(lastLines, lines) ? .unchanged : .lost
        }
        if shift == 0 {
            // 画面有局部变化，但没有滚动：更新上一帧（例如动图换了一帧、刚露出的部分画好了）
            refresh(from: frame)
            last = frame
            lastLines = lines
            lastProfiles = profiles
            return .unchanged
        }

        let n = lines.count
        let footer = Self.footer(previous: lastLines, current: lines, shift: shift)
        let scrollEnd = n - footer
        movingHeader = max(movingHeader, Self.unmovedTop(previous, frame, previousLines: lastLines, currentLines: lines, shift: shift,
                                                         axis: axis, span: span(for: frame)))
        let header = min(max(first != nil ? Self.header(previous: lastLines, current: lines, shift: shift) : headerLength, movingHeader),
                         scrollEnd)
        // 滚动的部分和已拼好的内容必须还有重叠：新帧滚动部分的开头不能越过已拼好的末尾。
        // 越过了说明这个距离是误认的（真正滚过的距离比整个滚动部分还长，不可能对上）——
        // 照接的话会把顶部固定的标题栏当成新内容接上去，或者接错位置。当作对不上，等用户滚回来
        let baseEnd = first != nil ? scrollEnd : committedEnd
        let basePosition = first != nil ? 0 : position
        guard baseEnd - (basePosition + shift) >= header else {
            return Self.mostlySame(lastLines, lines) ? .unchanged : .lost
        }
        bandResolved = true
        recentShift = shift
        footerLength = footer
        // 每次滚动都重新确认两侧哪些列是不跟着滚动的边栏（第一次认错也能纠正过来）
        if updateSidebars(previous, frame, shift: shift, rows: header..<scrollEnd) {
            lines = Self.lines(of: frame, axis: axis, span: span(for: frame))
        }
        if let firstFrame = first {
            // 第一次滚动：第一帧去掉末尾固定部分，作为开头；顶部固定部分以后不再覆盖
            headerLength = header
            content = Data()
            content.reserveCapacity(scrollEnd * cross * 4 * 4)
            Self.copy(firstFrame, axis: axis, lines: 0..<scrollEnd, into: &content, at: 0)
            committedEnd = scrollEnd
            position = 0
            first = nil
        }
        position += shift
        last = frame
        lastLines = lines
        lastProfiles = profiles
        refresh(from: frame)

        // 当前帧露出了已拼好的末尾之后的内容：接上（顶部固定的部分永远不接，上面已经保证不会越过它）
        let start = max(header, committedEnd - position)
        guard start < scrollEnd else { return .moved }
        var range = start..<scrollEnd
        let room = maxLength - committedEnd - footerLength
        if range.count > room {
            range = start..<(start + max(0, room))
            reachedLimit = true
        }
        guard !range.isEmpty else { return .limitReached }
        Self.copy(frame, axis: axis, lines: range, into: &content, at: committedEnd, only: band,
                  fill: band == nil ? nil : sideFill)
        committedEnd += range.count
        return reachedLimit ? .limitReached : .appended(range.count)
    }

    /// 滚得太快、被甩开了：和上一次对上的那一帧已经没有重叠，而且页面还在往前滚（这几帧之间一直往下走）——
    /// 再等也对不上了。从当前画面接着拼：中间滚过去没截到的部分留空（直接接上，不会重复、也不会错位）。
    /// 往回滚时不这样做：回到已经拼过的地方，接上去就重复了，等滚回能对上的位置
    private mutating func recoverIfOutrun(_ frame: PixelFrame) -> Event? {
        guard let previous = last, previous.width == frame.width, previous.height == frame.height else { return nil }
        let lines = Self.lines(of: frame, axis: axis, span: span(for: frame))
        var pairShift: Int?
        if let earlier = lostLines, let earlierFrame = lostFrame {
            pairShift = Self.shift(from: earlier, to: lines)
                ?? Self.tolerantShift(previous: (earlier, Self.profiles(of: earlierFrame, axis: axis, span: span(for: earlierFrame))),
                                      current: (lines, Self.profiles(of: frame, axis: axis, span: span(for: frame))), prior: nil,
                                      frames: (earlierFrame, frame), axis: axis, span: span(for: frame), inner: nil)
            if let d = pairShift { lostMotion += d }
        }
        let earlierFrame = lostFrame
        lostLines = lines
        lostFrame = frame
        lostFrames += 1
        if first != nil {
            // 还没开始拼：开头截到的那一张是过渡画面（刚从调度中心回来、切换桌面的动画、窗口还没画好），
            // 之后的画面彼此能对上（页面在正常滚动）却一直对不上它——起点换成上一张正常的画面，重新开始
            guard lostFrames >= 3, let d = pairShift, d != 0, let restart = earlierFrame else { return nil }
            self = ScrollStitcher(axis: axis, maxLength: maxLength, edgeMargin: edgeMargin)
            add(restart)
            return add(frame)
        }
        guard lostFrames >= Self.outrunFrames, lostMotion > 0, (recentShift ?? 0) > 0 else { return nil }
        let n = lines.count
        let header = max(headerLength, movingHeader)
        let scrollEnd = n - footerLength
        guard header < scrollEnd else { return nil }
        var range = header..<scrollEnd
        let room = maxLength - committedEnd - footerLength
        if range.count > room {
            range = header..<(header + max(0, room))
            reachedLimit = true
        }
        guard !range.isEmpty else { return .limitReached }
        Self.copy(frame, axis: axis, lines: range, into: &content, at: committedEnd, only: band,
                  fill: band == nil ? nil : sideFill)
        position = committedEnd - header
        committedEnd += range.count
        last = frame
        lastLines = lines
        lastProfiles = nil
        lostFrames = 0
        lostMotion = 0
        self.lostLines = nil
        lostFrame = nil
        return reachedLimit ? .limitReached : .appended(range.count)
    }

    /// 连续这么多帧对不上、页面还在往前滚，就从当前画面接回（帧只在画面变化时才来，大约是滚动中的四分之一秒）
    static let outrunFrames = 15

    /// 找出这一对画面里真正在滚动的那一段（两侧是不动的边栏），而且只用这一段能认出滚动：
    /// 采用它（以后只比对、只拼接这一段，边栏用背景色延伸），上一帧的指纹换成这一段的，返回当前帧这一段的指纹
    private mutating func adoptScrollingBand(_ previous: PixelFrame, _ frame: PixelFrame) -> [Line]? {
        guard let changed = scrollingSpan(previous, frame) else { return nil }
        let full = lineCrossCount(frame)
        guard changed.count >= full * 15 / 100, changed.count <= full * 95 / 100, changed != band else { return nil }
        let saved = band
        band = changed
        let span = span(for: frame)
        let bandPrevious = Self.lines(of: previous, axis: axis, span: span)
        let bandCurrent = Self.lines(of: frame, axis: axis, span: span)
        // 逐像素对不上（平滑滚动停在半个像素上、颜色转换的抖动）时，用容差比对再认一次
        var d = Self.shift(from: bandPrevious, to: bandCurrent)
        if d == nil {
            d = Self.tolerantShift(previous: (bandPrevious, Self.profiles(of: previous, axis: axis, span: span)),
                                   current: (bandCurrent, Self.profiles(of: frame, axis: axis, span: span)), prior: nil,
                                   frames: (previous, frame), axis: axis, span: span, inner: nil)
        }
        guard let d, d != 0 else {
            band = saved   // 认不出来：照旧
            return nil
        }
        lastLines = bandPrevious
        lastProfiles = nil
        sideFill = Self.sideFill(of: previous, axis: axis, band: changed)
        sideColumn = (0..<full).map { !changed.contains($0) }
        sideStreak = [Int](repeating: 0, count: full)
        contentStreak = [Int](repeating: 0, count: full)
        return bandCurrent
    }

    /// 两侧的边栏：每次滚动，逐列看这一列是跟着滚动了（正文），还是没跟着滚动（不动的边栏、边栏里转圈的图标、
    /// 闪烁的光标、刷新的数字）。连续 3 次没跟着滚动才算边栏；连续 2 次跟着滚动就算回正文（宁可多拼，不丢内容）。
    /// 纯色的空白列两种都说得通，不改变原来的判断。从选区两边往里，连成一片的边栏列就是边栏：
    /// 只保留第一屏的样子，往下用它的背景色延伸。
    /// 判断用的是这次滚动前后都看得到、又不在顶部和底部固定栏里的那些行，按「有多少行对得上」而不是平均差别，
    /// 半透明的标题栏、浮着的提示之类只占几行，不会把正文误判成边栏。返回 true 表示边栏范围变了
    private mutating func updateSidebars(_ previous: PixelFrame, _ frame: PixelFrame, shift d: Int, rows: Range<Int>) -> Bool {
        let crossCount = lineCrossCount(frame)
        if sideColumn.count != crossCount {
            sideColumn = (0..<crossCount).map { c in band.map { !$0.contains(c) } ?? false }
            sideStreak = [Int](repeating: 0, count: crossCount)
            contentStreak = [Int](repeating: 0, count: crossCount)
        }
        let low = max(rows.lowerBound, -d), high = min(rows.upperBound, rows.upperBound - d, lineCount(frame) - d)
        guard high - low >= 8 else { return false }
        let step = max(1, (high - low) / 160)
        let bpr = frame.bytesPerRow
        let vertical = axis == .vertical
        var follows = [Bool](repeating: false, count: crossCount), still = [Bool](repeating: false, count: crossCount)
        previous.data.withUnsafeBytes { prevRaw in
            frame.data.withUnsafeBytes { curRaw in
                guard let pb = prevRaw.baseAddress, let cb = curRaw.baseAddress else { return }
                func pixel(_ base: UnsafeRawPointer, _ c: Int, _ i: Int) -> UInt32 {
                    base.loadUnaligned(fromByteOffset: vertical ? i * bpr + c * 4 : c * bpr + i * 4, as: UInt32.self)
                }
                func near(_ a: UInt32, _ b: UInt32) -> Bool {
                    if a == b { return true }
                    for k in stride(from: 0, to: 24, by: 8) where abs(Int((a >> UInt32(k)) & 0xff) - Int((b >> UInt32(k)) & 0xff)) > 6 {
                        return false
                    }
                    return true
                }
                for c in 0..<crossCount {
                    var moved = 0, stayed = 0, total = 0
                    var i = low
                    while i < high {
                        let now = pixel(cb, c, i)
                        if near(now, pixel(pb, c, i + d)) { moved += 1 }
                        if near(now, pixel(pb, c, i)) { stayed += 1 }
                        total += 1
                        i += step
                    }
                    follows[c] = moved * 5 >= total * 4
                    still[c] = stayed * 5 >= total * 4
                }
            }
        }
        for c in 0..<crossCount {
            if follows[c], still[c] { continue }   // 空白：两种都说得通
            if follows[c] {
                contentStreak[c] += 1
                sideStreak[c] = 0
                if contentStreak[c] >= 2 { sideColumn[c] = false }
            } else {
                sideStreak[c] += 1
                contentStreak[c] = 0
                if sideStreak[c] >= 3 { sideColumn[c] = true }
            }
        }
        var left = 0
        while left < crossCount, sideColumn[left] { left += 1 }
        var right = 0
        while right < crossCount - left, sideColumn[crossCount - 1 - right] { right += 1 }
        var proposed: Range<Int>? = left == 0 && right == 0 ? nil : left..<(crossCount - right)
        if let p = proposed, p.count < crossCount * 15 / 100 { proposed = band }   // 剩下的太窄：不可信，保持原样
        guard proposed != band else { return false }
        band = proposed
        if let proposed { sideFill = Self.sideFill(of: previous, axis: axis, band: proposed) }
        return true
    }

    /// 用当前帧覆盖已拼好、仍在选区里的那部分内容（顶部、底部固定部分除外）
    private mutating func refresh(from frame: PixelFrame) {
        guard first == nil else { return }
        let n = lineCount(frame)
        // 当前帧第 i 行 = 内容第 position + i 行；顶部的栏（固定的、半透明的）盖着的那几行不用
        let low = max(headerLength, position + max(headerLength, movingHeader))
        let high = min(committedEnd, position + n - footerLength)
        guard low < high else { return }
        // 只覆盖滚动的那一段：边栏保持第一帧的样子
        Self.copy(frame, axis: axis, lines: (low - position)..<(high - position), into: &content, at: low, only: band)
    }

    private func lineCrossCount(_ frame: PixelFrame) -> Int { axis == .vertical ? frame.width : frame.height }

    /// 比对时看每一行的哪一段：滚动的那一段（没有边栏时是整行），再去掉两侧边缘（只在足够长时才去掉）
    private func span(for frame: PixelFrame) -> Range<Int> {
        let base = band ?? 0..<lineCrossCount(frame)
        guard base.count > (edgeMargin.leading + edgeMargin.trailing) * 4 else { return base }
        return (base.lowerBound + edgeMargin.leading)..<(base.upperBound - edgeMargin.trailing)
    }

    // MARK: - 结果

    /// 拼好的整张图：开头 + 中间接上的部分 + 末尾固定部分（来自最后一帧）
    func makeImage() -> CGImage? {
        guard let last else { return nil }
        if let first { return Self.image(of: first) }
        let end = contentEnd
        var all = content
        if footerLength > 0 {
            let n = lineCount(last)
            Self.copy(last, axis: axis, lines: (n - footerLength)..<n, into: &all, at: end)
        }
        return Self.image(lines: all, count: end + footerLength, cross: cross, axis: axis, colorSpace: last.colorSpace)
    }

    /// 拼好的内容实际到哪里为止：去掉滚过头时拉出来的空白。
    /// 触控板式滚动到页面尽头会「回弹」：先多拉出一截空白背景，松开后弹回去。拉出来的那截已经被接上了，
    /// 页面弹回后，当前画面的末尾之后如果全是纯色（背景），就是那截空白，不算内容
    private var contentEnd: Int {
        guard first == nil, let last else { return committedEnd }
        let end = position + lineCount(last) - footerLength
        guard end > 0, end < committedEnd else { return committedEnd }
        let lineBytes = cross * 4
        let span = band ?? 0..<cross
        let blank = content.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            let reference = base.loadUnaligned(fromByteOffset: end * lineBytes + span.lowerBound * 4, as: UInt32.self)
            for line in end..<committedEnd {
                for x in stride(from: span.lowerBound, to: span.upperBound, by: 3) {
                    let p = base.loadUnaligned(fromByteOffset: line * lineBytes + x * 4, as: UInt32.self)
                    for shift in stride(from: 0, to: 24, by: 8) {
                        let a = Int((p >> UInt32(shift)) & 0xff), b = Int((reference >> UInt32(shift)) & 0xff)
                        if abs(a - b) > 6 { return false }
                    }
                }
            }
            return true
        }
        return blank ? end : committedEnd
    }

    /// 预览用：拼好的内容最后 maxLines 行（不含末尾固定部分），一张图
    func previewParts(maxLines: Int = 3000) -> [CGImage] {
        guard let last else { return [] }
        if let first { return Self.image(of: first).map { [$0] } ?? [] }
        let count = min(committedEnd, maxLines)
        let lineBytes = cross * 4
        let tail = content.subdata(in: (committedEnd - count) * lineBytes..<committedEnd * lineBytes)
        return Self.image(lines: tail, count: count, cross: cross, axis: axis, colorSpace: last.colorSpace).map { [$0] } ?? []
    }

    private func lineCount(_ frame: PixelFrame) -> Int { axis == .vertical ? frame.height : frame.width }

    // MARK: - 指纹

    /// 每一行（或每一列）的指纹。像素按 32 位整数读，FNV-1a 哈希；同时判断是不是纯色。两侧边缘不算
    private static func lines(of frame: PixelFrame, axis: ScrollAxis, span: Range<Int>) -> [Line] {
        let w = frame.width, h = frame.height, bpr = frame.bytesPerRow
        let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325, prime: UInt64 = 0x0000_0100_0000_01b3
        return frame.data.withUnsafeBytes { raw -> [Line] in
            guard let base = raw.baseAddress else { return [] }
            func pixel(_ x: Int, _ y: Int) -> UInt32 { base.loadUnaligned(fromByteOffset: y * bpr + x * 4, as: UInt32.self) }
            func near(_ a: UInt32, _ b: UInt32) -> Bool {
                // 每个通道相差不超过 6：抗锯齿、细微渐变也算「几乎纯色」
                for shift in stride(from: 0, to: 24, by: 8) {
                    let ca = Int((a >> UInt32(shift)) & 0xff), cb = Int((b >> UInt32(shift)) & 0xff)
                    if abs(ca - cb) > 6 { return false }
                }
                return true
            }
            switch axis {
            case .vertical:
                let xs = span
                return (0..<h).map { y in
                    var hash = offsetBasis
                    let firstPixel = pixel(xs.lowerBound, y)
                    var flat = true
                    for x in xs {
                        let p = pixel(x, y)
                        hash = (hash ^ UInt64(p)) &* prime
                        if flat, p != firstPixel, !near(p, firstPixel) { flat = false }
                    }
                    return Line(hash: hash, flat: flat)
                }
            case .horizontal:
                // 按行遍历、同时更新每一列的哈希（顺序读内存，比逐列跳着读快）
                let ys = span
                var hashes = [UInt64](repeating: offsetBasis, count: w)
                var flat = [Bool](repeating: true, count: w)
                let firstRow = (0..<w).map { pixel($0, ys.lowerBound) }
                for y in ys {
                    for x in 0..<w {
                        let p = pixel(x, y)
                        hashes[x] = (hashes[x] ^ UInt64(p)) &* prime
                        if flat[x], p != firstRow[x], !near(p, firstRow[x]) { flat[x] = false }
                    }
                }
                return (0..<w).map { Line(hash: hashes[$0], flat: flat[$0]) }
            }
        }
    }

    /// 每一行（或每一列）的亮度轮廓。隔一个像素取一个（容差比对用不着每个像素），两侧边缘不算
    private static func profiles(of frame: PixelFrame, axis: ScrollAxis, span: Range<Int>) -> [Profile] {
        let w = frame.width, h = frame.height, bpr = frame.bytesPerRow
        return frame.data.withUnsafeBytes { raw -> [Profile] in
            guard let base = raw.baseAddress else { return [] }
            // 亮度（近似 0.25 R + 0.625 G + 0.125 B）
            func luma(_ x: Int, _ y: Int) -> Float {
                let p = base.loadUnaligned(fromByteOffset: y * bpr + x * 4, as: UInt32.self)
                return Float(((p >> 16) & 0xff) * 2 + ((p >> 8) & 0xff) * 5 + (p & 0xff)) / 8
            }
            // 沿一行（去掉边缘后长度 count）分 16 段，每段隔一个像素取样
            let offset = span.lowerBound
            let count = span.count
            let segments: [(start: Int, end: Int)] = (0..<16).map {
                (offset + $0 * count / 16, offset + max($0 * count / 16 + 1, ($0 + 1) * count / 16))
            }
            let lines = axis == .vertical ? h : w
            var result = [Profile](repeating: Profile(), count: lines)
            for line in 0..<lines {
                var profile = Profile()
                for (b, segment) in segments.enumerated() {
                    var sum: Float = 0, samples: Float = 0
                    var k = segment.start
                    while k < min(segment.end, offset + count) {
                        sum += axis == .vertical ? luma(k, line) : luma(line, k)
                        samples += 1
                        k += 2
                    }
                    profile[b] = samples > 0 ? sum / samples : 0
                }
                result[line] = profile
            }
            return result
        }
    }

    // MARK: - 匹配

    /// 滚动距离：当前帧第 i 行 = 上一帧第 i + d 行（d > 0 是往前滚）。对不上时返回 nil，没滚动返回 0
    private static func shift(from previous: [Line], to current: [Line]) -> Int? {
        let n = current.count
        guard n == previous.count, n > 4 else { return nil }
        if previous == current { return 0 }

        // 上一帧：指纹 → 出现的位置（重复太多的指纹是花纹、分隔线之类，不参与投票）
        var positions: [UInt64: [Int]] = [:]
        for (j, line) in previous.enumerated() where !line.flat { positions[line.hash, default: []].append(j) }
        var votes: [Int: Int] = [:]
        for (i, line) in current.enumerated() where !line.flat {
            guard let js = positions[line.hash], js.count <= 4 else { continue }
            for j in js where j != i { votes[j - i, default: 0] += 1 }
        }
        // 票数从多到少，逐个核对重叠部分
        for (d, count) in votes.sorted(by: { $0.value > $1.value || ($0.value == $1.value && abs($0.key) < abs($1.key)) }).prefix(3)
        where count >= 3 {
            if verify(previous, current, shift: d) { return d }
        }
        // 精确匹配找不到：交给容差比对（它会先排除原位置不动的行再找）。
        // 不能在这里因为「大部分行没变」就判成没滚动——选区里不动的部分占大头时（框了整个屏幕、只有中间一栏在滚），
        // 在 Retina 屏上像素有细微差别、精确匹配失败，会把真实的滚动当成「没变」
        return nil
    }

    /// 容差比对：像素不完全一致时（例如 Retina 屏上截取时的颜色转换让三分之一的像素差 1~2 级），找最像的滚动距离。
    /// 1. 先按像素（隔几个取一个，允许细微差别）找出两帧里原位置没变的行：固定的标题栏、输入框，不参与比对。
    ///    不能用亮度轮廓判断——行距整齐的文字，不同的两行轮廓也差不多，会被误当成没变
    /// 2. 用亮度轮廓快速给每个可能的距离打分，取最好的几个
    /// 3. 对这几个逐个按像素核对，取最像的：要足够像，而且明显比其他候选像，否则返回 nil
    /// 有滚轮提示时只在提示附近找（快、也不容易被重复的花纹骗）
    private static func tolerantShift(previous: (lines: [Line], profiles: [Profile]), current: (lines: [Line], profiles: [Profile]),
                                      prior: Int?, frames: (previous: PixelFrame, current: PixelFrame), axis: ScrollAxis,
                                      span: Range<Int>, inner: Range<Int>?) -> Int? {
        let n = current.lines.count
        guard n == previous.lines.count, n == current.profiles.count, n == previous.profiles.count else { return nil }
        let minOverlap = max(8, n / 8)
        let limit = n - minOverlap
        guard limit > 0 else { return nil }
        let candidates = -limit...limit
        let usable = (0..<n).filter { !current.lines[$0].flat }
        guard !usable.isEmpty else { return 0 }

        return frames.previous.data.withUnsafeBytes { prevRaw -> Int? in
            frames.current.data.withUnsafeBytes { curRaw -> Int? in
                guard let pb = prevRaw.baseAddress, let cb = curRaw.baseAddress else { return nil }
                let bpr = frames.current.bytesPerRow
                let sampleStep = max(1, span.count / 240)
                /// 上一帧第 j 行和当前帧第 i 行的平均像素差（每个通道 0~255，取三个通道的平均）
                func pixelDistance(_ j: Int, _ i: Int) -> Float {
                    var total = 0, count = 0
                    var x = span.lowerBound
                    while x < span.upperBound {
                        let (po, co) = axis == .vertical ? (j * bpr + x * 4, i * bpr + x * 4) : (x * bpr + j * 4, x * bpr + i * 4)
                        let p = pb.loadUnaligned(fromByteOffset: po, as: UInt32.self)
                        let q = cb.loadUnaligned(fromByteOffset: co, as: UInt32.self)
                        if p != q {
                            for shift in stride(from: 0, to: 24, by: 8) {
                                total += abs(Int((p >> UInt32(shift)) & 0xff) - Int((q >> UInt32(shift)) & 0xff))
                            }
                        }
                        count += 1
                        x += sampleStep
                    }
                    return count == 0 ? 0 : Float(total) / Float(count * 3)
                }
                // 原位置几乎没变 → 没有滚动。按「真正变了的行有多少」判断，不按平均差别：
                // 选区里不动的部分占大头时（框了整个屏幕、只有中间一栏在滚），平均下来差别很小，会把真实的滚动当成没变
                let changedRows = usable.filter { pixelDistance($0, $0) > 1.2 }.count
                if changedRows < max(3, usable.count / 50) { return 0 }
                let fixed = (0..<n).map { current.lines[$0].flat || pixelDistance($0, $0) <= 1.2 }

                let cur = current.profiles, prev = previous.profiles
                func distance(_ a: Profile, _ b: Profile) -> Float {
                    let d = a - b
                    return d.replacing(with: -d, where: d .< 0).sum() / 16
                }
                let step = n > 600 ? 2 : 1
                func profileCost(_ d: Int) -> Float? {
                    var total: Float = 0, count = 0
                    var i = max(0, -d)
                    let end = min(n, n - d)
                    while i < end {
                        if !current.lines[i].flat, !fixed[i], !fixed[i + d] {
                            total += distance(cur[i], prev[i + d])
                            count += 1
                        }
                        i += step
                    }
                    return count >= max(3, (end - max(0, -d)) / (10 * step)) ? total / Float(count) : nil
                }
                // 亮度轮廓最像的几个距离（相隔 3 行以上，算不同的候选）
                var scored: [(d: Int, cost: Float)] = []
                for d in candidates where d != 0 {
                    if let c = profileCost(d) { scored.append((d, c)) }
                }
                scored.sort { $0.cost < $1.cost }
                var picks: [Int] = []
                for item in scored where !picks.contains(where: { abs($0 - item.d) <= 2 }) {
                    picks.append(item.d)
                    if picks.count == 6 { break }
                }
                // 和刚才的滚动一致的距离也一定核对一下
                if let prior, prior != 0, abs(prior) <= limit, !picks.contains(where: { abs($0 - prior) <= 2 }) { picks.append(prior) }
                // 逐个按像素核对
                func pixelCost(_ d: Int) -> Float {
                    var total: Float = 0, count = 0
                    var i = max(0, -d)
                    let end = min(n, n - d)
                    while i < end {
                        if !fixed[i], !fixed[i + d] {
                            total += pixelDistance(i + d, i)
                            count += 1
                        }
                        i += step
                    }
                    return count == 0 ? .infinity : total / Float(count)
                }
                // 最好的候选附近 ±2 行也试一下（轮廓分辨不出一两行的差别）
                var refined: [(d: Int, cost: Float)] = []
                for d in picks {
                    let local = (max(-limit, d - 2)...min(limit, d + 2)).filter { $0 != 0 }.map { ($0, pixelCost($0)) }
                    if let bestLocal = local.min(by: { $0.1 < $1.1 }) { refined.append((bestLocal.0, bestLocal.1)) }
                }
                refined.sort { $0.cost < $1.cost }
                // 找不到可信的滚动距离时，是局部重画（刚滚到时没画完的部分补上了、动图换了一帧），还是一下滚得太远、和上一帧没有重叠？
                // 局部重画：滚动的那部分里（顶部、底部固定的部分不算）一半以上的行原地没变——当作没滚动，由调用方用这一帧更新内容。
                // 不能把固定的部分也算进去：选区里上下有大片不动的区域时，一下滚太远，没变的行照样过半，
                // 会把错位的画面当成重画写进去，之后接错位置、已经截过的内容又被接一遍。
                // 还没滚动过（不知道哪些是固定的）时一律算对不上：等用户滚回能对上的位置
                let localChange: Int? = {
                    guard let inner else { return nil }
                    let rows = usable.filter { inner.contains($0) }
                    guard !rows.isEmpty else { return nil }
                    let unchanged = rows.filter { pixelDistance($0, $0) <= 1.2 }.count
                    return unchanged * 2 >= rows.count ? 0 : nil
                }()
                guard let best = refined.first, best.cost <= 6 else { return localChange }
                // 和刚才的滚动一致的那个距离，如果几乎和最好的一样好，就选它：列表、聊天记录里相似的内容很多，
                // 别的距离可能凑巧更像一点；真的一下滚了很远时，小距离会对得很差，不会被选中
                if let prior, prior != 0 {
                    let tolerance = max(24, abs(prior) / 2)
                    if let near = refined.first(where: { abs($0.d - prior) <= tolerance }), near.cost <= 6,
                       near.cost <= best.cost * 1.3 + 0.5 {
                        return near.d
                    }
                }
                let second = refined.dropFirst().first { abs($0.d - best.d) > 2 }?.cost ?? .infinity
                guard second >= best.cost * 1.6 + 1 else { return localChange }
                return best.d
            }
        }
    }

    /// 核对：重叠部分里，参与比较的行至少 85% 对得上。不参与比较的：纯色行；
    /// 两帧里原位置都没变的固定行（顶部标题栏、底部输入框）——不管是这一行本身，还是它要对应的上一帧那一行
    private static func verify(_ previous: [Line], _ current: [Line], shift d: Int) -> Bool {
        let n = current.count
        var considered = 0, matched = 0
        for i in max(0, -d)..<min(n, n - d) {
            let line = current[i]
            if line.flat || line == previous[i] || current[i + d] == previous[i + d] { continue }
            considered += 1
            if line == previous[i + d] { matched += 1 }
        }
        return considered >= 3 && Double(matched) >= Double(considered) * 0.85
    }

    /// 大部分行和上一帧原位置相同（没有滚动，只是局部变化）
    /// 认不出移动了多少时：是画面没变（只有光标闪烁之类的一两行变化），还是对不上了。
    /// 按变了的行有多少判断，不按没变的行占比：选区里不动的部分占大头时，没变的行永远过半，会把对不上当成没变，
    /// 页面一直在滚、拼接却原地踏步
    private static func mostlySame(_ previous: [Line], _ current: [Line]) -> Bool {
        let differing = zip(previous, current).filter { $0 != $1 && !$1.flat }.count
        return differing < max(4, current.count / 20)
    }

    /// 末尾固定部分的长度：从末尾往前，原位置不变的那一段里，最靠前的一行「确定是固定的」
    /// （和滚动后的位置对不上）就是固定部分的开头；纯色的空白行两种都对得上，算作内容。最多占一半
    private static func footer(previous: [Line], current: [Line], shift d: Int) -> Int {
        let n = current.count
        var start = n
        var i = n - 1
        while i >= n / 2, current[i] == previous[i] {
            let movesToo = i + d >= 0 && i + d < n && current[i] == previous[i + d]
            if !movesToo { start = i }
            i -= 1
        }
        return n - start
    }


    /// 顶部不跟着滚动的栏有多高（固定的、半透明磨砂的标题栏）。从开头往下逐行看：这一行和上一帧「原位置」那一行更像，
    /// 还是和「滚动前对应的那一行」更像。栏不跟着滚动，和原位置更像（半透明的只差一点点）；正文跟着滚动，和滚动前的位置一样、
    /// 和原位置不一样。只看「和滚动前的位置对不对得上」不够：每帧只滚几个像素时，栏里文字相邻的几行本来就很像，也对得上，
    /// 会被当成正文，每一帧在长图里留下一条。两种都很像的（空白）不算数；连续 3 行明确跟着滚动就到头了。最多占三分之一
    private static func unmovedTop(_ previous: PixelFrame, _ current: PixelFrame, previousLines: [Line], currentLines: [Line],
                                   shift d: Int, axis: ScrollAxis, span: Range<Int>) -> Int {
        let n = currentLines.count
        let begin = max(0, -d), end = min(n / 3, n - d)
        guard begin < end else { return 0 }
        return previous.data.withUnsafeBytes { prevRaw -> Int in
            current.data.withUnsafeBytes { curRaw -> Int in
                guard let pb = prevRaw.baseAddress, let cb = curRaw.baseAddress else { return 0 }
                let bpr = current.bytesPerRow
                let step = max(1, span.count / 240)
                /// 当前帧第 i 行和上一帧第 j 行的平均像素差（每个通道 0~255）
                func distance(_ i: Int, _ j: Int) -> Float {
                    var total = 0, count = 0
                    var x = span.lowerBound
                    while x < span.upperBound {
                        let (po, co) = axis == .vertical ? (j * bpr + x * 4, i * bpr + x * 4) : (x * bpr + j * 4, x * bpr + i * 4)
                        let p = pb.loadUnaligned(fromByteOffset: po, as: UInt32.self)
                        let q = cb.loadUnaligned(fromByteOffset: co, as: UInt32.self)
                        if p != q {
                            for shift in stride(from: 0, to: 24, by: 8) {
                                total += abs(Int((p >> UInt32(shift)) & 0xff) - Int((q >> UInt32(shift)) & 0xff))
                            }
                        }
                        count += 1
                        x += step
                    }
                    return count == 0 ? 0 : Float(total) / Float(count * 3)
                }
                var header = 0, run = 0, i = begin
                while i < end {
                    if currentLines[i].flat {
                        i += 1
                        continue
                    }
                    let moved = currentLines[i] == previousLines[i + d] ? 0 : distance(i, i + d)
                    let stayed = currentLines[i] == previousLines[i] ? 0 : distance(i, i)
                    if moved <= 2, stayed > moved + 1 {
                        // 明确跟着滚动了：正文
                        run += 1
                        if run == 3 { break }
                    } else if stayed <= moved || moved > 2 {
                        // 不动（或者只差一点点），或者和滚动前的位置对不上：栏
                        run = 0
                        header = i + 1
                    }
                    i += 1
                }
                return header
            }
        }
    }

    /// 顶部固定部分的长度：从开头往后，原位置不变的那一段里，最靠后的一行「确定是固定的」就是固定部分的结尾。最多占一半
    private static func header(previous: [Line], current: [Line], shift d: Int) -> Int {
        let n = current.count
        var end = 0
        var i = 0
        while i < n / 2, current[i] == previous[i] {
            let movesToo = i + d >= 0 && i + d < n && current[i] == previous[i + d]
            if !movesToo { end = i + 1 }
            i += 1
        }
        return end
    }

    // MARK: - 像素

    /// 把一帧里的若干行（横向时是若干列）复制到内容的第 at 行起（覆盖或接在末尾）
    /// - Parameters:
    ///   - only: 只复制每一行的这一段（滚动的那一段）；nil 表示整行
    ///   - fill: 和 only 一起用：这一段以外填这些颜色（边栏往下延伸的部分）；nil 表示不动原来的内容
    private static func copy(_ frame: PixelFrame, axis: ScrollAxis, lines range: Range<Int>, into content: inout Data, at index: Int,
                             only: Range<Int>? = nil, fill: [UInt32]? = nil) {
        guard !range.isEmpty else { return }
        let cross = axis == .vertical ? frame.width : frame.height
        let lineBytes = cross * 4
        let needed = (index + range.count) * lineBytes
        if content.count < needed { content.append(Data(count: needed - content.count)) }
        let bpr = frame.bytesPerRow
        let part = only ?? 0..<cross
        content.withUnsafeMutableBytes { out in
            frame.data.withUnsafeBytes { src in
                guard let dst = out.baseAddress, let s = src.baseAddress else { return }
                let out32 = dst.assumingMemoryBound(to: UInt32.self)
                for (k, line) in range.enumerated() {
                    let target = out32 + (index + k) * cross
                    if let fill, fill.count == cross {
                        fill.withUnsafeBufferPointer { f in
                            guard let f = f.baseAddress else { return }
                            target.update(from: f, count: part.lowerBound)
                            (target + part.upperBound).update(from: f + part.upperBound, count: cross - part.upperBound)
                        }
                    }
                    switch axis {
                    case .vertical:
                        memcpy(target + part.lowerBound, s + line * bpr + part.lowerBound * 4, part.count * 4)
                    case .horizontal:
                        // 每一列的像素连续存放（转置），拼好后再转回来
                        for y in part { target[y] = s.loadUnaligned(fromByteOffset: y * bpr + line * 4, as: UInt32.self) }
                    }
                }
            }
        }
    }

    /// 两帧之间变了的那一段（沿每一行的方向）：竖向时是哪些列有变化，横向时是哪些行有变化；没变化返回 nil
    /// 两帧之间真正在滚动的那一段（沿每一行）。
    /// 变了的位置先分成几段（中间隔着一截没变的）：最宽的一段是正文，用它算出滚动距离；
    /// 其他段只有「也按同样的距离移动」才算在滚动的范围里——边栏里转圈的图标、闪烁的光标、刷新的数字
    /// 虽然也在变，但不是跟着滚动，不能因为它们就把整个边栏当成正文（否则边栏会被一段段重复拼上去）
    private func scrollingSpan(_ previous: PixelFrame, _ frame: PixelFrame) -> Range<Int>? {
        let runs = Self.changedRuns(previous, frame, axis: axis)
        guard let main = runs.max(by: { $0.count < $1.count }) else { return nil }
        guard runs.count > 1 else { return main }
        let mainPrevious = Self.lines(of: previous, axis: axis, span: main), mainCurrent = Self.lines(of: frame, axis: axis, span: main)
        guard let d = Self.shift(from: mainPrevious, to: mainCurrent), d != 0 else { return main }
        var low = main.lowerBound, high = main.upperBound
        for run in runs where run != main {
            let a = Self.lines(of: previous, axis: axis, span: run), b = Self.lines(of: frame, axis: axis, span: run)
            let n = b.count
            var moved = 0, considered = 0
            for i in max(0, -d)..<min(n, n - d) where !b[i].flat || !a[i + d].flat {
                considered += 1
                if b[i] == a[i + d] { moved += 1 }
            }
            // 这一段里有内容的行，一半以上按同样的距离移动了：也是滚动的内容（例如正文右边的图片、滚动条旁的一栏）
            if considered > 0, moved * 2 >= considered {
                low = min(low, run.lowerBound)
                high = max(high, run.upperBound)
            }
        }
        return low..<high
    }

    /// 两帧之间变了的位置，分成一段一段（相隔不到 12 个像素的并成一段）
    private static func changedRuns(_ a: PixelFrame, _ b: PixelFrame, axis: ScrollAxis) -> [Range<Int>] {
        let w = a.width, h = a.height
        let cross = axis == .vertical ? w : h
        var changed = [Bool](repeating: false, count: cross)
        a.data.withUnsafeBytes { ra in
            b.data.withUnsafeBytes { rb in
                guard let pa = ra.baseAddress, let pb = rb.baseAddress else { return }
                for y in 0..<h {
                    let rowA = pa + y * a.bytesPerRow, rowB = pb + y * b.bytesPerRow
                    guard memcmp(rowA, rowB, w * 4) != 0 else { continue }
                    if axis == .horizontal {
                        changed[y] = true
                        continue
                    }
                    for x in 0..<w where !changed[x] {
                        if rowA.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self)
                            != rowB.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self) { changed[x] = true }
                    }
                }
            }
        }
        var runs: [Range<Int>] = []
        var start: Int?, last = -1
        for (i, flag) in changed.enumerated() where flag {
            if let s = start, i - last > 12 {
                runs.append(s..<(last + 1))
                start = i
            } else if start == nil {
                start = i
            }
            last = i
        }
        if let s = start { runs.append(s..<(last + 1)) }
        return runs
    }

    /// 边栏的背景色：滚动的那一段以外，每个位置取出现最多的颜色（隔一个像素取样）
    private static func sideFill(of frame: PixelFrame, axis: ScrollAxis, band: Range<Int>) -> [UInt32] {
        let cross = axis == .vertical ? frame.width : frame.height
        let along = axis == .vertical ? frame.height : frame.width
        return frame.data.withUnsafeBytes { raw -> [UInt32] in
            guard let base = raw.baseAddress else { return [] }
            return (0..<cross).map { c in
                guard !band.contains(c) else { return 0 }
                var counts: [UInt32: Int] = [:]
                for k in stride(from: 0, to: along, by: 2) {
                    let (x, y) = axis == .vertical ? (c, k) : (k, c)
                    counts[base.loadUnaligned(fromByteOffset: y * frame.bytesPerRow + x * 4, as: UInt32.self), default: 0] += 1
                }
                return counts.max { $0.value < $1.value }?.key ?? 0
            }
        }
    }

    /// 内容（count 行，每行 cross 像素）做成图；横向时把按列存放的像素转回按行
    private static func image(lines data: Data, count: Int, cross: Int, axis: ScrollAxis, colorSpace: CGColorSpace) -> CGImage? {
        guard count > 0, cross > 0 else { return nil }
        switch axis {
        case .vertical:
            return makeCGImage(width: cross, height: count, bytesPerRow: cross * 4, data: data.prefix(count * cross * 4),
                               colorSpace: colorSpace)
        case .horizontal:
            var rows = Data(count: count * cross * 4)
            rows.withUnsafeMutableBytes { out in
                data.withUnsafeBytes { src in
                    guard let dst = out.baseAddress?.assumingMemoryBound(to: UInt32.self),
                          let s = src.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
                    for x in 0..<count {
                        let column = s + x * cross
                        for y in 0..<cross { dst[y * count + x] = column[y] }
                    }
                }
            }
            return makeCGImage(width: count, height: cross, bytesPerRow: count * 4, data: rows, colorSpace: colorSpace)
        }
    }

    private static func image(of frame: PixelFrame) -> CGImage? {
        makeCGImage(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, data: frame.data,
                    colorSpace: frame.colorSpace)
    }

    private static func makeCGImage(width: Int, height: Int, bytesPerRow: Int, data: Data, colorSpace: CGColorSpace) -> CGImage? {
        guard width > 0, height > 0, let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: PixelFrame.bitmapInfo), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
