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

    /// - Parameter hint: 滚轮提供的大致滚动量（像素，往前为正），从上一次对上的帧算起；没有时为 nil
    @discardableResult
    mutating func add(_ frame: PixelFrame, hint: Int? = nil) -> Event {
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
        if !bandResolved, first != nil, let changed = Self.changedSpan(previous, frame, axis: axis) {
            let full = lineCrossCount(frame)
            if changed.count >= full * 15 / 100, changed.count <= full * 95 / 100 {
                band = changed
                let bandPrevious = Self.lines(of: previous, axis: axis, span: span(for: previous))
                let bandCurrent = Self.lines(of: frame, axis: axis, span: span(for: frame))
                if let d = Self.shift(from: bandPrevious, to: bandCurrent), d != 0 {
                    bandResolved = true
                    lastLines = bandPrevious
                    lastProfiles = nil
                    lines = bandCurrent
                    sideFill = Self.sideFill(of: previous, axis: axis, band: changed)
                } else {
                    band = nil   // 认不出来：照旧整行处理
                }
            }
        }

        var shift = Self.shift(from: lastLines, to: lines)
        var profiles: [Profile]?
        if shift == nil {
            // 像素对不上：用亮度轮廓再找一次
            let previousProfiles = lastProfiles ?? Self.profiles(of: previous, axis: axis, span: span(for: previous))
            lastProfiles = previousProfiles
            profiles = Self.profiles(of: frame, axis: axis, span: span(for: frame))
            // 先在滚轮提示附近找；提示不准（平滑滚动工具放大了滚动、App 滚动的距离和滚轮量不同）或没有提示时，在所有距离里找
            let usefulHint = hint.flatMap { $0 == 0 ? nil : $0 }
            shift = Self.tolerantShift(previous: (lastLines, previousProfiles), current: (lines, profiles!), hint: usefulHint,
                                       frames: (previous, frame), axis: axis, span: span(for: frame))
            if shift == nil, usefulHint != nil {
                shift = Self.tolerantShift(previous: (lastLines, previousProfiles), current: (lines, profiles!), hint: nil,
                                           frames: (previous, frame), axis: axis, span: span(for: frame))
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

        bandResolved = true
        let n = lines.count
        footerLength = Self.footer(previous: lastLines, current: lines, shift: shift)
        let scrollEnd = n - footerLength
        if let firstFrame = first {
            // 第一次滚动：第一帧去掉末尾固定部分，作为开头；顶部固定部分以后不再覆盖
            headerLength = min(Self.header(previous: lastLines, current: lines, shift: shift), scrollEnd)
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

        // 当前帧露出了已拼好的末尾之后的内容：接上
        let start = max(0, committedEnd - position)
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

    /// 用当前帧覆盖已拼好、仍在选区里的那部分内容（顶部、底部固定部分除外）
    private mutating func refresh(from frame: PixelFrame) {
        guard first == nil else { return }
        let n = lineCount(frame)
        // 当前帧第 i 行 = 内容第 position + i 行
        let low = max(headerLength, position + headerLength)
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
                                      hint: Int?, frames: (previous: PixelFrame, current: PixelFrame), axis: ScrollAxis,
                                      span: Range<Int>) -> Int? {
        let n = current.lines.count
        guard n == previous.lines.count, n == current.profiles.count, n == previous.profiles.count else { return nil }
        let minOverlap = max(8, n / 8)
        let limit = n - minOverlap
        guard limit > 0 else { return nil }
        var candidates = -limit...limit
        if let hint {
            let window = max(48, abs(hint) / 2)
            let low = max(-limit, hint - window), high = min(limit, hint + window)
            if low <= high { candidates = low...high }
        }
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
                guard let best = refined.first, best.cost <= 6 else { return nil }
                let second = refined.dropFirst().first { abs($0.d - best.d) > 2 }?.cost ?? .infinity
                guard second >= best.cost * 1.6 + 1 else { return nil }
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
    private static func changedSpan(_ a: PixelFrame, _ b: PixelFrame, axis: ScrollAxis) -> Range<Int>? {
        let w = a.width, h = a.height
        return a.data.withUnsafeBytes { ra -> Range<Int>? in
            b.data.withUnsafeBytes { rb -> Range<Int>? in
                guard let pa = ra.baseAddress, let pb = rb.baseAddress else { return nil }
                var low = Int.max, high = -1
                for y in 0..<h {
                    let rowA = pa + y * a.bytesPerRow, rowB = pb + y * b.bytesPerRow
                    guard memcmp(rowA, rowB, w * 4) != 0 else { continue }
                    switch axis {
                    case .horizontal:
                        low = min(low, y)
                        high = max(high, y)
                    case .vertical:
                        // 只需要找最左、最右变了的列
                        var x = 0
                        while x < min(low, w), rowA.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self)
                                == rowB.loadUnaligned(fromByteOffset: x * 4, as: UInt32.self) { x += 1 }
                        if x < w { low = min(low, x) }
                        var r = w - 1
                        while r > high, rowA.loadUnaligned(fromByteOffset: r * 4, as: UInt32.self)
                                == rowB.loadUnaligned(fromByteOffset: r * 4, as: UInt32.self) { r -= 1 }
                        high = max(high, r)
                    }
                }
                return high >= low ? low..<(high + 1) : nil
            }
        }
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
