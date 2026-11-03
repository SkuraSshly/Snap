import SnapOCRKit
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
                            footer: "Apple 翻译离线、免费。在线引擎默认全部关闭；启用并填写 Key 后才会联网，原文只发送给所选的服务商。Key 保存在钥匙串里。默认引擎失败时会自动换到下一个可用的引擎。") {
                SettingsRow(icon: "star.fill", tint: .apricot, title: "默认引擎", isFirst: true) {
                    Picker("", selection: $prefs.defaultEngine) {
                        ForEach(engines.selectable) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                ForEach(EngineID.allCases.filter { $0 != .apple }) { engine in
                    EngineRow(engine: engine, model: engines)
                }
                if EngineID.allCases.contains(where: { $0.isLLM && engines.isEnabled($0) }) {
                    LLMPromptRow(prompt: $prefs.llmPrompt)
                }
            }

            SettingsSection(title: "结果窗口",
                            footer: "窗口里的快捷键：⌘C 复制译文、⇧⌘C 复制原文、⌘R 重新翻译、⌘P 钉住 / 取消钉住、Esc 关闭。") {
                SwitchRow(icon: "pin.fill", tint: .apricot, title: "默认钉住",
                          caption: "钉住的窗口置顶、点别处不会关闭，可以拖动、调整大小，也可以同时钉住多个对照着看。",
                          isFirst: true, isOn: $prefs.translateWindowPinnedByDefault)
            }

            SettingsSection(title: "即将加入", footer: "截屏翻译的快捷键在「快捷键」里设置。") {
                SettingsRow(icon: "sparkles", tint: .chipLavender, title: "查词、在线引擎、历史记录",
                            caption: "默认目标语言、朗读语速、单词查词、可选的在线翻译引擎、翻译历史，会在后续版本陆续出现在这里。",
                            isFirst: true) {
                    EmptyView()
                }
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

/// 一个在线引擎：开关；启用后显示 Key 输入框、测试按钮、申请 Key 的链接
private struct EngineRow: View {
    let engine: EngineID
    @ObservedObject var model: EngineSettingsModel

    private var tint: Color {
        switch engine {
        case .youdao: .coral
        case .deepl: .chipSky
        case .azure: .chipLavender
        case .baidu: .chipHoney
        case .tencent: .chipSage
        case .openAI: .chipCocoa
        case .claude: .apricot
        default: .chipCocoa
        }
    }

    var body: some View {
        let enabled = model.isEnabled(engine)
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(icon: engine.isLLM ? "sparkles" : "globe.asia.australia.fill", tint: tint, title: engine.displayName,
                        caption: enabled ? (engine.hasCredentials ? "已启用" : "已启用 · 还没有填写 Key") : "未启用") {
                Toggle("", isOn: Binding(get: { enabled }, set: { model.setEnabled(engine, $0) }))
                    .toggleStyle(WarmSwitchStyle())
                    .labelsHidden()
            }
            if enabled {
                VStack(alignment: .leading, spacing: 8) {
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
            }
        }
    }
}

/// 大模型翻译的提示词：留空用默认的；{source}、{target} 会换成原文语言、目标语言
private struct LLMPromptRow: View {
    @Binding var prompt: String

    var body: some View {
        SettingsRow(icon: "text.quote", tint: .chipLavender, title: "大模型提示词",
                    caption: "只对大模型引擎生效。{source} 和 {target} 会换成原文语言和目标语言。") {
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
