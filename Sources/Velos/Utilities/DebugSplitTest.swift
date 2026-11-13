#if DEBUG
import AppKit
import Carbon.HIToolbox

/// VelosSettings 自测（只编进调试版）：设置窗口在子进程 VelosSettings 里打开、设置改动同步回 Velos、关掉 30 秒后它自己退出。
/// 自测期间先暂停调试版的全局快捷键，免得抢走正式版的快捷键；不截屏、不读屏幕内容。
/// 用法：open --env VELOS_SPLITTEST=/输出目录 build/Velos.app
@MainActor
enum DebugSplitTest {
    static func runIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["VELOS_SPLITTEST"] else { return }
        let dir = URL(fileURLWithPath: path)
        Task { @MainActor in
            let check = DebugUITest.Checks()
            HotkeyManager.shared.pauseAll()
            try? await Task.sleep(for: .seconds(2))
            let idle = DebugUITest.footprintMB()
            check.note("Velos 启动后空闲 \(idle) MB")

            // 1. 打开设置：启动子进程 VelosSettings
            SettingsLauncher.open(.hotkeys)
            guard let process = await waitFor({ SettingsLauncher.debugProcess }) else {
                return finish(check, dir, failing: "打开设置：启动了 VelosSettings")
            }
            try? await Task.sleep(for: .seconds(3))
            let pid = process.processIdentifier
            let settingsMB = footprintMB(of: pid)
            check("打开设置：启动了单独的进程（进程号和 Velos 不同）", pid != ProcessInfo.processInfo.processIdentifier && process.isRunning)
            let app = NSRunningApplication(processIdentifier: pid)
            check("活动监视器里的名字是 VelosSettings", app?.localizedName == "VelosSettings", app?.localizedName ?? "没有")
            check("它是 Velos 的子进程", parentPID(of: pid) == ProcessInfo.processInfo.processIdentifier, "\(parentPID(of: pid))")
            check("VelosSettings 有窗口在显示", windowCount(of: pid) > 0)
            check.note("VelosSettings \(settingsMB) MB")
            check("设置窗口开着时 Velos 本身仍然很小（\(DebugUITest.footprintMB()) MB）", DebugUITest.footprintMB() < idle + 8)

            // VELOS_SPLITTEST_RELAUNCH=1：模拟 VelosSettings 里点了「重新启动 Velos」（由外面检查：旧的 Velos 和 VelosSettings 都退出、
            // 新的 Velos 启动了一份）。这条消息 Velos 不分是谁发的，这里直接发，走的是和 VelosSettings 发来时同一条路
            if ProcessInfo.processInfo.environment["VELOS_SPLITTEST_RELAUNCH"] != nil {
                try? "\(pid)".write(to: dir.appendingPathComponent("settings.pid"), atomically: true, encoding: .utf8)
                finish(check, dir)
                SettingsProcess.post(.relaunch)
                return
            }

            // VELOS_SPLITTEST_QUIT=1：设置窗口开着时退出 Velos（由外面检查设置进程有没有跟着退出）
            if ProcessInfo.processInfo.environment["VELOS_SPLITTEST_QUIT"] != nil {
                try? "\(pid)".write(to: dir.appendingPathComponent("settings.pid"), atomically: true, encoding: .utf8)
                finish(check, dir)
                NSApp.terminate(nil)
                return
            }

            // 2. 设置进程开着时再打开：不会再开一份
            SettingsLauncher.open(.translate)
            try? await Task.sleep(for: .seconds(1.5))
            check("再次打开设置：用的还是同一个 VelosSettings", SettingsLauncher.debugProcess === process && settingsCopies() == 1,
                  "共 \(settingsCopies()) 个")

            // 3. 设置改了：Velos 重新读设置、按新的快捷键注册（模拟设置进程写入设置后发来的通知）
            let prefs = Preferences.shared
            let savedHotkey = prefs.screenshotHotkey, savedIcon = prefs.showMenuBarIcon
            let newHotkey = Hotkey(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(optionKey | shiftKey))
            UserDefaults.standard.set(newHotkey.stored, forKey: "screenshotHotkey")
            UserDefaults.standard.set(!savedIcon, forKey: "showMenuBarIcon")
            SettingsLauncher.applyChangedPreferences()
            check("设置进程改了设置：Velos 读到了新设置", prefs.screenshotHotkey == newHotkey && prefs.showMenuBarIcon == !savedIcon)
            check("设置进程改了快捷键：Velos 按新的快捷键注册", HotkeyManager.shared.hotkey(for: .screenshot) == newHotkey)
            prefs.screenshotHotkey = savedHotkey
            prefs.showMenuBarIcon = savedIcon
            CaptureCoordinator.shared.rebindHotkeysFromPreferences()

            // 4. 关掉设置窗口：30 秒后设置进程退出，内存全部还给系统
            SettingsProcess.post(.debugCloseWindows)
            try? await Task.sleep(for: .seconds(20))
            check("关掉设置窗口 20 秒后，VelosSettings 还在（30 秒内再打开可以直接用）", process.isRunning)
            let quit = await waitFor(timeout: 20) { process.isRunning ? nil : true } ?? false
            check("关掉设置窗口 30 秒后，VelosSettings 自己退出了", quit)
            try? await Task.sleep(for: .milliseconds(500))
            check("VelosSettings 退出后 Velos 知道了（可以重新打开）", !SettingsLauncher.isProcessRunning)
            check("VelosSettings 退出后 Velos 的全局快捷键恢复正常（不会一直暂停）", !HotkeyManager.shared.debugAllPaused)
            HotkeyManager.shared.pauseAll()   // 自测还没结束：继续不抢正式版的快捷键
            check.note("全部结束后 Velos \(DebugUITest.footprintMB()) MB")
            finish(check, dir)
        }
    }

    private static func finish(_ check: DebugUITest.Checks, _ dir: URL, failing: String? = nil) {
        if let failing { check(failing, false) }
        try? check.lines.joined(separator: "\n").write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
    }

    private static func waitFor<T>(timeout: Double = 8, _ value: () -> T?) async -> T? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let found = value() { return found }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// 另一个进程的内存占用（MB）
    private static func footprintMB(of pid: pid_t) -> Int {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int(info.ri_phys_footprint / 1_048_576) : -1
    }

    /// 这个进程在屏幕上的窗口数（只看窗口列表，不读窗口内容）
    private static func windowCount(of pid: pid_t) -> Int {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }.count
    }

    /// 正在运行的 VelosSettings（调试版）有几个
    private static func settingsCopies() -> Int {
        NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.settingsBundleID).filter { !$0.isTerminated }.count
    }

    /// 父进程号
    private static func parentPID(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size > 0 ? pid_t(info.pbi_ppid) : -1
    }
}
#endif
