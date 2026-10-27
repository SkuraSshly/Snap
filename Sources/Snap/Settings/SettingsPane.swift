import SwiftUI

/// 所有设置面板的统一外观：经典的「标签：控件」两栏布局，固定宽度，高度随内容。
/// 外层用 fixedSize 报告理想尺寸，窗口据此自动贴合。
struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.columns)
        .padding(.horizontal, 40)
        .padding(.vertical, 24)
        .frame(width: 520)
        .fixedSize()
    }
}

/// 一组竖排的选项（放在同一个左侧标签下）
struct OptionStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(.bottom, 6)   // 与下一组选项拉开一点距离
    }
}

extension View {
    /// 设置项下方的灰色小字说明
    func settingsCaption() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
