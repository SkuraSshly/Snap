import AppKit
import AVFoundation
import ScreenCaptureKit

/// 录屏的状态与开始 / 暂停 / 停止。界面（菜单栏红点计时、浮动控制条、红框）订阅 state。
@MainActor
final class RecordingManager: ObservableObject {
    static let shared = RecordingManager()

    enum State: Equatable {
        case idle
        /// 开始前的 3 秒倒计时
        case countingDown
        case starting
        case recording
        case paused
        case stopping
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isMicrophoneMuted = false
    /// 系统事件让录制自动暂停时的说明（控制条上显示）；用户点「继续」后清掉
    private(set) var autoPauseNote: String?
    /// 本次录制是否录了麦克风（控制条据此显示麦克风按钮）
    private(set) var capturesMicrophone = false
    /// 设置里打开了麦克风，但没有麦克风权限，本次没有录麦克风
    private(set) var microphoneUnavailable = false

    private var recorder: ScreenRecorder?
    private var controlBar: RecordingControlBar?
    private var frameWindow: RecordingFrameWindow?
    private var countdown: RecordingCountdown?
    private var highlighter: ClickHighlighter?
    private var screen: NSScreen?
    /// 录制期间监听的系统事件（熄屏、锁屏、切换用户、睡眠），停止录制时移除
    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// 锁屏是全系统的分布式通知：要「立即送达」（Velos 平时不是前台 App，否则系统会把它攒到 Velos 变成前台才送）
    private var lockObserver: DistributedObserver?

    /// 录制中（包括暂停）
    var isRecording: Bool { state == .recording || state == .paused }
    var isPaused: Bool { state == .paused }
    /// 已录制的时长（扣除暂停）
    var elapsed: TimeInterval {
        #if DEBUG
        if let debugElapsedOverride { return debugElapsedOverride }
        #endif
        return recorder?.elapsed ?? 0
    }

    #if DEBUG
    /// 自测用：录屏文件保存到这里
    static var debugOutputDirectory: URL?
    private(set) var debugLastOutput: URL?
    var debugControlBar: RecordingControlBar? { controlBar }
    var debugFrameWindow: RecordingFrameWindow? { frameWindow }
    var debugCountdown: RecordingCountdown? { countdown }
    var debugHighlighter: ClickHighlighter? { highlighter }
    /// README 截图用：控制条上显示固定的时长
    var debugElapsedOverride: TimeInterval?
    #endif

    private init() {}

    // MARK: - 开始

    /// 从录屏选区开始录制（设置里打开了倒计时则先倒数 3 秒）
    func start(_ target: RecordingTarget, from session: RecordingSelectionSession) {
        guard state == .idle else { return }
        // 遮罩立即藏起来（录到的第一帧里不会有它）；Velos 的窗口还在，之后取窗口列表时能找到 Velos 自己
        session.hideOverlays()
        // 红框倒计时期间就出现，让人知道要录哪里
        frameWindow = RecordingFrameWindow(region: target.rect, screen: target.screen,
                                           isFullScreen: target.rect.equalTo(target.screen.frame))
        frameWindow?.orderFrontRegardless()

        guard Preferences.shared.recordingCountdown else {
            beginCapture(target, from: session)
            return
        }
        state = .countingDown
        let countdown = RecordingCountdown(seconds: 3, region: target.rect,
                                           hotkey: CaptureCoordinator.shared.recordingHotkey) { [weak self] outcome in
            guard let self else { return }
            self.countdown = nil
            if outcome == .finished {
                self.beginCapture(target, from: session)
            } else {
                Log.capture.notice("倒计时期间取消了录制")
                self.hideChrome()
                session.finish()
                self.state = .idle
            }
        }
        self.countdown = countdown
        countdown.run()
    }

    /// 倒计时期间取消（倒计时卡片上按 Esc、点一下，或按录屏快捷键）
    func cancelCountdown() {
        countdown?.finish(.cancelled)
    }

    private func beginCapture(_ target: RecordingTarget, from session: RecordingSelectionSession) {
        state = .starting
        // 点击高亮的透明层要在创建录制范围之前出现，才能把它列为「要录进去的例外窗口」
        if Preferences.shared.highlightClicks {
            highlighter = ClickHighlighter(screen: target.screen)
        }
        Task {
            do {
                let filter = try await Self.makeFilter(for: target, including: highlighter.map { [$0.windowID] } ?? [])
                session.finish()
                let recorder = try ScreenRecorder(settings: try makeSettings(for: target, filter: filter))
                // 录制意外中断（权限被收回、显示器被拔掉等）：把已经录到的部分保存下来
                recorder.onInterrupted = { _ in
                    Task { await RecordingManager.shared.stop() }
                }
                try await recorder.start()
                self.recorder = recorder
                screen = target.screen
                capturesMicrophone = recorder.settings.capturesMicrophone
                isMicrophoneMuted = false
                state = .recording
                highlighter?.start()
                showControlBar(for: target)
                watchSystemEvents()
                // 控制条、红框出来后换成「只排除它们」：录制中用 Velos 截图、截屏翻译时，截图界面、标注、
                // 翻译结果、缩略图、钉图都会录进视频（录的就是屏幕上看到的）；只有录屏自己的控制条和红框不录
                await includeVelosWindows(target)
                let s = recorder.settings
                Log.capture.notice("开始录制：\(s.pixelWidth)×\(s.pixelHeight) 像素，\(s.fps) fps，\(s.codec == .hevc ? "HEVC" : "H.264", privacy: .public)，码率 \(ScreenRecorder.bitRate(for: s) / 1_000_000) Mbps，系统声音 \(s.capturesSystemAudio)，麦克风 \(s.capturesMicrophone)，点击高亮 \(self.highlighter != nil)")
            } catch {
                session.finish()
                hideChrome()
                state = .idle
                Log.capture.error("录制无法开始：\(error.localizedDescription, privacy: .public)")
                showError("录屏无法开始", error)
            }
        }
    }

