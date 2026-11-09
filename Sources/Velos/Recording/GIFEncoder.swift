import Foundation

/// 流式 GIF 编码器：每来一帧就量化、压缩、写进文件，不在内存里攒帧。
///
/// 系统的 ImageIO 编码 GIF 时会把所有帧攒到最后一起处理，300 帧 960×540 就要 1.6 GB 内存，
/// 所以这里自己实现（GIF89a 格式本身很简单）：
/// - 每帧只编码与上一帧不同的矩形区域，区域内没变的像素设为透明（显示上一帧的内容），体积小很多
/// - 完全没变的帧不写，直接延长上一帧的停留时间
/// - 每帧单独的 256 色调色板：颜色不超过 255 种时（界面截图很常见）原样保留，否则用中位切分量化
/// - LZW 压缩按 GIF 规范实现（经典的 compress 哈希表做法）
///
/// 像素格式：每个像素一个 UInt32，内存里依次是 R、G、B、X（CGImageAlphaInfo.noneSkipLast + byteOrder32Big）
final class GIFEncoder {
    let width: Int
    let height: Int

    private let handle: FileHandle
    private var offset: UInt64 = 0
    /// 每个像素「当前显示的是哪个原始颜色」：只在像素被重新编码时更新，用来判断像素有没有变
    private var reference: [UInt32]
    private var hasFirstFrame = false
    /// 上一帧的时间（秒）和它的延时字段在文件里的位置（知道下一帧的时间后回填）
    private var lastFrameTime: Double = 0
    private var lastDelayOffset: UInt64?
    private(set) var framesWritten = 0

    /// 各通道差值都不超过这个数就算没变（视频解码的细微噪点，肉眼不可见）
    private static let threshold: Int32 = 3
    private static let transparentIndex: UInt8 = 255

    init(url: URL, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        reference = [UInt32](repeating: 0, count: width * height)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)

