import AppKit

/// 冻屏那一刻屏幕上的窗口位置，用于鼠标悬停时自动识别窗口。
/// 只读取窗口的位置和层级（CGWindowListCopyWindowInfo），不截取任何窗口内容。
enum WindowList {
    /// 按从前到后的顺序返回窗口矩形（AppKit 全局坐标，单位：点）
    /// - Parameter includingOwn: Velos 自己的窗口中仍要参与识别的（钉图）
    /// - Parameter insetOwn: 这些 Velos 窗口识别时往里缩多少点（钉图窗口四周有一圈看不见的抓取边，只识别图本身）
    static func snapshot(includingOwn: Set<CGWindowID> = [], insetOwn: [CGWindowID: CGFloat] = [:]) -> [CGRect] {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let maxLayer = Int(CGWindowLevelForKey(.screenSaverWindow))

        return infos.compactMap { info -> CGRect? in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  (0..<maxLayer).contains(layer),                                   // 普通窗口、浮动面板、菜单栏、程序坞等
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID           // 不识别 Velos 自己的界面，
                    || includingOwn.contains(info[kCGWindowNumber as String] as? CGWindowID ?? 0),  // 设置、钉图等普通窗口除外
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,          // 跳过完全透明的辅助窗口
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 4, bounds.height >= 4 else { return nil }
            // CoreGraphics 坐标原点在主屏左上角，AppKit 在主屏左下角，翻转 y
            let rect = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            let inset = insetOwn[info[kCGWindowNumber as String] as? CGWindowID ?? 0] ?? 0
            return rect.insetBy(dx: inset, dy: inset)
        }
    }
}
