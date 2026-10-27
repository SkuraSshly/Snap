import AppKit

/// 保存位置与文件命名：截图和录屏分开存放
@MainActor
enum SaveLocation {
    enum Kind {
        case screenshot, recording

        var title: String { self == .screenshot ? "截图" : "录屏" }
    }

    /// 默认位置：截图 ~/Pictures/ScreenShots，录屏 ~/Movies/ScreenRecordings
    static func defaultDirectory(for kind: Kind) -> URL {
        let fileManager = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        switch kind {
        case .screenshot:
            let pictures = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Pictures")
            return pictures.appendingPathComponent("ScreenShots", isDirectory: true)
        case .recording:
            let movies = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Movies")
            return movies.appendingPathComponent("ScreenRecordings", isDirectory: true)
        }
    }

    /// 当前设置的保存文件夹
    static func directory(for kind: Kind) -> URL {
        let prefs = Preferences.shared
        let path = kind == .screenshot ? prefs.screenshotDirectoryPath : prefs.recordingDirectoryPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 确保文件夹存在（第一次保存时才创建，不在启动时创建）
    @discardableResult
    static func ensureDirectory(for kind: Kind) throws -> URL {
        let url = directory(for: kind)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 带日期时间的文件名，例如「截图 2026-10-26 14.03.22.png」。
    /// 访达不允许文件名里出现冒号，所以时间用点分隔。
    static func fileName(prefix: String, fileExtension: String, date: Date = Date()) -> String {
        "\(prefix) \(timestampFormatter.string(from: date)).\(fileExtension)"
    }

    /// 同一秒内连续截图 / 录屏时文件名会重复，依次加上「 2」「 3」…
    nonisolated static func uniqueURL(in directory: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var url = directory.appendingPathComponent(fileName)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(index).\(ext)")
            index += 1
        }
        return url
    }

    /// 在访达中打开保存文件夹（不存在则先创建）
    static func revealInFinder(_ kind: Kind) {
        if let url = try? ensureDirectory(for: kind) {
            NSWorkspace.shared.open(url)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}
