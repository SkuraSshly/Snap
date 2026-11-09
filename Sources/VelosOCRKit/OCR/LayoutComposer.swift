import Foundation

/// 版面整理：先按大的竖直空白把页面切成若干水平带，带内再分左右两栏，
/// 每栏按阅读顺序排好后交给 LineJoiner 合并成段落，最后把栏和带拼起来。
struct LayoutComposer {
    let imageSize: CGSize
    /// 指定的识别语言；nil 表示每栏自动检测
    let language: TranslateLanguage?
    let detector: LanguageDetector

    struct Output {
        let text: String
        let confidence: Double
    }

    func compose(_ lines: [OCRLine]) -> Output {
        var bandTexts: [String] = []
        var confidenceTotal = 0.0, blockCount = 0
        for band in splitIntoBands(lines) {
            let blocks = splitIntoColumns(band).map { column -> TextBlock in
                let ordered = readingOrder(column)
                let blockLanguage = language ?? detector.detect(ordered.map(\.text).joined(separator: "\n"))
                var block = TextBlock(lines: ordered, language: blockLanguage, imageSize: imageSize)
                block.isPoetry = PoetryClassifier.isPoetry(block)
                return block
            }
            var bandText = ""
            for (index, block) in blocks.enumerated() {
                let blockText = LineJoiner(block: block, detector: detector).compose()
                confidenceTotal += Double(block.confidence)
                blockCount += 1
                bandText = index == 0 ? blockText : joinColumns(left: blocks[index - 1], right: block).join(bandText, blockText)
            }
            let trimmed = bandText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { bandTexts.append(trimmed) }
        }
        let text = bandTexts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Output(text: text, confidence: blockCount == 0 ? 0 : confidenceTotal / Double(blockCount))
    }

    // MARK: - 切分

    /// 从上到下排列，相邻两行的空隙超过平均行高的 1.45 倍就切开
    private func splitIntoBands(_ lines: [OCRLine]) -> [[OCRLine]] {
        let sorted = lines.sorted { $0.box.minY > $1.box.minY }
        guard !sorted.isEmpty else { return [] }
        let averageHeight = sorted.map { Double($0.box.height) }.reduce(0, +) / Double(sorted.count)
        var bands: [[OCRLine]] = [[sorted[0]]]
        for index in 1..<sorted.count {
            let gap = TextBlock.verticalGap(upper: sorted[index - 1], lower: sorted[index])
            if averageHeight > 0, gap / averageHeight > 1.45 {
                bands.append([])
            }
            bands[bands.count - 1].append(sorted[index])
        }
        return bands
    }

    /// 有一行横跨页面中线就是单栏；否则按每行左边缘落在左半还是右半分成两栏
    private func splitIntoColumns(_ band: [OCRLine]) -> [[OCRLine]] {
        if band.contains(where: { $0.box.minX < 0.5 && $0.box.maxX > 0.5 }) { return [band] }
        let left = band.filter { $0.box.minX < 0.5 }
        let right = band.filter { $0.box.minX >= 0.5 }
        return [left, right].filter { !$0.isEmpty }
    }

    /// 阅读顺序：同一行从左到右，不同行从上到下
    private func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        let geometry = TextBlock(lines: [], language: language, imageSize: imageSize)
        return lines.sorted { a, b in
            geometry.isNewLine(b, a) ? a.box.minY > b.box.minY : a.box.minX < b.box.minX
        }
    }

    /// 同一带里左右两栏怎么接：左栏最后一行没写满或已经结束一句话，就另起一段；否则接着写
    private func joinColumns(left: TextBlock, right: TextBlock) -> LineJoin {
        guard let last = left.lines.last, let first = right.lines.first else { return .paragraph }
        let joiner = LineJoiner(block: left, detector: detector)
        if let hyphen = joiner.hyphenJoin(previous: last, current: first, block: left) { return hyphen }
        if !left.isLongLine(last, next: first) { return .paragraph }
        if TextTraits.endsSentence(last.text) { return .paragraph }
        return LineJoin.byLanguage(last.text, first.text, detector: detector)
    }
}
