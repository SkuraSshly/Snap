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
/// - 每一行（横向滚动时是每一列）算一个指纹（像素哈希），纯色的行不参与比较（空白处到处都一样，会误判）
/// - 新帧的每一行去上一帧里找指纹相同的行，按「位置差」投票，票最多、且重叠部分核对得上的就是滚动距离
/// - 底部固定不动的部分（聊天输入框、底部工具栏）：在原位置不变、又和滚动后的内容对不上的行，
///   拼接时排除，最后只在末尾接一次；顶部固定的部分（标题栏）只来自第一帧，不影响拼接
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

    /// 拼好的长度（像素，沿滚动方向，含末尾固定部分）
    var length: Int { isMoving ? committedEnd + footerLength : (first.map { lineCount($0) } ?? 0) }
    /// 已经开始拼接（至少滚动过一次）
    var isMoving: Bool { first == nil && last != nil }
    private(set) var reachedLimit = false

    /// 还没滚动过时的第一帧（第一次滚动时才知道底部固定部分有多高，再把它切好放进结果）
    private var first: PixelFrame?
    /// 上一帧和它每一行的指纹
    private var last: PixelFrame?
    private var lastLines: [Line] = []
    /// 当前帧第 0 行在拼好的内容里的位置
    private var position = 0
    /// 已经拼好的内容的末尾位置（不含末尾固定部分）
    private var committedEnd = 0
    /// 末尾固定部分的长度（按最近一次滚动算）
    private var footerLength = 0
    /// 拼好的内容：一段一段（竖向是若干行，横向是若干列）
    private(set) var strips: [Strip] = []

    struct Strip: @unchecked Sendable {
        /// 沿滚动方向的长度（像素）
        let length: Int
        /// 紧凑的 BGRA 数据：竖向 length 行 × 宽度；横向 高度行 × length 列
        let data: Data
    }

    private struct Line: Equatable {
        let hash: UInt64
        /// 纯色（或几乎纯色）的行：不参与匹配
        let flat: Bool
    }

    init(axis: ScrollAxis, maxLength: Int = 20_000) {
        self.axis = axis
        self.maxLength = maxLength
    }

    // MARK: - 加入一帧

    @discardableResult
    mutating func add(_ frame: PixelFrame) -> Event {
        let lines = Self.lines(of: frame, axis: axis)
        guard let previous = last else {
            first = frame
            last = frame
            lastLines = lines
            return .started
        }
        guard previous.width == frame.width, previous.height == frame.height else { return .lost }
        if reachedLimit { return .limitReached }

        guard let shift = Self.shift(from: lastLines, to: lines) else {
            // 对不上：保留上一帧，等用户滚回能对上的位置
            return Self.mostlySame(lastLines, lines) ? .unchanged : .lost
        }
        if shift == 0 {
            // 画面有局部变化，但没有滚动：更新上一帧（例如动图换了一帧）
            last = frame
            lastLines = lines
            return .unchanged
        }

        let n = lines.count
        footerLength = Self.footer(previous: lastLines, current: lines, shift: shift)
        let scrollEnd = n - footerLength
        if let firstFrame = first {
            // 第一次滚动：第一帧去掉末尾固定部分，作为开头
            strips = [Self.strip(of: firstFrame, axis: axis, range: 0..<scrollEnd)]
            committedEnd = scrollEnd
            position = 0
            first = nil
        }
        position += shift
        last = frame
        lastLines = lines

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
        strips.append(Self.strip(of: frame, axis: axis, range: range))
        committedEnd += range.count
        return reachedLimit ? .limitReached : .appended(range.count)
    }

    // MARK: - 结果

    /// 拼好的整张图：开头 + 中间接上的各段 + 末尾固定部分（来自最后一帧）
    func makeImage() -> CGImage? {
        guard let last else { return nil }
        if let first { return Self.image(of: first) }
        var parts = strips
        if footerLength > 0 {
            parts.append(Self.strip(of: last, axis: axis, range: (lineCount(last) - footerLength)..<lineCount(last)))
        }
        let total = parts.reduce(0) { $0 + $1.length }
        let crossLength = axis == .vertical ? last.width : last.height
        let width = axis == .vertical ? crossLength : total
        let height = axis == .vertical ? total : crossLength
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { out in
            guard let dst = out.baseAddress else { return }
            var offset = 0
            for part in parts {
                part.data.withUnsafeBytes { src in
                    guard let s = src.baseAddress else { return }
                    switch axis {
                    case .vertical:
                        // 竖向：整段行直接接在后面
                        memcpy(dst + offset * bytesPerRow, s, part.data.count)
                    case .horizontal:
                        // 横向：每一行里，把这一段的列接在后面
                        let segment = part.length * 4
                        for y in 0..<height {
                            memcpy(dst + y * bytesPerRow + offset * 4, s + y * segment, segment)
                        }
                    }
                }
                offset += part.length
            }
        }
        return Self.makeCGImage(width: width, height: height, bytesPerRow: bytesPerRow, data: data, colorSpace: last.colorSpace)
    }

    /// 预览用：已拼好的各段（每段一张小图，不复制像素）
    func previewParts() -> [CGImage] {
        if let first { return Self.image(of: first).map { [$0] } ?? [] }
        guard let last else { return [] }
        let cross = axis == .vertical ? last.width : last.height
        return strips.compactMap { strip in
            axis == .vertical
                ? Self.makeCGImage(width: cross, height: strip.length, bytesPerRow: cross * 4, data: strip.data, colorSpace: last.colorSpace)
                : Self.makeCGImage(width: strip.length, height: cross, bytesPerRow: strip.length * 4, data: strip.data, colorSpace: last.colorSpace)
        }
    }

    private func lineCount(_ frame: PixelFrame) -> Int { axis == .vertical ? frame.height : frame.width }

    // MARK: - 指纹

    /// 每一行（或每一列）的指纹。像素按 32 位整数读，FNV-1a 哈希；同时判断是不是纯色
    private static func lines(of frame: PixelFrame, axis: ScrollAxis) -> [Line] {
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
                return (0..<h).map { y in
                    var hash = offsetBasis
                    let firstPixel = pixel(0, y)
                    var flat = true
                    for x in 0..<w {
                        let p = pixel(x, y)
                        hash = (hash ^ UInt64(p)) &* prime
                        if flat, p != firstPixel, !near(p, firstPixel) { flat = false }
                    }
                    return Line(hash: hash, flat: flat)
                }
            case .horizontal:
                // 按行遍历、同时更新每一列的哈希（顺序读内存，比逐列跳着读快）
                var hashes = [UInt64](repeating: offsetBasis, count: w)
                var flat = [Bool](repeating: true, count: w)
                let firstRow = (0..<w).map { pixel($0, 0) }
                for y in 0..<h {
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
        return mostlySame(previous, current) ? 0 : nil
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
    private static func mostlySame(_ previous: [Line], _ current: [Line]) -> Bool {
        let same = zip(previous, current).filter { $0 == $1 }.count
        return Double(same) >= Double(current.count) * 0.5
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

    // MARK: - 像素

    /// 从一帧里取出一段（竖向是几行，横向是几列），复制成紧凑的数据
    private static func strip(of frame: PixelFrame, axis: ScrollAxis, range: Range<Int>) -> Strip {
        let bpr = frame.bytesPerRow
        switch axis {
        case .vertical:
            let rowBytes = frame.width * 4
            var data = Data(count: rowBytes * range.count)
            data.withUnsafeMutableBytes { out in
                frame.data.withUnsafeBytes { src in
                    guard let dst = out.baseAddress, let s = src.baseAddress else { return }
                    for (k, y) in range.enumerated() { memcpy(dst + k * rowBytes, s + y * bpr, rowBytes) }
                }
            }
            return Strip(length: range.count, data: data)
        case .horizontal:
            let segment = range.count * 4
            var data = Data(count: segment * frame.height)
            data.withUnsafeMutableBytes { out in
                frame.data.withUnsafeBytes { src in
                    guard let dst = out.baseAddress, let s = src.baseAddress else { return }
                    for y in 0..<frame.height { memcpy(dst + y * segment, s + y * bpr + range.lowerBound * 4, segment) }
                }
            }
            return Strip(length: range.count, data: data)
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
