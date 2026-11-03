import Foundation
import Combine

// MARK: - 选项枚举

/// 截图保存格式
enum ImageFormat: String, CaseIterable, Identifiable {
    case png, heic, jpeg
    var id: Self { self }
    var title: String {
        switch self {
        case .png: "PNG（无损）"
        case .heic: "HEIC"
        case .jpeg: "JPEG"
        }
    }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

/// 录屏分辨率
enum RecordingResolution: String, CaseIterable, Identifiable {
    case native, p1080
    var id: Self { self }
    var title: String { self == .native ? "原生分辨率" : "1080p" }
}

/// 录屏帧率
enum RecordingFrameRate: Int, CaseIterable, Identifiable {
    case fps60 = 60, fps30 = 30
    var id: Self { self }
    var title: String { "\(rawValue) fps" }
}

/// 视频编码
enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc, h264
    var id: Self { self }
    var title: String { self == .hevc ? "HEVC（画质高、体积小）" : "H.264（兼容性更好）" }
}

/// GIF 帧率
enum GIFFrameRate: Int, CaseIterable, Identifiable {
    case fps10 = 10, fps15 = 15, fps20 = 20
    var id: Self { self }
    var title: String { "\(rawValue) fps" }
}

/// GIF 最大宽度（像素）；0 表示与视频相同
enum GIFMaxWidth: Int, CaseIterable, Identifiable {
    case original = 0, w1280 = 1280, w960 = 960, w640 = 640
    var id: Self { self }
    var title: String { self == .original ? "与视频同宽" : "最宽 \(rawValue) 像素" }
}

/// 录屏画质档位（决定码率系数）
enum VideoQuality: String, CaseIterable, Identifiable {
    case high, ultra
    var id: Self { self }
    var title: String { self == .high ? "高" : "极高" }
}

// MARK: - 设置