    /// 录制中：只排除录屏自己的控制条和红框，Velos 的其他窗口（截图界面、翻译结果、缩略图、钉图……）照常录进去
    private func includeVelosWindows(_ target: RecordingTarget) async {
        guard let recorder else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else { return }
            let chrome = Set([controlBar?.windowNumber, frameWindow?.windowNumber].compactMap { $0 }.map { CGWindowID($0) })
            let excluded = content.windows.filter { chrome.contains($0.windowID) }
            guard excluded.count == chrome.count else {
                Log.capture.error("录屏：找不到控制条或红框的窗口，保持排除 Velos 的所有窗口")
                return
            }
            try await recorder.updateFilter(SCContentFilter(display: display, excludingWindows: excluded))
            Log.capture.notice("录屏：录制中使用截图、截屏翻译会录进视频（控制条、红框除外）")
        } catch {
            Log.capture.error("录屏：更新录制范围失败 \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 录制范围：整块显示器，排除 Velos 自己的所有窗口（包括之后才出现的控制条、红框、缩略图），
    /// 钉图（属于屏幕内容）和 including 里的窗口（点击高亮层）除外
    private static func makeFilter(for target: RecordingTarget, including: [CGWindowID]) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw ScreenFreezer.FreezeError.displayNotFound
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let pins = PinManager.shared.windowNumbers
        let keptWindows = content.windows.filter { pins.contains($0.windowID) || including.contains($0.windowID) }
        if ownApps.isEmpty {
            // 理论上不会发生（此时遮罩还在）；保险起见按窗口排除
            let excluded = ScreenFreezer.ownWindows(in: content).filter { !including.contains($0.windowID) }
            return SCContentFilter(display: display, excludingWindows: excluded)
        }
        return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: keptWindows)
    }

    private func makeSettings(for target: RecordingTarget, filter: SCContentFilter) throws -> ScreenRecorder.Settings {
        let prefs = Preferences.shared
        let frame = target.screen.frame
        let scale = target.scale

        // 原生像素尺寸，向下取偶数（视频编码要求）；同时把录制区域收窄到对应的大小，保证像素一一对应、不缩放
        let nativeWidth = Int((target.rect.width * scale).rounded()) & ~1
        let nativeHeight = Int((target.rect.height * scale).rounded()) & ~1
        let sourceRect = CGRect(x: target.rect.minX - frame.minX,
                                y: frame.maxY - target.rect.maxY,   // ScreenCaptureKit 的原点在左上角
                                width: CGFloat(nativeWidth) / scale,
                                height: CGFloat(nativeHeight) / scale)

        // 设置为 1080p 时，超过 1920×1080 的按比例缩小
        var width = nativeWidth, height = nativeHeight
        if prefs.recordingResolution == .p1080, width > 1920 || height > 1080 {
            let factor = min(1920 / Double(width), 1080 / Double(height))
            width = Int(Double(width) * factor) & ~1
            height = Int(Double(height) * factor) & ~1
        }

        // 麦克风：没有权限就不录（录屏照常进行），控制条上会提示
        let microphoneAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let capturesMicrophone = prefs.recordMicrophone && microphoneAuthorized
        microphoneUnavailable = prefs.recordMicrophone && !microphoneAuthorized
        if microphoneUnavailable { Log.capture.notice("没有麦克风权限，本次不录麦克风") }
        // 选过的设备被拔掉了就用系统默认
        let deviceID = prefs.microphoneDeviceID
        let microphoneID = AudioDevices.all().contains { $0.uniqueID == deviceID } ? deviceID : nil

        let directory: URL
        #if DEBUG
        directory = try Self.debugOutputDirectory ?? SaveLocation.ensureDirectory(for: .recording)
        #else
        directory = try SaveLocation.ensureDirectory(for: .recording)
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = SaveLocation.uniqueURL(in: directory, fileName: SaveLocation.fileName(prefix: "录屏", fileExtension: "mp4"))

        return ScreenRecorder.Settings(
            filter: filter, sourceRect: sourceRect, pixelWidth: max(width, 2), pixelHeight: max(height, 2),
            fps: prefs.recordingFrameRate.rawValue, showsCursor: prefs.recordingShowsCursor,
            codec: prefs.videoCodec, quality: prefs.videoQuality,
            isWideGamut: target.screen.canRepresent(.p3),
            capturesSystemAudio: prefs.recordSystemAudio,
            capturesMicrophone: capturesMicrophone, microphoneDeviceID: microphoneID,
            outputURL: url
        )
    }

