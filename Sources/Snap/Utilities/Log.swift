import os

/// 系统日志（只写本机统一日志，不联网）。查看：
/// log show --last 5m --predicate 'subsystem == "local.snap.Snap"'
enum Log {
    static let hotkey = Logger(subsystem: "local.snap.Snap", category: "hotkey")
    static let capture = Logger(subsystem: "local.snap.Snap", category: "capture")
}