/// 所有用户设置，持久化在 UserDefaults（~/Library/Preferences/local.snap.Snap.plist）。
/// SwiftUI 设置界面直接绑定这些属性；其他模块读取它们，或通过 `$属性` 订阅变化。
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key: String {
        case showMenuBarIcon, screenshotDirectoryPath, recordingDirectoryPath, hasCompletedOnboarding
        case imageFormat, jpegQuality, screenshotIncludesCursor, screenshotSaveAs1x
        case screenshotCopyToClipboard, screenshotSaveToFile, screenshotShowThumbnail, hideThumbnailAfterPaste
        case recordingResolution, recordingFrameRate, videoCodec, videoQuality
        case recordSystemAudio, recordMicrophone, microphoneDeviceID, recordingShowsCursor
        case recordingCountdown, highlightClicks, recordingShowThumbnail
        case gifFrameRate, gifMaxWidth
        case screenshotHotkey, recordingHotkey, translateHotkey
        case ocrSmartLayout, ocrDetectsQRCodes, ocrPreferredLanguage, translateWindowPinnedByDefault
        case enabledEngines, defaultEngine, llmPrompt
        case defaultTargetLanguage, translateAutoCopy, speechRate
    }

    // MARK: 通用
    @Published var showMenuBarIcon: Bool { didSet { Self.save(showMenuBarIcon, .showMenuBarIcon) } }
    /// 截图的保存文件夹（绝对路径），默认 ~/Pictures/ScreenShots
    @Published var screenshotDirectoryPath: String { didSet { Self.save(screenshotDirectoryPath, .screenshotDirectoryPath) } }
    /// 录屏的保存文件夹（绝对路径），默认 ~/Movies/ScreenRecordings
    @Published var recordingDirectoryPath: String { didSet { Self.save(recordingDirectoryPath, .recordingDirectoryPath) } }

    // MARK: 截图
    @Published var imageFormat: ImageFormat { didSet { Self.save(imageFormat.rawValue, .imageFormat) } }
    /// JPEG 压缩质量 0~1
    @Published var jpegQuality: Double { didSet { Self.save(jpegQuality, .jpegQuality) } }
    @Published var screenshotIncludesCursor: Bool { didSet { Self.save(screenshotIncludesCursor, .screenshotIncludesCursor) } }
    @Published var screenshotSaveAs1x: Bool { didSet { Self.save(screenshotSaveAs1x, .screenshotSaveAs1x) } }
    @Published var screenshotCopyToClipboard: Bool { didSet { Self.save(screenshotCopyToClipboard, .screenshotCopyToClipboard) } }
    @Published var screenshotSaveToFile: Bool { didSet { Self.save(screenshotSaveToFile, .screenshotSaveToFile) } }
    @Published var screenshotShowThumbnail: Bool { didSet { Self.save(screenshotShowThumbnail, .screenshotShowThumbnail) } }
    /// 截图被粘贴后自动收起缩略图
    @Published var hideThumbnailAfterPaste: Bool { didSet { Self.save(hideThumbnailAfterPaste, .hideThumbnailAfterPaste) } }

    // MARK: 录屏
    @Published var recordingResolution: RecordingResolution { didSet { Self.save(recordingResolution.rawValue, .recordingResolution) } }
    @Published var recordingFrameRate: RecordingFrameRate { didSet { Self.save(recordingFrameRate.rawValue, .recordingFrameRate) } }
    @Published var videoCodec: VideoCodec { didSet { Self.save(videoCodec.rawValue, .videoCodec) } }
    @Published var videoQuality: VideoQuality { didSet { Self.save(videoQuality.rawValue, .videoQuality) } }
    /// 以下几项同时也是录制选项条的「上次选择」
    @Published var recordSystemAudio: Bool { didSet { Self.save(recordSystemAudio, .recordSystemAudio) } }
    @Published var recordMicrophone: Bool { didSet { Self.save(recordMicrophone, .recordMicrophone) } }
    /// 麦克风设备 uniqueID，空字符串表示系统默认输入设备
    @Published var microphoneDeviceID: String { didSet { Self.save(microphoneDeviceID, .microphoneDeviceID) } }
    @Published var recordingShowsCursor: Bool { didSet { Self.save(recordingShowsCursor, .recordingShowsCursor) } }
    @Published var recordingCountdown: Bool { didSet { Self.save(recordingCountdown, .recordingCountdown) } }
    @Published var highlightClicks: Bool { didSet { Self.save(highlightClicks, .highlightClicks) } }
    /// 录制完成后在屏幕角落显示缩略图
    @Published var recordingShowThumbnail: Bool { didSet { Self.save(recordingShowThumbnail, .recordingShowThumbnail) } }
    @Published var gifFrameRate: GIFFrameRate { didSet { Self.save(gifFrameRate.rawValue, .gifFrameRate) } }
    @Published var gifMaxWidth: GIFMaxWidth { didSet { Self.save(gifMaxWidth.rawValue, .gifMaxWidth) } }

    // MARK: 截屏翻译
    /// 智能排版（合并段落、处理连字符和中英文空格）；关闭时保留原始换行
    @Published var ocrSmartLayout: Bool { didSet { Self.save(ocrSmartLayout, .ocrSmartLayout) } }
    /// 同时识别二维码（默认关闭）
    @Published var ocrDetectsQRCodes: Bool { didSet { Self.save(ocrDetectsQRCodes, .ocrDetectsQRCodes) } }
    /// 启用的在线翻译引擎（EngineID 的 rawValue；默认全部关闭）
    @Published var enabledEngines: [String] { didSet { Self.save(enabledEngines, .enabledEngines) } }
    /// 默认翻译引擎（EngineID 的 rawValue，默认 Apple 翻译）
    @Published var defaultEngine: String { didSet { Self.save(defaultEngine, .defaultEngine) } }
    /// 大模型翻译的自定义提示词（空字符串表示用默认提示词）
    @Published var llmPrompt: String { didSet { Self.save(llmPrompt, .llmPrompt) } }
    /// 截屏翻译的结果窗口默认钉住
    @Published var translateWindowPinnedByDefault: Bool { didSet { Self.save(translateWindowPinnedByDefault, .translateWindowPinnedByDefault) } }
    /// OCR 优先语言（TranslateLanguage 的 rawValue），空字符串表示跟随系统语言
    @Published var ocrPreferredLanguage: String { didSet { Self.save(ocrPreferredLanguage, .ocrPreferredLanguage) } }
    /// 默认目标语言（TranslateLanguage 的 rawValue）；空字符串表示自动：中文 → 英文，其他 → 简体中文
    @Published var defaultTargetLanguage: String { didSet { Self.save(defaultTargetLanguage, .defaultTargetLanguage) } }
    /// 翻译完成后自动复制译文（默认关闭）
    @Published var translateAutoCopy: Bool { didSet { Self.save(translateAutoCopy, .translateAutoCopy) } }
    /// 朗读语速（AVSpeechUtterance.rate，系统默认 0.5）
    @Published var speechRate: Double { didSet { Self.save(speechRate, .speechRate) } }

    // MARK: 快捷键（存成 [键码, 修饰键]）
    @Published var screenshotHotkey: Hotkey { didSet { Self.save(screenshotHotkey.stored, .screenshotHotkey) } }
    @Published var recordingHotkey: Hotkey { didSet { Self.save(recordingHotkey.stored, .recordingHotkey) } }
    @Published var translateHotkey: Hotkey { didSet { Self.save(translateHotkey.stored, .translateHotkey) } }

    /// 是否已经走完首次运行的权限引导（界面不需要监听它，所以不用 @Published）
    var hasCompletedOnboarding: Bool {
        get { Self.load(.hasCompletedOnboarding, false) }
        set { Self.save(newValue, .hasCompletedOnboarding) }
    }

    private init() {
        showMenuBarIcon = Self.load(.showMenuBarIcon, true)
        screenshotDirectoryPath = Self.load(.screenshotDirectoryPath, SaveLocation.defaultDirectory(for: .screenshot).path)
        recordingDirectoryPath = Self.load(.recordingDirectoryPath, SaveLocation.defaultDirectory(for: .recording).path)

        imageFormat = Self.loadEnum(.imageFormat, ImageFormat.png)
        jpegQuality = Self.load(.jpegQuality, 0.95)
        screenshotIncludesCursor = Self.load(.screenshotIncludesCursor, false)
        screenshotSaveAs1x = Self.load(.screenshotSaveAs1x, false)
        screenshotCopyToClipboard = Self.load(.screenshotCopyToClipboard, true)
        // 默认不自动保存：按 Enter 只复制，需要时在缩略图上点「保存」或按 ⌘S
        screenshotSaveToFile = Self.load(.screenshotSaveToFile, false)
        screenshotShowThumbnail = Self.load(.screenshotShowThumbnail, true)
        hideThumbnailAfterPaste = Self.load(.hideThumbnailAfterPaste, true)

        recordingResolution = Self.loadEnum(.recordingResolution, RecordingResolution.native)
        recordingFrameRate = Self.loadEnum(.recordingFrameRate, RecordingFrameRate.fps60)
        videoCodec = Self.loadEnum(.videoCodec, VideoCodec.hevc)
        videoQuality = Self.loadEnum(.videoQuality, VideoQuality.high)
        recordSystemAudio = Self.load(.recordSystemAudio, true)
        recordMicrophone = Self.load(.recordMicrophone, false)
        microphoneDeviceID = Self.load(.microphoneDeviceID, "")
        recordingShowsCursor = Self.load(.recordingShowsCursor, true)
        recordingCountdown = Self.load(.recordingCountdown, false)
        highlightClicks = Self.load(.highlightClicks, false)
        recordingShowThumbnail = Self.load(.recordingShowThumbnail, true)
        gifFrameRate = Self.loadEnum(.gifFrameRate, GIFFrameRate.fps15)
        gifMaxWidth = Self.loadEnum(.gifMaxWidth, GIFMaxWidth.w960)

        ocrSmartLayout = Self.load(.ocrSmartLayout, true)
        ocrDetectsQRCodes = Self.load(.ocrDetectsQRCodes, false)
        ocrPreferredLanguage = Self.load(.ocrPreferredLanguage, "")
        translateWindowPinnedByDefault = Self.load(.translateWindowPinnedByDefault, false)
        enabledEngines = Self.load(.enabledEngines, [String]())
        defaultEngine = Self.load(.defaultEngine, "apple")
        llmPrompt = Self.load(.llmPrompt, "")
        defaultTargetLanguage = Self.load(.defaultTargetLanguage, "")
        translateAutoCopy = Self.load(.translateAutoCopy, false)
        speechRate = Self.load(.speechRate, 0.5)

        screenshotHotkey = Hotkey(stored: Self.load(.screenshotHotkey, [Int]())) ?? .defaultScreenshot
        recordingHotkey = Hotkey(stored: Self.load(.recordingHotkey, [Int]())) ?? .defaultRecording
        translateHotkey = Hotkey(stored: Self.load(.translateHotkey, [Int]())) ?? .defaultTranslate
        // 默认快捷键从 ⌥1 / ⌥2 / ⌥3 改成 ⌥A / ⌥S / ⌥D：还在用旧默认值的一次性换成新的（只做一次，之后自己改回 ⌥1 也会保留）
        if !UserDefaults.standard.bool(forKey: "hotkeysMigratedToASD") {
            if screenshotHotkey == Hotkey.legacyDefaults[0] { screenshotHotkey = .defaultScreenshot }
            if recordingHotkey == Hotkey.legacyDefaults[1] { recordingHotkey = .defaultRecording }
            if translateHotkey == Hotkey.legacyDefaults[2] { translateHotkey = .defaultTranslate }
            UserDefaults.standard.set(true, forKey: "hotkeysMigratedToASD")
        }
    }

    // MARK: 读写辅助

    private static func load<T>(_ key: Key, _ defaultValue: T) -> T {
        UserDefaults.standard.object(forKey: key.rawValue) as? T ?? defaultValue
    }

    private static func loadEnum<E: RawRepresentable>(_ key: Key, _ defaultValue: E) -> E {
        guard let raw = UserDefaults.standard.object(forKey: key.rawValue) as? E.RawValue else { return defaultValue }
        return E(rawValue: raw) ?? defaultValue
    }

    private static func save(_ value: Any, _ key: Key) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
    }
}
