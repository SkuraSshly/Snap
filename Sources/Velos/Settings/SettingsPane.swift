import AppKit
import SwiftUI

// 设置窗口的「温暖磨砂」风格，与截图工具栏、录制选项条一致（见 WarmStyle）：
// 奶油色（深色模式下可可色）的半透明底、圆角卡片、杏色的开关和选中态、圆润字体。
// 注意：只装了命令行工具时没有 SwiftUI 的宏插件，不能用 @State，界面状态一律放在 ObservableObject 里。

// MARK: - 配色

/// 设置窗口（SwiftUI）的配色。主色 apricot、coral 取自 WarmPalette（UI/WarmStyle.swift）；
/// 文字、细线等按设置窗口的底色单独调过，和 WarmPalette 里的同名颜色数值略有不同，改动时两边一起看
extension Color {
    private static func warm(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let apricot = Color(nsColor: WarmPalette.apricot)
    static let coral = Color(nsColor: WarmPalette.coral)
    /// 文字和图标（暖棕 / 奶白）
    static let warmInk = warm(light: WarmPalette.cocoa,
                              dark: NSColor(srgbRed: 0.98, green: 0.92, blue: 0.86, alpha: 1))
    static let warmSecondary = warm(light: WarmPalette.cocoa.withAlphaComponent(0.58),
                                    dark: NSColor(srgbRed: 0.98, green: 0.92, blue: 0.86, alpha: 0.55))
    /// 卡片底色
    static let warmCard = warm(light: NSColor(srgbRed: 1, green: 0.99, blue: 0.975, alpha: 0.72),
                               dark: NSColor(srgbRed: 0.30, green: 0.24, blue: 0.20, alpha: 0.55))
    static let warmHairline = warm(light: NSColor(srgbRed: 0.45, green: 0.33, blue: 0.22, alpha: 0.13),
                                   dark: NSColor(srgbRed: 1, green: 0.9, blue: 0.8, alpha: 0.12))
    /// 关着的开关、分段控件的轨道
    static let warmTrack = warm(light: NSColor(srgbRed: 0.45, green: 0.33, blue: 0.22, alpha: 0.12),
                                dark: NSColor(srgbRed: 1, green: 0.9, blue: 0.8, alpha: 0.13))
    /// 窗口底色上叠的暖色渐变
    static let warmWashTop = warm(light: NSColor(srgbRed: 1, green: 0.95, blue: 0.89, alpha: 0.78),
                                  dark: NSColor(srgbRed: 0.22, green: 0.17, blue: 0.14, alpha: 0.72))
    static let warmWashBottom = warm(light: NSColor(srgbRed: 0.99, green: 0.91, blue: 0.84, alpha: 0.7),
                                     dark: NSColor(srgbRed: 0.18, green: 0.14, blue: 0.12, alpha: 0.78))

    // 图标小方块的几种暖色
    static let chipHoney = Color(red: 0.95, green: 0.68, blue: 0.25)
    static let chipSage = Color(red: 0.45, green: 0.70, blue: 0.47)
    static let chipSky = Color(red: 0.38, green: 0.62, blue: 0.88)
    static let chipLavender = Color(red: 0.62, green: 0.52, blue: 0.85)
    static let chipCocoa = Color(red: 0.62, green: 0.45, blue: 0.34)
    static let chipRose = Color(red: 0.90, green: 0.47, blue: 0.55)
}

// MARK: - 面板骨架

/// 所有设置面板的统一外观：一列分组卡片，放在设置窗口右侧（可滚动）
struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            content
        }
        .padding(.horizontal, 26)
        .padding(.top, 4)
        .padding(.bottom, 26)
    }
}

/// 一组设置：小标题 + 圆角卡片 + 底部说明
struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.warmSecondary)
                .padding(.leading, 8)
            VStack(spacing: 0) {
                // 行与行之间的分隔线由 SettingsRow 自己画在顶部（第一行不画）
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.warmCard)
                    .shadow(color: Color(red: 0.35, green: 0.2, blue: 0.1).opacity(0.07), radius: 8, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.warmHairline, lineWidth: 0.5)
            )
            if let footer {
                Text(footer)
                    .settingsCaption()
                    .padding(.horizontal, 8)
            }
        }
    }
}

/// 卡片里的一行：彩色图标小方块 + 标题 / 说明 + 右侧控件
struct SettingsRow<Accessory: View>: View {
    let icon: String
    var tint: Color = .apricot
    let title: String
    var caption: String? = nil
    /// 第一行不画顶部分隔线
    var isFirst = false
    /// 缩进一级（从属于上一行的选项）
    var indented = false
    /// 标题右边紧跟的小东西（例如保存位置的路径标签）
    var titleDetail: AnyView? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            if indented {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.warmSecondary)
                    .frame(width: 26)
            } else {
                IconChip(symbol: icon, tint: tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.warmInk)
                        .fixedSize()
                    titleDetail
                }
                if let caption {
                    Text(caption).settingsCaption()
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(minHeight: 46)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle()
                    .fill(Color.warmHairline)
                    .frame(height: 0.5)
                    .padding(.leading, 50)
            }
        }
    }
}

