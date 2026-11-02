import SnapOCRKit
import SwiftUI

/// 截屏翻译：文字识别（快捷键在「快捷键」里）。翻译引擎、目标语言、结果窗口、历史记录在后续阶段加入这里。
struct TranslateSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

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

            SettingsSection(title: "即将加入", footer: "截屏翻译的快捷键在「快捷键」里设置。") {
                SettingsRow(icon: "sparkles", tint: .chipLavender, title: "翻译、结果窗口、历史记录",
                            caption: "默认目标语言、钉住结果窗口、朗读语速、可选的在线翻译引擎、翻译历史，会在后续版本陆续出现在这里。",
                            isFirst: true) {
                    EmptyView()
                }
            }
        }
    }
}
