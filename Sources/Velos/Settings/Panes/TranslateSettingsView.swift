import VelosOCRKit
import SwiftUI

/// 截屏翻译：文字识别、翻译引擎、结果窗口（快捷键在「快捷键」里）
struct TranslateSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var engines = EngineSettingsModel.shared

    /// OCR 优先语言的选项（常用的几种；空字符串 = 跟随系统）
    private static let languages: [TranslateLanguage] = [
        .simplifiedChinese, .traditionalChinese, .english, .japanese, .korean,
        .french, .german, .spanish, .russian,
    ]

    var body: some View {
        SettingsPane {
            SettingsSection(title: "文字识别",
                            footer: "完全离线，使用系统自带的 Vision 文字识别；识别在单独的小进程里进行，空闲 30 秒后自动退出、释放内存。") {
                SettingsRow(icon: "globe", tint: .chipSky, title: "优先识别的语言",
                            caption: "文字较短、语言不好判断时优先按这种语言识别", isFirst: true) {
                    Picker("", selection: $prefs.ocrPreferredLanguage) {
                        Text("跟随系统").tag("")
                        Divider()
                        ForEach(Self.languages, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SwitchRow(icon: "text.alignleft", tint: .apricot, title: "智能排版",
                          caption: prefs.ocrSmartLayout ? "合并成段落，处理连字符、中英文之间的空格、诗歌和列表"
                                                        : "关闭：保留图片里原来的换行",
                          isOn: $prefs.ocrSmartLayout)
                SwitchRow(icon: "qrcode", tint: .chipCocoa, title: "同时识别二维码",
                          caption: "二维码的内容附在文字后面", isOn: $prefs.ocrDetectsQRCodes)
            }

            SettingsSection(title: "翻译引擎",
                            footer: "Apple 翻译离线、免费。需要 Key 的在线引擎都在「在线翻译」里：先选服务商，填写 Key 后打开开关；可以启用多个。启用后才会联网，原文只发送给所选的服务商，Key 保存在钥匙串里。默认引擎失败时会自动换到下一个可用的引擎。") {
                SettingsRow(icon: "star.fill", tint: .apricot, title: "默认引擎", isFirst: true) {
                    Picker("", selection: $prefs.defaultEngine) {
                        ForEach(engines.selectable) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                OnlineEngineGroup(model: engines, prompt: $prefs.llmPrompt)
            }

            SettingsSection(title: "结果窗口",
                            footer: "窗口里的快捷键：⌘C 复制译文、⇧⌘C 复制原文、⌘R 重新翻译、⌘P 钉住 / 取消钉住、Esc 关闭。截屏翻译的快捷键在「快捷键」里设置。") {
                SettingsRow(icon: "arrow.right.circle.fill", tint: .chipSky, title: "默认目标语言",
                            caption: prefs.defaultTargetLanguage.isEmpty ? "自动：中文译成英文，其他语言译成简体中文"
                                                                         : "原文就是这种语言时，中文译成英文、其他译成简体中文",
                            isFirst: true) {
                    Picker("", selection: $prefs.defaultTargetLanguage) {
                        Text("自动").tag("")
                        Divider()
                        ForEach(Self.languages, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SwitchRow(icon: "doc.on.clipboard.fill", tint: .chipHoney, title: "翻译完成后自动复制译文",
                          caption: "复制到剪贴板，可以直接粘贴", isOn: $prefs.translateAutoCopy)
                SettingsRow(icon: "speaker.wave.2.fill", tint: .chipSage, title: "朗读语速") {
                    WarmSegmented(options: [(0.42, "慢"), (0.5, "正常"), (0.57, "快")], selection: $prefs.speechRate,
                                  segmentWidth: 52)
                }
                SwitchRow(icon: "pin.fill", tint: .apricot, title: "默认钉住",
                          caption: "钉住的窗口置顶、点别处不会关闭，可以拖动、调整大小，也可以同时钉住多个对照着看。",
                          isOn: $prefs.translateWindowPinnedByDefault)
            }
        }
    }
}

/// 翻译引擎设置的界面状态：Key 输入框的内容（读写钥匙串）、测试结果
@MainActor
final class EngineSettingsModel: ObservableObject {
    static let shared = EngineSettingsModel()

    @Published private var values: [String: String] = [:]
    @Published private(set) var testResults: [EngineID: (ok: Bool, text: String)] = [:]
    @Published private(set) var testing: Set<EngineID> = []
    /// 「在线翻译」里当前显示的服务商：先显示已启用的第一个，没有就显示腾讯翻译君
    @Published var selected: EngineID = {
        let enabled = Set(Preferences.shared.enabledEngines)
        return [EngineID.tencent, .volcengine, .baidu, .youdao, .deepl, .azure, .openAI, .claude]
            .first { enabled.contains($0.rawValue) } ?? .tencent
    }()

    /// 默认引擎可选的：Apple 翻译 + 已启用并填了 Key 的引擎
    var selectable: [EngineID] {
        _ = values   // 填了 Key 后刷新
        return EngineRouting.available
    }

    func isEnabled(_ engine: EngineID) -> Bool { Preferences.shared.enabledEngines.contains(engine.rawValue) }

    func setEnabled(_ engine: EngineID, _ enabled: Bool) {
        var list = Preferences.shared.enabledEngines.filter { $0 != engine.rawValue }
        if enabled { list.append(engine.rawValue) }
        Preferences.shared.enabledEngines = list
        if !enabled, Preferences.shared.defaultEngine == engine.rawValue { Preferences.shared.defaultEngine = EngineID.apple.rawValue }
        objectWillChange.send()
    }

    /// 输入框绑定：读的时候从钥匙串取，改的时候写回钥匙串
    func binding(_ engine: EngineID, _ field: String) -> Binding<String> {
        let key = "\(engine.rawValue).\(field)"
        return Binding(
            get: { [weak self] in self?.values[key] ?? engine.credential(field) },
            set: { [weak self] value in
                self?.values[key] = value
                engine.setCredential(value, for: field)
                self?.testResults[engine] = nil
            }
        )
    }

    /// 测试：把「Hello, world.」翻译成简体中文
    func test(_ engine: EngineID) {
        testing.insert(engine)
        testResults[engine] = nil
        Task { @MainActor in
            defer { testing.remove(engine) }
            do {
                let output = try await engine.translate("Hello, world.", from: .english, to: .simplifiedChinese)
                testResults[engine] = (true, "可以使用：Hello, world. → \(output)")
            } catch {
                testResults[engine] = (false, error.localizedDescription)
            }
        }
    }
}

/// 需要 Key 的在线引擎合成一项：右边选服务商，下面是这个服务商的开关、Key、测试和申请链接；可以逐个启用多个
private struct OnlineEngineGroup: View {
    @ObservedObject var model: EngineSettingsModel
    @Binding var prompt: String

    /// 翻译服务（免费额度多的在前）和大模型
    static let services: [EngineID] = [.tencent, .volcengine, .baidu, .youdao, .deepl, .azure]
    static let models: [EngineID] = [.openAI, .claude]

    private func label(_ engine: EngineID) -> String {
        model.isEnabled(engine) ? "\(engine.displayName)  ✓" : engine.displayName
    }

    var body: some View {
        let enabledNames = (Self.services + Self.models).filter(model.isEnabled).map(\.displayName)
        SettingsRow(icon: "key.fill", tint: .chipSage, title: "在线翻译",
                    caption: enabledNames.isEmpty ? "需要自己的 Key · 还没有启用"
                                                  : "已启用：" + enabledNames.joined(separator: "、")) {
            Picker("", selection: $model.selected) {
                Section("翻译服务") {
                    ForEach(Self.services) { Text(label($0)).tag($0) }
                }
                Section("大模型") {
                    ForEach(Self.models) { Text(label($0)).tag($0) }
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        EngineDetail(engine: model.selected, model: model)
        if model.selected.isLLM {
            LLMPromptRow(prompt: $prompt)
        }
    }
}

/// 选中的服务商：启用开关、Key 输入框、测试按钮、申请 Key 的链接
private struct EngineDetail: View {
    let engine: EngineID
    @ObservedObject var model: EngineSettingsModel

    var body: some View {
        let enabled = model.isEnabled(engine)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("启用")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.warmSecondary)
                    .frame(width: 110, alignment: .trailing)
                Toggle("", isOn: Binding(get: { enabled }, set: { model.setEnabled(engine, $0) }))
                    .toggleStyle(WarmSwitchStyle())
                    .labelsHidden()
                Text(enabled ? (engine.hasCredentials ? "已启用「\(engine.displayName)」" : "已启用 · 还没有填写 Key")
                             : "未启用，不会联网")
                    .settingsCaption()
                Spacer()
            }
            ForEach(engine.fields, id: \.key) { field in
                HStack(spacing: 8) {
                    Text(field.label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.warmSecondary)
                        .frame(width: 110, alignment: .trailing)
                    Group {
                        if field.secret {
                            SecureField(field.placeholder, text: model.binding(engine, field.key))
                        } else {
                            TextField(field.placeholder, text: model.binding(engine, field.key))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                }
            }
            HStack(spacing: 8) {
                Spacer().frame(width: 110)
                Button(model.testing.contains(engine) ? "测试中…" : "测试") { model.test(engine) }
                    .buttonStyle(WarmButtonStyle(prominent: true))
                    .disabled(model.testing.contains(engine) || !engine.hasCredentials)
                if let url = engine.consoleURL {
                    Link("申请 Key", destination: url)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.apricot)
                }
                Spacer()
            }
            if let result = model.testResults[engine] {
                Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(result.ok ? Color.chipSage : Color.coral)
                    .padding(.leading, 118)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 13)
        .padding(.bottom, 12)
        .id(engine)
    }
}

/// 大模型翻译的提示词：留空用默认的；{source}、{target} 会换成原文语言、目标语言
private struct LLMPromptRow: View {
    @Binding var prompt: String

    var body: some View {
        SettingsRow(icon: "text.quote", tint: .chipLavender, title: "大模型提示词",
                    caption: "只对大模型生效。{source} 和 {target} 会换成原文语言和目标语言。") {
            if !prompt.isEmpty {
                Button("恢复默认") { prompt = "" }
                    .buttonStyle(WarmButtonStyle())
            }
        }
        TextEditor(text: Binding(get: { prompt.isEmpty ? LLMTranslation.defaultPrompt : prompt },
                                 set: { prompt = $0 == LLMTranslation.defaultPrompt ? "" : $0 }))
            .font(.system(size: 12))
            .foregroundStyle(Color.warmInk)
            .scrollContentBackground(.hidden)
            .frame(height: 96)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.warmTrack.opacity(0.6)))
            .padding(.horizontal, 13)
            .padding(.bottom, 12)
    }
}