/// 并排的两个短设置项（例如分辨率 | 帧率），省一半高度
struct SettingsPair<Left: View, Right: View>: View {
    var isFirst = false
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity)
            Rectangle()
                .fill(Color.warmHairline)
                .frame(width: 0.5)
                .padding(.vertical, 9)
            right.frame(maxWidth: .infinity)
        }
        .frame(minHeight: 46)
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle().fill(Color.warmHairline).frame(height: 0.5).padding(.leading, 50)
            }
        }
    }
}

/// SettingsPair 里的一格：图标 + 标题 + 控件
struct SettingsTile<Accessory: View>: View {
    let icon: String
    var tint: Color = .apricot
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            IconChip(symbol: icon, tint: tint)
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.warmInk)
                .fixedSize()
            Spacer(minLength: 6)
            accessory
        }
        .padding(.horizontal, 13)
    }
}

/// 图标小方块：暖色渐变的圆角方块 + 白色图标
struct IconChip: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.78), tint], startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: 26, height: 26)
            .shadow(color: tint.opacity(0.35), radius: 2.5, y: 1)
    }
}

extension View {
    /// 设置项下方的小字说明
    func settingsCaption() -> some View {
        font(.system(size: 11, design: .rounded))
            .foregroundStyle(Color.warmSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(1.5)
    }
}

// MARK: - 控件

/// 杏色开关：弹簧动画滑动的圆钮
struct WarmSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        WarmSwitch(isOn: configuration.$isOn)
    }
}

private struct WarmSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(LinearGradient(colors: [Color.apricot.opacity(0.85), .apricot],
                                                           startPoint: .top, endPoint: .bottom))
                           : AnyShapeStyle(Color.warmTrack))
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                .padding(2)
        }
        .frame(width: 36, height: 21)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.68)) { isOn.toggle() }
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "开" : "关")
    }
}

/// 一行里只有开关
struct SwitchRow: View {
    let icon: String
    var tint: Color = .apricot
    let title: String
    var caption: String? = nil
    var isFirst = false
    var indented = false
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(icon: icon, tint: tint, title: title, caption: caption, isFirst: isFirst, indented: indented) {
            Toggle("", isOn: $isOn).toggleStyle(WarmSwitchStyle()).labelsHidden()
        }
    }
}

/// 胶囊分段选择：杏色的选中块在选项之间弹性滑动
struct WarmSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var segmentWidth: CGFloat = 62

    private var index: Int { options.firstIndex { $0.value == selection } ?? 0 }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.warmTrack)
            Capsule()
                .fill(LinearGradient(colors: [Color.apricot.opacity(0.88), .apricot], startPoint: .top, endPoint: .bottom))
                .shadow(color: Color.apricot.opacity(0.4), radius: 3, y: 1)
                .frame(width: segmentWidth - 4)
                .padding(2)
                .offset(x: CGFloat(index) * segmentWidth)
            HStack(spacing: 0) {
                ForEach(options.indices, id: \.self) { i in
                    Text(options[i].title)
                        .font(.system(size: 12, weight: i == index ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(i == index ? Color.white : Color.warmInk)
                        .lineLimit(1)
                        .frame(width: segmentWidth, height: 26)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.74)) { selection = options[i].value }
                        }
                }
            }
        }
        .frame(width: segmentWidth * CGFloat(options.count), height: 26)
    }
}

/// 胶囊按钮；prominent 为杏色实心
struct WarmButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(prominent ? Color.white : Color.warmInk)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(
                Capsule().fill(prominent ? AnyShapeStyle(Color.apricot) : AnyShapeStyle(Color.warmTrack))
            )
            .overlay(Capsule().strokeBorder(Color.warmHairline, lineWidth: prominent ? 0 : 0.5))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// 状态小徽章：小圆点 + 文字（已授权绿色、未授权珊瑚色）
struct StatusBadge: View {
    let ok: Bool
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ok ? Color.chipSage : Color.coral)
                .frame(width: 6, height: 6)
                .shadow(color: (ok ? Color.chipSage : Color.coral).opacity(0.7), radius: 2.5)
            Text(text)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(ok ? Color.chipSage : Color.coral)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill((ok ? Color.chipSage : Color.coral).opacity(0.13)))
    }
}

// MARK: - 窗口背景

/// 窗口背景：系统毛玻璃 + 奶油色渐变 + 角落里两团柔和的杏色、珊瑚色光晕
struct WarmWindowBackground: View {
    var body: some View {
        ZStack {
            VisualEffectBackground()
            LinearGradient(colors: [.warmWashTop, .warmWashBottom], startPoint: .top, endPoint: .bottom)
            GeometryReader { proxy in
                Circle()
                    .fill(Color.apricot.opacity(0.22))
                    .frame(width: 260, height: 260)
                    .blur(radius: 70)
                    .position(x: proxy.size.width - 40, y: 20)
                Circle()
                    .fill(Color.coral.opacity(0.10))
                    .frame(width: 220, height: 220)
                    .blur(radius: 70)
                    .position(x: 30, y: proxy.size.height - 10)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
