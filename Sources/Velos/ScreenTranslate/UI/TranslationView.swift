import AppKit
import VelosOCRKit
import SwiftUI
import Translation

/// 结果窗口的内容（温暖磨砂风格，与截图工具栏、设置窗口一致）：
/// 1. 顶部：原文语言 ⇄ 目标语言，右上角钉住、关闭
/// 2. 原文：可直接编辑，编辑后自动重新翻译；下方朗读、复制
/// 3. 译文：可选择；下方朗读、复制、引擎名
/// 4. 底部：复制原文和译文
struct TranslationView: View {
    @ObservedObject var model: TranslationModel
    @ObservedObject private var speaker = Speaker.shared
    let onClose: () -> Void
    let onCopy: (String, String) -> Void   // (要复制的文字, 提示语)
    let onTogglePin: () -> Void

    static let width: CGFloat = 420
    private static let textWidth = width - 2 * 14 - 2 * 12
    static var cardTextWidth: CGFloat { textWidth }
    private static let font = NSFont.systemFont(ofSize: 14)

    var body: some View {
        VStack(spacing: 10) {
            header
            sourceCard
            if let entry = model.dictionaryEntry {
                DictionaryCard(entry: entry, speaker: speaker)
            }
            translationCard
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        // 平时宽度固定、高度随内容；钉住后拖过边缘调整了大小，内容就填满窗口（原文、译文平分多出来的高度）
        .frame(width: model.isFreeSized ? nil : Self.width)
        .frame(maxWidth: model.isFreeSized ? .infinity : nil, maxHeight: model.isFreeSized ? .infinity : nil, alignment: .top)
        .fixedSize(horizontal: false, vertical: !model.isFreeSized)
        .fontDesign(.rounded)
        .tint(.apricot)
        .background(WarmWindowBackground())
        .ignoresSafeArea()   // 标题栏是隐藏的，不留出它的位置
        .translationTask(model.configuration) { session in
            await model.perform(session: session)
        }
    }

    // MARK: - 顶部：语言

    private var header: some View {
        HStack(spacing: 6) {
            LanguageMenu(title: model.sourceChoice != nil ? model.sourceLanguage.displayName
                         : model.isRecognizing ? "自动检测" : "自动检测 · \(model.sourceLanguage.displayName)",
                         help: "原文语言") {
                Button("自动检测") { model.sourceChoice = nil }
                Divider()
                ForEach(LanguageRules.appleSupported, id: \.self) { language in
                    Button(language.displayName) { model.sourceChoice = language }
                }
            }
            Button(action: model.swapLanguages) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(WarmIconButtonStyle())
            .help("交换语言")
            LanguageMenu(title: model.targetLanguage.displayName, help: "目标语言") {
                Button("自动（中文 → 英文，其他 → 简体中文）") { model.targetChoice = nil }
                Divider()
                ForEach(LanguageRules.appleSupported, id: \.self) { language in
                    Button(language.displayName) { model.targetChoice = language }
                }
            }
            Spacer(minLength: 4)
            Button(action: onTogglePin) {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .bold))
                    .rotationEffect(.degrees(model.isPinned ? 0 : 45))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(WarmIconButtonStyle(active: model.isPinned))
            .help(model.isPinned ? "取消钉住（⌘P）" : "钉住：置顶、点别处不关闭，可拖动、调整大小（⌘P）")
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: model.isPinned)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(WarmIconButtonStyle())
            .help("关闭（Esc）")
        }
        .frame(height: 30)
    }

    // MARK: - 原文

    private var sourceCard: some View {
        Card {
            if model.isRecognizing {
                PlaceholderLines(widths: [0.94, 0.72])
                if model.isSlowRecognition {
                    message("第一次识别这种文字，系统正在准备识别模型（每种文字只需要一次，可能要十几秒）…",
                            symbol: "hourglass")
                }
            } else if let failure = model.recognitionFailure {
                message(failure, symbol: "text.viewfinder")
            } else {
                TextEditor(text: $model.sourceText)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.warmInk)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(model.isFreeSized || Self.height(of: model.sourceText, max: .infinity) > 180 ? .automatic : .never)
                    .frame(height: model.isFreeSized ? nil : Self.height(of: model.sourceText, max: 180))
                    .frame(minHeight: model.isFreeSized ? 40 : nil, maxHeight: model.isFreeSized ? .infinity : nil)
                    .padding(.horizontal, -5)   // TextEditor 自带的内边距
            }
            HStack(spacing: 4) {
                speakButton(model.sourceText, language: model.sourceLanguage, id: "source")
                copyButton(model.sourceText, hint: "已复制原文")
                Spacer()
                Text(model.isRecognizing ? "正在识别…" : "原文 · \(model.sourceLanguage.displayName)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.warmSecondary)
            }
        }
    }

    // MARK: - 译文

    private var translationCard: some View {
        Card(tint: Color.apricot.opacity(0.08)) {
            Group {
                switch model.status {
                case .idle, .checking, .translating:
                    if model.translation.isEmpty {
                        // 识别、翻译中：几条柔和的占位线（不用转圈）
                        PlaceholderLines(widths: [0.88, 0.6])
                    } else {
                        // 逐段出来的新译文正常显示；编辑原文后还没翻完时，旧译文变淡
                        translationText.opacity(model.isPartial ? 1 : 0.5)
                    }
                case .needsDownload:
                    message("第一次翻译「\(model.sourceLanguage.displayName) → \(model.targetLanguage.displayName)」需要下载离线语言包，请在弹出的提示里确认下载。下载后断网也能用。",
                            symbol: "arrow.down.circle")
                case .done:
                    translationText
                case .failed(let reason):
                    message(reason, symbol: "exclamationmark.triangle")
                }
            }
            .font(.system(size: 14))
            if let notice = model.engineNotice {
                Label(notice, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.apricot)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                speakButton(model.translation, language: model.targetLanguage, id: "translation")
                copyButton(model.translation, hint: "已复制译文")
                Spacer()
                engineMenu
            }
        }
    }

    /// 引擎下拉框：显示当前引擎，可以换成其他已启用的引擎重新翻译
    private var engineMenu: some View {
        Menu {
            ForEach(EngineRouting.available) { engine in
                Button {
                    model.use(engine)
                } label: {
                    if engine == model.engine {
                        Label(engine.displayName, systemImage: "checkmark")
                    } else {
                        Text(engine.displayName)
                    }
                }
            }
            Divider()
            Button("设置翻译引擎…") { SettingsWindowController.show(.translate) }
        } label: {
            HStack(spacing: 3) {
                Text(model.engine == .apple ? "Apple 翻译 · 离线" : model.engine.displayName)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color.warmSecondary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Capsule().fill(Color.warmTrack.opacity(0.7)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("翻译引擎")
    }

    private var translationText: some View {
        ScrollView {
            Text(model.translation)
                .foregroundStyle(Color.warmInk)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(model.isFreeSized || Self.height(of: model.translation, max: .infinity) > 240 ? .automatic : .never)
        .frame(height: model.isFreeSized ? nil : Self.height(of: model.translation, max: 240))
        .frame(minHeight: model.isFreeSized ? 40 : nil, maxHeight: model.isFreeSized ? .infinity : nil)
    }

    private func message(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12.5))
            .foregroundStyle(Color.warmSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            Button {
                onCopy(model.sourceText + "\n\n" + model.translation, "已复制原文和译文")
            } label: {
                Label("复制原文和译文", systemImage: "doc.on.doc")
            }
            .buttonStyle(WarmButtonStyle())
            .disabled(model.translation.isEmpty)
            Spacer()
            if let time = model.recognitionTime {
                Text(String(format: "识别 %.2f 秒", Double(time.components.attoseconds) / 1e18 + Double(time.components.seconds)))
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Color.warmSecondary)
            }
        }
    }

    // MARK: - 小按钮

    private func speakButton(_ text: String, language: TranslateLanguage, id: String) -> some View {
        let speaking = speaker.speakingID == id
        return Button { speaker.toggle(text, language: language, id: id) } label: {
            Image(systemName: speaking ? "stop.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 22)
        }
        .buttonStyle(WarmIconButtonStyle(active: speaking))
        .help(speaking ? "停止朗读" : "朗读")
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func copyButton(_ text: String, hint: String) -> some View {
        Button { onCopy(text, hint) } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 22)
        }
        .buttonStyle(WarmIconButtonStyle())
        .help("复制")
        .disabled(text.isEmpty)
    }

    /// 文字在卡片宽度下的高度（至少一行，最多 max，超出滚动）
    static func height(of text: String, max: CGFloat) -> CGFloat {
        let measured = (text.isEmpty ? " " : text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        return min(Swift.max(ceil(measured) + 8, 22), max)
    }
}

/// 占位线：识别、翻译还没出结果时的几条圆角浅色线，轻轻地明暗呼吸（不用转圈的加载动画）
private struct PlaceholderLines: View {
    let widths: [CGFloat]

    var body: some View {
        // 按时间算明暗（正弦曲线，周期 1.5 秒）；占位线只显示零点几秒，不会一直刷新
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(alignment: .leading, spacing: 9) {
                ForEach(widths.indices, id: \.self) { index in
                    Capsule()
                        .fill(Color.warmTrack)
                        .frame(width: TranslationView.cardTextWidth * widths[index], height: 9)
                }
            }
            .opacity(0.7 + 0.3 * sin(t * .pi / 0.75))
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
        .padding(.top, 4)
        .accessibilityLabel("正在识别")
    }
}

/// 词典卡片：词条、英 / 美音标（点一下朗读）、词性和释义（每条一个例句）
private struct DictionaryCard: View {
    let entry: DictionaryEntry
    @ObservedObject var speaker: Speaker

    var body: some View {
        Card(tint: Color.chipSky.opacity(0.06)) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.headword)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.warmInk)
                    .textSelection(.enabled)
                ForEach(entry.phonetics.indices, id: \.self) { index in
                    phonetic(entry.phonetics[index], id: "phonetic-\(index)")
                }
                Spacer(minLength: 0)
            }
            ForEach(entry.parts.indices, id: \.self) { index in
                let part = entry.parts[index]
                VStack(alignment: .leading, spacing: 5) {
                    if !part.name.isEmpty {
                        Text(part.name)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.chipSky)
                            .padding(.horizontal, 7)
                            .frame(height: 18)
                            .background(Capsule().fill(Color.chipSky.opacity(0.14)))
                    }
                    ForEach(part.senses.indices, id: \.self) { number in
                        let sense = part.senses[number]
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(number + 1).")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.warmSecondary)
                                .frame(width: 16, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sense.gloss)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.warmInk)
                                if let example = sense.example {
                                    Text(example)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Color.warmSecondary)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Text("词典 · macOS 自带")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.warmSecondary)
            }
        }
    }

    /// 音标胶囊：「英 /ˈapl/ 🔊」，点一下用对应口音朗读
    private func phonetic(_ phonetic: DictionaryEntry.Phonetic, id: String) -> some View {
        let speaking = speaker.speakingID == id
        return Button {
            speaker.toggle(entry.headword, voiceLanguage: phonetic.voiceLanguage, id: id)
        } label: {
            HStack(spacing: 4) {
                if !phonetic.label.isEmpty {
                    Text(phonetic.label).font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                Text("/\(phonetic.text)/").font(.system(size: 12))
                Image(systemName: speaking ? "stop.fill" : "speaker.wave.2.fill").font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(speaking ? Color.white : Color.warmInk)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(speaking ? AnyShapeStyle(Color.apricot) : AnyShapeStyle(Color.warmTrack)))
        }
        .buttonStyle(.plain)
        .help("朗读（\(phonetic.label.isEmpty ? "普通话" : phonetic.label + "式发音")）")
    }
}

/// 结果窗口里的圆角卡片
private struct Card<Content: View>: View {
    var tint: Color = .clear
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.warmCard)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint))
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.warmHairline, lineWidth: 0.5))
    }
}

/// 语言选择：胶囊形，点开是语言列表
private struct LanguageMenu<Items: View>: View {
    let title: String
    let help: String
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.warmInk)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.warmTrack))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}

/// 小图标按钮：平时透明，悬停 / 按下时暖色底；active 时杏色
struct WarmIconButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? Color.white : Color.warmInk)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? AnyShapeStyle(Color.apricot)
                                 : AnyShapeStyle(Color.warmTrack.opacity(configuration.isPressed ? 1.6 : 0.8)))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
