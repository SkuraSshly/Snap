import AppKit
import Carbon.HIToolbox

/// 全局快捷键：用 Carbon 的 RegisterEventHotKey 注册。
/// - 系统会直接把按键交给 Velos，不会再传给当前输入框，所以不会打出 å ß 之类的字符
/// - Carbon 修饰键不区分左右，左右 Option 都能触发
/// - 不需要「辅助功能」权限，空闲时不占 CPU
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    enum Action: UInt32, CaseIterable {
        case screenshot = 1
        case recording = 2
        case translate = 3
    }

    /// 快捷键「真正按下」时回调（按住不放产生的重复事件已被过滤）
    var onPress: ((Action) -> Void)?

    /// 注册失败的快捷键（通常是被其他程序占用了）
    private(set) var failedActions: Set<Action> = []

    private var bindings: [Action: Hotkey] = [:]
    private var registered: [Action: EventHotKeyRef] = [:]
    private var suspended: Set<Action> = []
    /// 设置界面正在录制新快捷键：暂时注销全部快捷键，免得按下的组合键直接触发截图 / 录屏
    private var allPaused = false
    /// 已按下、尚未松开的快捷键：用来忽略按住不放时可能出现的重复按下事件
    private var held: Set<Action> = []
    private var handlerRef: EventHandlerRef?
    /// 临时快捷键（例如长截图期间的 Esc）：编号从 100 开始，和三个固定动作区分开
    private var temporary: [UInt32: (ref: EventHotKeyRef, handler: () -> Void)] = [:]
    private var nextTemporaryID: UInt32 = 100

    /// 'VELO'，用来区分是不是本程序注册的快捷键
    private static let signature: OSType = 0x5645_4C4F

    private init() {}

    /// 设置（或更换）某个动作的快捷键；传 nil 表示不注册
    /// - Returns: 注册是否成功（失败通常是被其他程序以独占方式占用了）
    @discardableResult
    func bind(_ action: Action, to hotkey: Hotkey?) -> Bool {
        installHandlerIfNeeded()
        unregister(action)
        bindings[action] = hotkey
        failedActions.remove(action)
        if !suspended.contains(action), !allPaused {
            register(action)
        }
        return !failedActions.contains(action)
    }

    /// 试注册一个快捷键，看系统是否允许（不影响现有绑定）
    func canRegister(_ hotkey: Hotkey) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 99)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }

    /// 暂停 / 恢复全部快捷键（设置界面录制新快捷键期间）
    func pauseAll() {
        allPaused = true
        for action in Action.allCases { unregister(action) }
    }

    func resumeAll() {
        guard allPaused else { return }
        allPaused = false
        for action in Action.allCases where !suspended.contains(action) { register(action) }
    }

    func hotkey(for action: Action) -> Hotkey? {
        bindings[action]
    }

    /// 暂停全局快捷键：截图界面出现后由界面窗口自己处理按键，避免同一次按键被处理两次
    func suspend(_ action: Action) {
        suspended.insert(action)
        unregister(action)
    }

    func resume(_ action: Action) {
        guard suspended.remove(action) != nil, !allPaused else { return }
        register(action)
    }

    /// 注册一个临时快捷键（例如长截图期间按 Esc 取消）。注册期间这个按键只交给 Velos，不会传给当前 App。
    /// - Returns: 编号，用 removeTemporary 注销；注册失败（被别的程序占用）时返回 nil
    func addTemporary(keyCode: Int, modifiers: UInt32 = 0, handler: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let number = nextTemporaryID
        nextTemporaryID += 1
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: number)
        guard RegisterEventHotKey(UInt32(keyCode), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref else {
            return nil
        }
        temporary[number] = (ref, handler)
        return number
    }

    func removeTemporary(_ number: UInt32) {
        if let entry = temporary.removeValue(forKey: number) { UnregisterEventHotKey(entry.ref) }
    }

    #if DEBUG
    var debugRegisteredCount: Int { registered.count }
    var debugTemporaryCount: Int { temporary.count }
    func debugPressTemporary(_ number: UInt32) { handle(id: number, isPress: true) }
    #endif

    // MARK: - 注册

    private func register(_ action: Action) {
        guard let hotkey = bindings[action], registered[action] == nil else { return }
        held.remove(action)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            registered[action] = ref
            failedActions.remove(action)
        } else {
            failedActions.insert(action)
            Log.hotkey.error("快捷键 \(hotkey.displayString, privacy: .public) 注册失败：\(status)")
        }
    }

    private func unregister(_ action: Action) {
        held.remove(action)
        if let ref = registered.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }

    // MARK: - 事件处理

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        // C 回调不能捕获上下文，所以通过单例转发；应用事件目标上的回调总是在主线程执行
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotkeyManager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated {
                HotkeyManager.shared.handle(id: hotKeyID.id, isPress: isPress)
            }
            return noErr
        }, eventTypes.count, &eventTypes, nil, &handlerRef)
    }

    private func handle(id: UInt32, isPress: Bool) {
        if let entry = temporary[id] {
            if isPress { entry.handler() }
            return
        }
        guard let action = Action(rawValue: id) else { return }
        if isPress {
            // 按住不放时只认第一次按下
            guard held.insert(action).inserted else { return }
            onPress?(action)
        } else {
            held.remove(action)
        }
    }
}
