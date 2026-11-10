import Foundation

/// 时长的显示格式（录屏控制条、菜单栏、录屏缩略图共用）
enum DurationFormat {
    /// mm:ss，超过一小时为 h:mm:ss
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
