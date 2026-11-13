import AppKit

/// 设置窗口（和权限引导）在单独的进程 VelosSettings 里显示，和文字识别的 VelosOCR 一样各管一摊：
/// - Velos：常驻，只做一直要做的事（快捷键、菜单栏图标、截图、录屏），保持十几 MB
/// - VelosOCR：系统管理的后台服务，识别完 30 秒后退出
/// - VelosSettings：打开设置时由 Velos 作为子进程启动，关掉窗口 30 秒后自己退出
///
/// 为什么拆出来：设置窗口用 SwiftUI 画，第一次打开会把 SwiftUI 等系统框架和它们的缓存加载进进程（约 15–30 MB），
/// 关掉窗口也还不回去——macOS 没法卸掉已经加载的框架，只有进程退出才全部归还。
///
/// VelosSettings 是 Velos.app/Contents/Helpers 里的一个小 App，程序和 Velos 是同一份（build.sh 打包时复制一份，
/// 用自己的名字和标识），启动后进入「设置模式」。它是 Velos 的子进程：系统把它的权限算在 Velos 名下，
/// 所以设置里显示的屏幕录制、麦克风权限就是 Velos 的。它读写的是 Velos 的设置文件（见 AppIdentity）。
///
/// 两个进程之间用分布式通知说话（只在本机、本用户之间，不联网；不传 Key 之类的机密）：
/// - VelosSettings → Velos：设置改了、录快捷键期间暂停 / 恢复全局快捷键、打开 / 关闭登录时启动、重新启动 Velos
/// - Velos → VelosSettings：显示设置窗口（切到某一页）或权限引导、Velos 里改了设置
enum SettingsProcess {
    /// 启动参数：`--velos-settings=<栏目或 onboarding>`、`--velos-main-pid=<Velos 的进程号>`
    static let modeArgument = "--velos-settings="
    static let mainPIDArgument = "--velos-main-pid="

    /// 这个进程是不是 VelosSettings
    static var isSettingsProcess: Bool { AppIdentity.isSettingsApp }

    /// VelosSettings 要显示的内容
    enum Page: Equatable {
        case settings(SettingsTab?)
        case onboarding

        var argumentValue: String {
            switch self {
            case .settings(let tab): tab?.rawValue ?? "default"
            case .onboarding: "onboarding"
            }
        }

        init(argumentValue: String) {
            self = argumentValue == "onboarding" ? .onboarding : .settings(SettingsTab(rawValue: argumentValue))
        }
    }

    /// 两个进程之间的消息（名字带上 Velos 的标识：调试版和正式版同时运行时互不干扰）
    enum Message: String {
        /// Velos → VelosSettings：显示页面（userInfo["page"]）
        case show
        /// 设置改了（两个方向都发：VelosSettings 里改的，Velos 要跟着变；Velos 里改的，例如录制选项条，开着的设置窗口要跟着变）
        case preferencesChanged
        /// VelosSettings → Velos：录快捷键期间暂停 / 恢复全局快捷键（免得按下去直接截图）
        case pauseHotkeys, resumeHotkeys
        /// VelosSettings → Velos：打开 / 关闭登录时启动（userInfo["enabled"] 是 "1" 或 "0"）。
        /// 系统的登录项只能由 App 自己登记，VelosSettings 登记的会是它自己
        case setLaunchAtLogin
        /// VelosSettings → Velos：重新启动（屏幕录制权限刚打开，要重启才生效）
        case relaunch
        #if DEBUG
        /// 自测：Velos → VelosSettings，关掉所有窗口（模拟用户关掉设置窗口）
        case debugCloseWindows
        #endif

        var name: Notification.Name { Notification.Name("\(AppIdentity.mainBundleID).\(rawValue)") }
    }

    static func post(_ message: Message, userInfo: [String: String] = [:]) {
        var info = userInfo
        info[senderKey] = String(ProcessInfo.processInfo.processIdentifier)
        // deliverImmediately：两个进程平时都不是前台 App，不加的话系统会把通知攒着，等它变成前台才送到
        DistributedNotificationCenter.default().postNotificationName(message.name, object: nil, userInfo: info,
                                                                     deliverImmediately: true)
    }