        var header = [UInt8]()
        header += Array("GIF89a".utf8)
        header += le16(width) + le16(height)
        header += [0x70, 0, 0]   // 没有全局调色板，颜色精度 8 位
        // 无限循环播放
        header += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]
        try write(header)
    }

    deinit {
        try? handle.close()
    }

    /// 加入一帧
    /// - Parameter time: 这一帧在动画里出现的时间（秒）
    func add(_ pixels: UnsafeBufferPointer<UInt32>, at time: Double) throws {
        precondition(pixels.count == width * height)
        guard hasFirstFrame else {
            try writeFrame(pixels, rect: (0, 0, width, height), useTransparency: false, time: time)
            hasFirstFrame = true
            return
        }
        // 与当前显示内容不同的区域
        guard let rect = changedRect(pixels) else { return }   // 完全没变：上一帧继续显示
        try writeFrame(pixels, rect: rect, useTransparency: true, time: time)
    }

    /// 写完最后一帧的延时和文件尾
    func finish(endTime: Double) throws {
        try patchLastDelay(until: endTime)
        try write([0x3B])
        try handle.close()
    }

    // MARK: - 帧

    private func writeFrame(_ pixels: UnsafeBufferPointer<UInt32>, rect: (x: Int, y: Int, w: Int, h: Int),
                            useTransparency: Bool, time: Double) throws {
        try patchLastDelay(until: time)
        lastFrameTime = time

        // 1. 区域内要重新编码的像素（没变的设为透明）
        let count = rect.w * rect.h
        var changed = [Bool](repeating: true, count: count)
        if useTransparency {
            for row in 0..<rect.h {
                let base = (rect.y + row) * width + rect.x
                for col in 0..<rect.w where !Self.differs(pixels[base + col], reference[base + col]) {
                    changed[row * rect.w + col] = false
                }
            }
        }

        // 2. 调色板与每个像素的颜色序号
        let (palette, indices) = Quantizer.quantize(pixels, width: width, rect: rect, changed: changed,
                                                    transparent: Self.transparentIndex)
        for row in 0..<rect.h {
            let base = (rect.y + row) * width + rect.x
            for col in 0..<rect.w where changed[row * rect.w + col] {
                reference[base + col] = pixels[base + col]
            }
        }

        // 3. 图形控制扩展（延时先写 0，下一帧来了再回填）+ 图像描述 + 局部调色板 + LZW 数据
        var bytes = [UInt8]()
        bytes.reserveCapacity(count / 2 + 1024)
        let packed: UInt8 = (1 << 2) | (useTransparency ? 1 : 0)   // 处置方式 1：保留，供下一帧叠加
        bytes += [0x21, 0xF9, 0x04, packed, 0, 0, useTransparency ? Self.transparentIndex : 0, 0]
        lastDelayOffset = offset + 4
        bytes += [0x2C] + le16(rect.x) + le16(rect.y) + le16(rect.w) + le16(rect.h) + [0x87]   // 局部调色板 256 色
        for i in 0..<256 {
            let color = i < palette.count ? palette[i] : 0
            bytes += [UInt8(color & 0xFF), UInt8((color >> 8) & 0xFF), UInt8((color >> 16) & 0xFF)]
        }
        LZW.encode(indices, into: &bytes)
        try write(bytes)
        framesWritten += 1
    }

    /// 回填上一帧的延时（单位 1/100 秒）。按累计时间取整，长时间播放也不会越来越快或越来越慢；
    /// 不足 2 的按 2 算（浏览器会把小于 2 的延时当成 10）
    private func patchLastDelay(until time: Double) throws {
        guard let position = lastDelayOffset else { return }
        let delay = max(2, Int((time * 100).rounded()) - Int((lastFrameTime * 100).rounded()))
        let clamped = min(delay, 65_535)
        try handle.seek(toOffset: position)
        try handle.write(contentsOf: Data(le16(clamped)))
        try handle.seekToEnd()
        lastDelayOffset = nil
    }

    // MARK: - 变化检测

    private static func differs(_ a: UInt32, _ b: UInt32) -> Bool {
        let dr = Int32(a & 0xFF) - Int32(b & 0xFF)
        let dg = Int32((a >> 8) & 0xFF) - Int32((b >> 8) & 0xFF)
        let db = Int32((a >> 16) & 0xFF) - Int32((b >> 16) & 0xFF)
        return abs(dr) > threshold || abs(dg) > threshold || abs(db) > threshold
    }

    /// 与当前显示内容不同的像素所在的最小矩形；完全相同返回 nil
    private func changedRect(_ pixels: UnsafeBufferPointer<UInt32>) -> (x: Int, y: Int, w: Int, h: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        reference.withUnsafeBufferPointer { ref in
            for y in 0..<height {
                let base = y * width
                var rowMin = -1, rowMax = -1
                for x in 0..<width where Self.differs(pixels[base + x], ref[base + x]) {
                    if rowMin < 0 { rowMin = x }
                    rowMax = x
                }
                if rowMin >= 0 {
                    minX = min(minX, rowMin)
                    maxX = max(maxX, rowMax)
                    minY = min(minY, y)
                    maxY = y
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    // MARK: - 写文件

    private func write(_ bytes: [UInt8]) throws {
        try handle.write(contentsOf: Data(bytes))
        offset += UInt64(bytes.count)
    }

    private func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }
}

// MARK: - 量化

/// 把一块区域的颜色减到 255 种以内
private enum Quantizer {
    /// - Returns: 调色板（0x00BBGGRR）与区域内每个像素的颜色序号（没变的像素为 transparent）
    static func quantize(_ pixels: UnsafeBufferPointer<UInt32>, width: Int, rect: (x: Int, y: Int, w: Int, h: Int),
                         changed: [Bool], transparent: UInt8) -> ([UInt32], [UInt8]) {
        // 15 位直方图：每个格子记录像素数、颜色总和，以及格子里是不是只有一种颜色
        let binCount = 1 << 15
        var counts = [Int32](repeating: 0, count: binCount)
        var sumR = [Int64](repeating: 0, count: binCount)
        var sumG = [Int64](repeating: 0, count: binCount)
        var sumB = [Int64](repeating: 0, count: binCount)
        var firstColor = [UInt32](repeating: 0, count: binCount)
        var mixed = [Bool](repeating: false, count: binCount)
        var used: [Int] = []

        for row in 0..<rect.h {
            let base = (rect.y + row) * width + rect.x
            for col in 0..<rect.w where changed[row * rect.w + col] {
                let p = pixels[base + col] & 0x00FF_FFFF
                let bin = Self.bin(p)
                if counts[bin] == 0 {
                    used.append(bin)
                    firstColor[bin] = p
                } else if firstColor[bin] != p {
                    mixed[bin] = true
                }
                counts[bin] += 1
                sumR[bin] += Int64(p & 0xFF)
                sumG[bin] += Int64((p >> 8) & 0xFF)
                sumB[bin] += Int64((p >> 16) & 0xFF)
            }
        }

        // 调色板，并给每个用到的格子找最接近的颜色
        var palette: [UInt32]
        var lut = [UInt8](repeating: 0, count: binCount)
        if used.count <= 255, !used.contains(where: { mixed[$0] }) {
            // 颜色不超过 255 种：原样保留，没有任何损失
            palette = used.map { firstColor[$0] }
            for (index, bin) in used.enumerated() { lut[bin] = UInt8(index) }
        } else {
            palette = medianCut(used, counts: counts, sumR: sumR, sumG: sumG, sumB: sumB, maxColors: 255)
            for bin in used {
                let c = Int64(counts[bin])
                lut[bin] = nearest(r: Int(sumR[bin] / c), g: Int(sumG[bin] / c), b: Int(sumB[bin] / c), in: palette)
            }
        }
        if palette.isEmpty { palette = [0] }

        var indices = [UInt8](repeating: transparent, count: rect.w * rect.h)
        for row in 0..<rect.h {
            let base = (rect.y + row) * width + rect.x
            for col in 0..<rect.w where changed[row * rect.w + col] {
                indices[row * rect.w + col] = lut[Self.bin(pixels[base + col])]
            }
        }
        return (palette, indices)
    }

    @inline(__always)
    private static func bin(_ p: UInt32) -> Int {
        Int(((p & 0xF8) >> 3) | ((p & 0xF800) >> 6) | ((p & 0xF8_0000) >> 9))
    }

    /// 中位切分：反复把「像素多且颜色跨度大」的盒子沿跨度最大的通道从中位数切开
    private static func medianCut(_ bins: [Int], counts: [Int32], sumR: [Int64], sumG: [Int64], sumB: [Int64],
                                  maxColors: Int) -> [UInt32] {
        struct Box { var lo: Int; var hi: Int; var count: Int64; var range: Int; var channel: Int }
        var items = bins
        func component(_ bin: Int, _ channel: Int) -> Int { (bin >> (channel * 5)) & 0x1F }
        func makeBox(_ lo: Int, _ hi: Int) -> Box {
            var minC = [31, 31, 31], maxC = [0, 0, 0]
            var count: Int64 = 0
            for i in lo..<hi {
                let bin = items[i]
                count += Int64(counts[bin])
                for c in 0..<3 {
                    let v = component(bin, c)
                    minC[c] = min(minC[c], v)
                    maxC[c] = max(maxC[c], v)
                }
            }
            let ranges = (0..<3).map { maxC[$0] - minC[$0] }
            // 人眼对绿色最敏感，其次红色
            let weighted = [ranges[0] * 3, ranges[1] * 4, ranges[2] * 2]
            let channel = weighted.firstIndex(of: weighted.max()!)!
            return Box(lo: lo, hi: hi, count: count, range: weighted[channel], channel: channel)
        }

        var boxes = [makeBox(0, items.count)]
        while boxes.count < maxColors {
            // 优先切「像素数 × 跨度」最大的盒子
            guard let index = boxes.indices.filter({ boxes[$0].hi - boxes[$0].lo > 1 })
                .max(by: { Double(boxes[$0].count) * Double(boxes[$0].range) < Double(boxes[$1].count) * Double(boxes[$1].range) }),
                  boxes[index].range > 0 else { break }
            let box = boxes[index]
            items[box.lo..<box.hi].sort { component($0, box.channel) < component($1, box.channel) }
            // 按像素数找中位数
            var accumulated: Int64 = 0
            var split = box.lo + 1
            for i in box.lo..<box.hi {
                accumulated += Int64(counts[items[i]])
                if accumulated * 2 >= box.count { split = min(max(i + 1, box.lo + 1), box.hi - 1); break }
            }
            boxes[index] = makeBox(box.lo, split)
            boxes.append(makeBox(split, box.hi))
        }

        // 每个盒子的颜色 = 盒子里所有像素的平均色
        return boxes.map { box in
            var r: Int64 = 0, g: Int64 = 0, b: Int64 = 0, n: Int64 = 0
            for i in box.lo..<box.hi {
                let bin = items[i]
                r += sumR[bin]; g += sumG[bin]; b += sumB[bin]; n += Int64(counts[bin])
            }
            n = max(n, 1)
            return UInt32(r / n) | (UInt32(g / n) << 8) | (UInt32(b / n) << 16)
        }
    }

    private static func nearest(r: Int, g: Int, b: Int, in palette: [UInt32]) -> UInt8 {
        var best = 0, bestDistance = Int.max
        for (i, color) in palette.enumerated() {
            let dr = r - Int(color & 0xFF), dg = g - Int((color >> 8) & 0xFF), db = b - Int((color >> 16) & 0xFF)
            let distance = 3 * dr * dr + 4 * dg * dg + 2 * db * db
            if distance < bestDistance { bestDistance = distance; best = i }
        }
        return UInt8(best)
    }
}

// MARK: - LZW

/// GIF 的 LZW 压缩（变长编码 9~12 位，码表满了发清除码重新开始），输出带长度前缀的数据子块
private enum LZW {
    private static let maxBits = 12
    private static let maxMaxCode = 1 << maxBits
    private static let hashSize = 5003

    static func encode(_ indices: [UInt8], into output: inout [UInt8]) {
        let initCodeSize = 8
        output.append(UInt8(initCodeSize))
        var block = [UInt8]()
        block.reserveCapacity(255)
        func byteOut(_ byte: UInt8) {
            block.append(byte)
            if block.count == 255 {
                output.append(255)
                output += block
                block.removeAll(keepingCapacity: true)
            }
        }

        let initBits = initCodeSize + 1
        let clearCode = 1 << initCodeSize
        let eofCode = clearCode + 1
        var nBits = initBits
        var maxCode = (1 << nBits) - 1
        var freeEntry = clearCode + 2
        var clearFlag = false
        var accumulator: UInt32 = 0
        var accumulatedBits = 0

        var hashTable = [Int32](repeating: -1, count: hashSize)
        var codeTable = [UInt16](repeating: 0, count: hashSize)

        func emit(_ code: Int) {
            accumulator |= UInt32(code) << UInt32(accumulatedBits)
            accumulatedBits += nBits
            while accumulatedBits >= 8 {
                byteOut(UInt8(accumulator & 0xFF))
                accumulator >>= 8
                accumulatedBits -= 8
            }
            // 下一个码超出当前位宽时加宽；刚发过清除码则恢复初始位宽
            if freeEntry > maxCode || clearFlag {
                if clearFlag {
                    nBits = initBits
                    maxCode = (1 << nBits) - 1
                    clearFlag = false
                } else {
                    nBits += 1
                    maxCode = nBits == maxBits ? maxMaxCode : (1 << nBits) - 1
                }
            }
            if code == eofCode {
                while accumulatedBits > 0 {
                    byteOut(UInt8(accumulator & 0xFF))
                    accumulator >>= 8
                    accumulatedBits -= 8
                }
                accumulatedBits = 0
            }
        }

        // 哈希位移：hashSize 5003 对应 4
        var hashShift = 0
        var f = hashSize
        while f < 65_536 { hashShift += 1; f *= 2 }
        hashShift = 8 - hashShift

        emit(clearCode)
        guard var entry = indices.first.map(Int.init) else {
            emit(eofCode)
            if !block.isEmpty { output.append(UInt8(block.count)); output += block }
            output.append(0)
            return
        }
        indices.withUnsafeBufferPointer { pixels in
            var p = 1
            outer: while p < pixels.count {
                let c = Int(pixels[p])
                p += 1
                let fcode = Int32((c << maxBits) + entry)
                var i = (c << hashShift) ^ entry
                if hashTable[i] == fcode {
                    entry = Int(codeTable[i])
                    continue
                } else if hashTable[i] >= 0 {
                    // 冲突：二次探测
                    let displacement = i == 0 ? 1 : hashSize - i
                    repeat {
                        i -= displacement
                        if i < 0 { i += hashSize }
                        if hashTable[i] == fcode {
                            entry = Int(codeTable[i])
                            continue outer
                        }
                    } while hashTable[i] >= 0
                }
                emit(entry)
                entry = c
                if freeEntry < maxMaxCode {
                    codeTable[i] = UInt16(freeEntry)
                    freeEntry += 1
                    hashTable[i] = fcode
                } else {
                    // 码表满了：清空重来
                    for k in 0..<hashSize { hashTable[k] = -1 }
                    freeEntry = clearCode + 2
                    clearFlag = true
                    emit(clearCode)
                }
            }
        }
        emit(entry)
        emit(eofCode)
        if !block.isEmpty {
            output.append(UInt8(block.count))
            output += block
        }
        output.append(0)   // 数据结束
    }
}
