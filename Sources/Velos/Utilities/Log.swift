import os

/// 系统日志（只写本机统一日志，不联网）。查看：
/// log show --last 5m --predicate 'subsystem == "local.velos.Velos"'
enum Log {
    static let hotkey = Logger(subsystem: "local.velos.Velos", category: "hotkey")
    static let capture = Logger(subsystem: "local.velos.Velos", category: "capture")
}