    private static let senderKey = "sender"

    /// 是不是自己发出的（自己发的分布式通知自己也会收到）
    static func isOwn(_ notification: Notification) -> Bool {
        notification.userInfo?[senderKey] as? String == String(ProcessInfo.processInfo.processIdentifier)
    }

    // MARK: - VelosSettings 这一边

    /// 启动时要显示的页面（没有参数时显示设置的第一页）
    static var initialPage: Page {
        let value = CommandLine.arguments.first { $0.hasPrefix(modeArgument) }?.dropFirst(modeArgument.count)
        return Page(argumentValue: value.map(String.init) ?? "default")
    }

    /// 启动 VelosSettings 的那个 Velos 的进程号（它退出时 VelosSettings 跟着退出）
    static var mainPID: pid_t? {
        CommandLine.arguments.first { $0.hasPrefix(mainPIDArgument) }
            .flatMap { pid_t($0.dropFirst(mainPIDArgument.count)) }
    }

    /// 设置有改动时通知另一个进程（VelosSettings 开着的时候）。拖拉条这类连续的改动合并成一次（0.15 秒内只发一条）
    @MainActor
    static func notePreferencesChanged() {
        guard isSettingsProcess || SettingsLauncher.isProcessRunning, !changePending else { return }
        changePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            changePending = false
            post(.preferencesChanged)
        }
    }

    @MainActor private static var changePending = false

    /// 让 Velos 的设置文件读到另一个进程刚写进去的内容
    static func synchronizePreferences() {
        CFPreferencesAppSynchronize(AppIdentity.mainBundleID as CFString)
    }
}

/// 这个进程是谁、该读写哪份设置
enum AppIdentity {
    private static let settingsSuffix = ".settings"

    /// 这个进程是 VelosSettings（标识是 Velos 的标识加 .settings）
    static let isSettingsApp = Bundle.main.bundleIdentifier?.hasSuffix(settingsSuffix) == true

    /// Velos 的标识（在 VelosSettings 里去掉 .settings）
    static let mainBundleID: String = {
        let id = Bundle.main.bundleIdentifier ?? "local.velos.Velos"
        return isSettingsApp ? String(id.dropLast(settingsSuffix.count)) : id
    }()

    /// VelosSettings 的标识
    static var settingsBundleID: String { mainBundleID + settingsSuffix }

    /// Velos 的设置文件。VelosSettings 读写的也是这一份（不是它自己的）
    nonisolated(unsafe) static let defaults: UserDefaults =
        isSettingsApp ? (UserDefaults(suiteName: mainBundleID) ?? .standard) : .standard
}

/// 收分布式通知（立即送达）。用 selector 形式注册，才能指定 .deliverImmediately
final class DistributedObserver: NSObject {
    private let handler: @MainActor (Notification) -> Void
    private let name: Notification.Name

    init(_ name: Notification.Name, handler: @escaping @MainActor (Notification) -> Void) {
        self.name = name
        self.handler = handler
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receive(_:)), name: name,
                                                            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func receive(_ notification: Notification) {
        let handler = self.handler
        if Thread.isMainThread {
            MainActor.assumeIsolated { handler(notification) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(notification) } }
        }
    }

    func invalidate() {
        DistributedNotificationCenter.default().removeObserver(self, name: name, object: nil)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
}

// MARK: - Velos 这一边：打开设置

/// Velos 里所有「打开设置 / 权限引导」都走这里：启动 VelosSettings，已经开着的就叫它显示
@MainActor
enum SettingsLauncher {
    private static var process: Process?
    private static var observers: [DistributedObserver] = []

    static func open(_ tab: SettingsTab? = nil) { show(.settings(tab)) }
    static func openOnboarding() { show(.onboarding) }

    /// VelosSettings 开着
    static var isProcessRunning: Bool { process?.isRunning ?? false }

    #if DEBUG
    static var debugProcess: Process? { process }
    #endif

