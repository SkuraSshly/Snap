import SwiftUI

/// 录屏：画面、声音、录制、完成后、GIF
struct RecordingSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        SettingsPane {
            SettingsSection(title: "文件", footer: "录屏总是自动保存为 MP4。文件名示例：\(SaveLocation.fileName(prefix: "录屏", fileExtension: "mp4"))") {
                FolderRow(kind: .recording, icon: "folder.fill", tint: .chipHoney, title: "保存到",
                          path: $prefs.recordingDirectoryPath, isFirst: true)
            }

            SettingsSection(title: "画面", footer: codecFooter) {
                SettingsPair(isFirst: true) {
                    SettingsTile(icon: "aspectratio", tint: .chipSky, title: "分辨率") {
                        WarmSegmented(options: [(RecordingResolution.native, "原生"), (.p1080, "1080p")],
                                      selection: $prefs.recordingResolution, segmentWidth: 56)
                    }
                } right: {
                    SettingsTile(icon: "speedometer", tint: .chipHoney, title: "帧率") {
                        WarmSegmented(options: [(RecordingFrameRate.fps60, "60 fps"), (.fps30, "30 fps")],
                                      selection: $prefs.recordingFrameRate, segmentWidth: 56)
                    }
                }
                SettingsPair {
                    SettingsTile(icon: "cpu", tint: .chipLavender, title: "编码") {
                        WarmSegmented(options: [(VideoCodec.hevc, "HEVC"), (.h264, "H.264")], selection: $prefs.videoCodec,
                                      segmentWidth: 56)
                    }
                } right: {
                    SettingsTile(icon: "sparkles", tint: .apricot, title: "画质") {
                        WarmSegmented(options: VideoQuality.allCases.map { ($0, $0.title) }, selection: $prefs.videoQuality,
                                      segmentWidth: 56)
                    }
                }
            }

            SettingsSection(title: "声音", footer: "录制时可在选区旁的选项条里临时更改，会记住上次的选择。") {
                SwitchRow(icon: "speaker.wave.2.fill", tint: .chipSage, title: "录制系统声音", isFirst: true,
                          isOn: $prefs.recordSystemAudio)
                SwitchRow(icon: "mic.fill", tint: .chipRose, title: "录制麦克风", isOn: $prefs.recordMicrophone)
            }

            SettingsSection(title: "录制") {
                SwitchRow(icon: "cursorarrow", tint: .chipCocoa, title: "显示鼠标指针", isFirst: true,
                          isOn: $prefs.recordingShowsCursor)
                SwitchRow(icon: "cursorarrow.click.2", tint: .apricot, title: "高亮鼠标点击",
                          caption: "点击处出现杏色圆圈（右键为珊瑚色），会录进视频。", isOn: $prefs.highlightClicks)
                SwitchRow(icon: "timer", tint: .coral, title: "开始前 3 秒倒计时",
                          caption: "倒计时期间按 Esc 取消，按 Enter 立即开始。", isOn: $prefs.recordingCountdown)
                SwitchRow(icon: "rectangle.inset.bottomright.filled", tint: .chipSky, title: "完成后在屏幕角落显示缩略图",
                          caption: "缩略图上可以预览、拷贝文件、导出 GIF、移到废纸篓。",
                          isOn: $prefs.recordingShowThumbnail)
            }

            SettingsSection(title: "GIF",
                            footer: "刚录完的录屏，在缩略图上点「GIF」；以前的录屏用上面的「选择录屏…」。GIF 最多 256 色，适合界面演示。") {
                SettingsRow(icon: "film.stack", tint: .coral, title: "将录屏转为 GIF",
                            caption: "GIF 保存在视频旁边，进度显示在屏幕角落的缩略图上", isFirst: true) {
                    Button("选择录屏…") { GIFConversion.chooseAndConvert() }
                        .buttonStyle(WarmButtonStyle())
                }
                SettingsRow(icon: "photo.stack", tint: .chipLavender, title: "帧率") {
                    WarmSegmented(options: GIFFrameRate.allCases.map { ($0, $0.title) }, selection: $prefs.gifFrameRate,
                                  segmentWidth: 58)
                }
                SettingsRow(icon: "arrow.left.and.right", tint: .chipHoney, title: "最大宽度") {
                    WarmSegmented(options: GIFMaxWidth.allCases.map { ($0, $0 == .original ? "原宽" : "\($0.rawValue)") },
                                  selection: $prefs.gifMaxWidth, segmentWidth: 54)
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

    private var codecFooter: String {
        prefs.videoCodec == .hevc ? "HEVC：画质高、体积小。" : "H.264：兼容性更好，老设备和网页也能直接播放。"
    }
}