    // MARK: - 控制条与红框

    /// 录制区域旁放浮动控制条（红框在倒计时前就已出现）；两者都属于 Velos，不会被录进视频
    private func showControlBar(for target: RecordingTarget) {
        let bar = RecordingControlBar(manager: self)
        bar.place(near: target.rect, on: target.screen, isFullScreen: target.rect.equalTo(target.screen.frame))
        bar.orderFrontRegardless()
        controlBar = bar
    }

    // MARK: - 系统事件

    /// 录制中遇到这些情况，自动处理：
    /// - 屏幕熄灭、锁屏、切换到别的用户：自动暂停（画面和声音都不录，这段时间不算进视频）。
    ///   不然视频里会多出一大段静止画面，人走开了麦克风还在录，锁屏界面也可能被录进去。
    ///   回来后保持暂停，由用户点「继续」——自动接着录容易录进解锁画面之类不想要的东西
    /// - 电脑要睡眠：睡眠时截屏一定会被系统切断，趁睡眠前停止并把文件写完，醒来后显示缩略图
    /// （被录的显示器拔掉、截屏被系统中断：由 recorder.onInterrupted 自动停止并保存）
    private func watchSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.autoPause(because: "屏幕熄灭") }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.autoPause(because: "切换到了别的用户") }
        lockObserver = DistributedObserver(Self.screenLockedNotification) { [weak self] _ in
            self?.autoPause(because: "锁屏")
        }
        observe(workspace, NSWorkspace.willSleepNotification) { manager in
            guard manager.isRecording else { return }
            Log.capture.notice("电脑要睡眠：自动停止录制并保存")
            Task { await manager.stop() }
        }
    }

    private static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")

    #if DEBUG
    /// 自测：模拟收到锁屏通知（真的锁屏通知是全系统广播，自测不发）
    func debugSimulateScreenLocked() { autoPause(because: "锁屏") }
    #endif

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping (RecordingManager) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        systemObservers.append((center, token))
    }

    private func stopWatchingSystemEvents() {
        for (center, token) in systemObservers { center.removeObserver(token) }
        systemObservers.removeAll()
        lockObserver?.invalidate()
        lockObserver = nil
    }

    /// 自动暂停：只在正在录时暂停（用户自己已经暂停的不动）；记下原因显示在控制条上
    private func autoPause(because reason: String) {
        guard state == .recording else { return }
        autoPauseNote = "\(reason)时自动暂停了"   // 先记原因，暂停时控制条一次刷新就显示出来
        togglePause()
        Log.capture.notice("\(reason, privacy: .public)：录制自动暂停")
    }

    /// 收起控制条、红框、点击高亮层
    private func hideChrome() {
        stopWatchingSystemEvents()
        autoPauseNote = nil
        controlBar?.close()
        controlBar = nil
        frameWindow?.close()
        frameWindow = nil
        highlighter?.stop()
        highlighter = nil
    }

    // MARK: - 暂停 / 麦克风

    /// 暂停 / 继续（控制条上的按钮）
    func togglePause() {
        guard let recorder, isRecording else { return }
        let pause = state == .recording
        recorder.setPaused(pause)
        state = pause ? .paused : .recording
        if !pause { autoPauseNote = nil }
        frameWindow?.isPaused = pause
        controlBar?.refresh()
        Log.capture.notice("录制已\(pause ? "暂停" : "继续", privacy: .public)")
    }

    /// 麦克风静音 / 取消静音（录制中随时切换，不影响系统声音）
    func toggleMicrophoneMute() {
        guard let recorder, isRecording, capturesMicrophone else { return }
        isMicrophoneMuted.toggle()
        recorder.setMicrophoneMuted(isMicrophoneMuted)
        controlBar?.refresh()
    }

    // MARK: - 停止

    /// 停止录制并保存 MP4（录制中按录屏快捷键、点控制条或菜单「停止录制」）；之后在屏幕角落显示录屏缩略图
    func stop() async {
        guard isRecording, let recorder else { return }
        state = .stopping
        hideChrome()
        var savedURL: URL?
        do {
            let url = try await recorder.stop()
            Log.capture.notice("录屏已保存：\(url.lastPathComponent, privacy: .public)")
            savedURL = url
            #if DEBUG
            debugLastOutput = url
            #endif
        } catch {
            Log.capture.error("录屏保存失败：\(error.localizedDescription, privacy: .public)")
            showError("录屏保存失败", error)
        }
        let screen = self.screen
        self.recorder = nil
        self.screen = nil
        isMicrophoneMuted = false
        capturesMicrophone = false
        state = .idle
        if let savedURL, Preferences.shared.recordingShowThumbnail {
            await ThumbnailManager.shared.showRecording(savedURL, on: screen)
        }
    }

    private func showError(_ title: String, _ error: Error) {
        PermissionManager.shared.refresh()
        if !PermissionManager.shared.screenRecordingGranted {
            SettingsLauncher.openOnboarding()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}