    /// Velos.app 里的 VelosSettings
    private static var executableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/VelosSettings.app/Contents/MacOS/VelosSettings")
    }

    /// 在 Velos 进程里直接显示（VelosSettings 自己、找不到或启动不了 VelosSettings 时、调试版自测时）
    private static func showInProcess(_ page: SettingsProcess.Page) {
        switch page {
        case .settings(let tab): SettingsWindowController.show(tab)
        case .onboarding: OnboardingWindowController.show(over: SettingsWindowController.currentWindow)
        }
    }

    private static func show(_ page: SettingsProcess.Page) {
        if SettingsProcess.isSettingsProcess || runsInProcess { return showInProcess(page) }
        listen()
        // 让 VelosSettings 能切到前台（macOS 的激活是协作式的：前台的 App 要让出来）
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: AppIdentity.settingsBundleID)
        if isProcessRunning {
            SettingsProcess.post(.show, userInfo: ["page": page.argumentValue])
            return
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            Log.capture.error("找不到 VelosSettings，设置窗口改为在 Velos 里打开")
            return showInProcess(page)
        }
        let child = Process()
        child.executableURL = executableURL
        child.arguments = [SettingsProcess.modeArgument + page.argumentValue,
                           SettingsProcess.mainPIDArgument + String(ProcessInfo.processInfo.processIdentifier)]
        // 调试用的环境变量（自测开关）不带给 VelosSettings
        child.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("VELOS_") }
        child.terminationHandler = { ended in
            DispatchQueue.main.async { MainActor.assumeIsolated { processEnded(ended) } }
        }
        do {
            try child.run()
            process = child
            Log.capture.notice("VelosSettings 已启动（子进程 \(child.processIdentifier)）")
        } catch {
            // 启动不了（极少见）：退回到在 Velos 里直接显示
            Log.capture.error("VelosSettings 启动失败：\(error.localizedDescription, privacy: .public)，改为在 Velos 里打开")
            showInProcess(page)
        }
    }

    /// 开始听 VelosSettings 的消息（只注册一次）
    private static func listen() {
        guard observers.isEmpty else { return }
        observers = [
            DistributedObserver(SettingsProcess.Message.preferencesChanged.name) { notification in
                if !SettingsProcess.isOwn(notification) { applyChangedPreferences() }
            },
            DistributedObserver(SettingsProcess.Message.pauseHotkeys.name) { _ in HotkeyManager.shared.pauseAll() },
            DistributedObserver(SettingsProcess.Message.resumeHotkeys.name) { _ in HotkeyManager.shared.resumeAll() },
            DistributedObserver(SettingsProcess.Message.setLaunchAtLogin.name) { notification in
                LaunchAtLogin.shared.setEnabled(notification.userInfo?["enabled"] as? String == "1")
            },
            DistributedObserver(SettingsProcess.Message.relaunch.name) { _ in PermissionManager.shared.relaunch() },
        ]
    }

    /// VelosSettings 退出了：万一它在录快捷键的中途退出，全局快捷键还暂停着，恢复它；再读一次设置
    private static func processEnded(_ ended: Process) {
        guard process === ended else { return }
        process = nil
        HotkeyManager.shared.resumeAll()
        applyChangedPreferences()
        Log.capture.notice("VelosSettings 已退出")
    }

    /// 另一个进程改了设置：重新读设置（用到设置的地方都跟着变）、按新的快捷键重新注册、忘掉记住的 Key（可能换了）
    static func applyChangedPreferences() {
        SettingsProcess.synchronizePreferences()
        Preferences.shared.reloadFromStore()
        CaptureCoordinator.shared.rebindHotkeysFromPreferences()
        EngineKeychain.forgetCached()
    }

    /// 调试版自测：设置窗口在自测进程里直接打开（自测要直接检查窗口里的内容）；专门测 VelosSettings 的自测除外
    private static var runsInProcess: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("VELOS_") && !$0.hasPrefix("VELOS_SPLITTEST") }
        #else
        false
        #endif
    }
}

// MARK: - VelosSettings 这一边：显示、闲置退出

