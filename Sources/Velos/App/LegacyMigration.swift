import Foundation

/// 软件从 Snap 改名为 Velos（内部标识从 local.snap.Snap 换成 local.velos.Velos）后，第一次启动时把旧设置搬过来：
/// 快捷键、保存位置、截图 / 录屏 / 翻译的各项设置都照旧，不用重新设。只搬一次，之后不再读旧设置。
///
/// 不搬的：
/// - 系统权限（屏幕录制、辅助功能、麦克风）：macOS 按标识记录，新标识必须重新授权，App 没法代办
/// - 钥匙串里的翻译 Key：读旧 App 存的条目会弹系统密码框，所以不自动读；需要时在设置里重新填写
enum LegacyMigration {
    private static let doneKey = "migratedFromSnap"

    /// 必须在读任何设置（Preferences.shared）之前调用
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        #if DEBUG
        let oldDomain = "local" + ".snap.Snap.debug"
        #else
        let oldDomain = "local" + ".snap.Snap"
        #endif
        guard let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return }
        var moved = 0
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            moved += 1
        }
        Log.capture.info("从旧版 Snap 搬来 \(moved) 项设置")
    }
}
