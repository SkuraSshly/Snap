import SwiftUI

/// 截图：格式、画面、完成后的行为
struct ScreenshotSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        SettingsPane {
            LabeledContent("文件格式：") {
                OptionStack {
                    Picker("", selection: $prefs.imageFormat) {
                        ForEach(ImageFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Text("只影响保存的文件；复制到剪贴板的始终是无损 PNG。")
                        .settingsCaption()
                }
            }

            if prefs.imageFormat != .png {
                LabeledContent("压缩质量：") {
                    HStack {
                        Slider(value: $prefs.jpegQuality, in: 0.6...1.0, step: 0.05)
                            .frame(width: 180)
                        Text("\(Int((prefs.jpegQuality * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            LabeledContent("画面：") {
                OptionStack {
                    Toggle("包含鼠标指针", isOn: $prefs.screenshotIncludesCursor)
                    Toggle("按 1x 分辨率输出（体积更小）", isOn: $prefs.screenshotSaveAs1x)
                    Text("默认始终以 Retina 原生像素输出，不缩放；文件写入色彩配置文件（Display P3 / sRGB）。1x 对复制和保存都生效，钉图始终是原生清晰度。")
                        .settingsCaption()
                }
            }

            LabeledContent("完成后：") {
                OptionStack {
                    Toggle("复制到剪贴板", isOn: $prefs.screenshotCopyToClipboard)
                    Toggle("自动保存到文件", isOn: $prefs.screenshotSaveToFile)
                    Toggle("在屏幕角落显示缩略图", isOn: $prefs.screenshotShowThumbnail)
                    Toggle("粘贴后自动收起缩略图", isOn: $prefs.hideThumbnailAfterPaste)
                        .disabled(!prefs.screenshotShowThumbnail || !prefs.screenshotCopyToClipboard)
                        .padding(.leading, 18)
                    Text("不自动保存时，可在缩略图上点「保存」，或在截图界面按 ⌘S 完成并保存。\n如果用了剪贴板历史工具（如 Maccy、Paste），它会立即读取剪贴板，缩略图会马上收起，可关闭此项。")
                        .settingsCaption()
                    if !prefs.screenshotCopyToClipboard && !prefs.screenshotSaveToFile && !prefs.screenshotShowThumbnail {
                        Label("复制、保存、缩略图都已关闭，截图完成后不会留下结果。", systemImage: "exclamationmark.triangle.fill")
                            .settingsCaption()
                    }
                }
            }
        }
    }
}