/// VelosSettings 的生命周期：显示要求的页面；窗口都关了 30 秒后退出（期间再打开就接着用）；启动它的 Velos 退出时跟着退出
@MainActor
final class SettingsProcessController {
    static let shared = SettingsProcessController()

    /// 窗口都关了以后多久退出
    static let idleTimeout: TimeInterval = 30

    private var observers: [DistributedObserver] = []
    private var tokens: [NSObjectProtocol] = []
    /// 启动它的 Velos，和对它「退出了没有」的监听。监听不会留住被监听的对象，要自己留着，
    /// 否则对象先释放、监听还挂在上面，进程会崩溃
    private var mainApp: NSRunningApplication?
    private var mainObservation: NSKeyValueObservation?
    private var quitTimer: Timer?

    func start() {
        // VelosSettings 只带了小图标，界面里用的大图标从 Velos.app 读（…/Velos.app/Contents/Helpers/VelosSettings.app）
        let velosApp = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let icon = NSImage(contentsOf: velosApp.appendingPathComponent("Contents/Resources/AppIcon.icns")) {
            NSApp.applicationIconImage = icon
        }
        Log.capture.notice("VelosSettings 已启动，屏幕录制权限：\(PermissionManager.shared.screenRecordingGranted ? "已授权" : "未授权", privacy: .public)")
        // Velos 里改了设置（例如录制选项条、登录时启动）：开着的设置窗口跟着变
        observers.append(DistributedObserver(SettingsProcess.Message.preferencesChanged.name) { notification in
            guard !SettingsProcess.isOwn(notification) else { return }
            SettingsProcess.synchronizePreferences()
            Preferences.shared.reloadFromStore()
            LaunchAtLogin.shared.refresh()
        })
        #if DEBUG
        observers.append(DistributedObserver(SettingsProcess.Message.debugCloseWindows.name) { _ in
            NSApp.windows.filter(\.isVisible).forEach { $0.close() }
        })
        #endif
        observers.append(DistributedObserver(SettingsProcess.Message.show.name) { [weak self] notification in
            let value = notification.userInfo?["page"] as? String ?? "default"
            self?.show(SettingsProcess.Page(argumentValue: value))
        })
        // 窗口关了：看看还有没有别的窗口开着，都关了就开始计时
        tokens.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                                             queue: .main) { [weak self] notification in
            let closing = notification.object as? NSWindow
            MainActor.assumeIsolated { self?.windowWillClose(closing) }
        })
        // 启动它的 Velos 退出了（退出 Velos、Velos 重新启动、意外退出）：跟着退出。
        // 没有 Velos 的进程号（例如有人直接打开了 VelosSettings.app）也不留着：只有 Velos 能用它
        guard let mainPID = SettingsProcess.mainPID,
              let main = NSRunningApplication(processIdentifier: mainPID), !main.isTerminated else {
            Log.capture.notice("VelosSettings：没有在运行的 Velos，退出")
            return NSApp.terminate(nil)
        }
        mainApp = main
        mainObservation = main.observe(\.isTerminated, options: [.new]) { main, _ in
            guard main.isTerminated else { return }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        show(SettingsProcess.initialPage)
    }

    private func show(_ page: SettingsProcess.Page) {
        quitTimer?.invalidate()
        quitTimer = nil
        switch page {
        case .settings(let tab): SettingsWindowController.show(tab)
        case .onboarding: OnboardingWindowController.show(over: SettingsWindowController.currentWindow)
        }
    }

    private func windowWillClose(_ closing: NSWindow?) {
        let others = NSApp.windows.contains { $0 !== closing && $0.isVisible && !($0 is NSPanel) && $0.canBecomeKey }
        guard !others else { return }
        quitTimer?.invalidate()
        quitTimer = Timer.scheduledTimer(withTimeInterval: Self.idleTimeout, repeats: false) { _ in
            MainActor.assumeIsolated {
                Log.capture.notice("VelosSettings：窗口都关了 \(Int(Self.idleTimeout)) 秒，退出（释放内存）")
                NSApp.terminate(nil)
            }
        }
    }
}
