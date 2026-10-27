import SwiftUI

/// 录屏：画面、编码、声音、其他
struct RecordingSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        SettingsPane {
            Picker("分辨率：", selection: $prefs.recordingResolution) {
                ForEach(RecordingResolution.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()

            Picker("帧率：", selection: $prefs.recordingFrameRate) {
                ForEach(RecordingFrameRate.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()

            Picker("编码：", selection: $prefs.videoCodec) {
                ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()

            Picker("画质：", selection: $prefs.videoQuality) {
                ForEach(VideoQuality.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            LabeledContent("声音：") {
                OptionStack {
                    Toggle("录制系统声音", isOn: $prefs.recordSystemAudio)
                    Toggle("录制麦克风", isOn: $prefs.recordMicrophone)
                    Text("录制时可在选区旁的选项条里临时更改，会记住上次的选择。")
                        .settingsCaption()
                }
            }

            LabeledContent("录制：") {
                OptionStack {
                    Toggle("显示鼠标指针", isOn: $prefs.recordingShowsCursor)
                    Toggle("高亮鼠标点击", isOn: $prefs.highlightClicks)
                    Text("点击处出现杏色圆圈（右键为珊瑚色），会录进视频。").settingsCaption()
                    Toggle("开始前 3 秒倒计时", isOn: $prefs.recordingCountdown)
                    Text("倒计时期间按 Esc 取消，按 Enter 立即开始。").settingsCaption()
                }
            }

            LabeledContent("完成后：") {
                OptionStack {
                    Toggle("在屏幕角落显示缩略图", isOn: $prefs.recordingShowThumbnail)
                    Text("录屏总是自动保存到录屏文件夹。缩略图上可以预览、拷贝文件、导出 GIF、移到废纸篓。").settingsCaption()
                }
            }

            LabeledContent("GIF：") {
                OptionStack {
                    HStack(spacing: 8) {
                        Picker("", selection: $prefs.gifFrameRate) {
                            ForEach(GIFFrameRate.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Picker("", selection: $prefs.gifMaxWidth) {
                            ForEach(GIFMaxWidth.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text("在录屏缩略图上点「GIF」，或菜单栏「将录屏转为 GIF…」。GIF 最多 256 色，适合界面演示；大面积渐变和照片会有色带。").settingsCaption()
                }
            }
        }
        .onChange(of: prefs.recordMicrophone) { _, enabled in
            // 打开麦克风时顺便请求权限（未决定时弹系统对话框；被拒绝过则跳到系统设置）
            if enabled && !PermissionManager.shared.microphoneGranted {
                PermissionManager.shared.requestMicrophone()
            }
        }
    }
}
