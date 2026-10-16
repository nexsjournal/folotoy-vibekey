import SwiftUI

/// 统一的视觉规范:颜色、圆角、间距。所有界面从这里取值,保证风格一致。
enum DS {
    enum Radius {
        static let card: CGFloat = 14
        static let icon: CGFloat = 10
        static let control: CGFloat = 8
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 20
        static let xl: CGFloat = 32
    }

    /// 唯一的强调色:跟随系统强调色(主按钮、选中态、进度)。整体保持中性克制,不用渐变。
    static let accent = Color.accentColor
    /// 语义色只用于表达状态(成功 / 提醒 / 失败)。
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)

    /// 卡片背景:跟随系统浅色 / 深色。
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let cardStroke = Color.primary.opacity(0.08)
}

/// 主按钮:品牌渐变填充。
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(Capsule().fill(DS.accent).opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 次要按钮:浅灰底胶囊。
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08)))
            .contentShape(Capsule())
    }
}

/// 卡片容器。
struct Card<Content: View>: View {
    var highlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(DS.Space.m + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.cardFill))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(highlighted ? AnyShapeStyle(DS.accent) : AnyShapeStyle(DS.cardStroke),
                                  lineWidth: highlighted ? 1.5 : 1))
    }
}

/// 中性的圆角图标(模型卡片、权限行、设置侧边栏共用):浅灰底 + 主色符号。
struct GradientIcon: View {
    let symbol: String
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.8)))
    }
}

/// 小标签,如"推荐"、"已启用"。
struct Tag: View {
    private let text: Text
    private let color: Color

    init(text: LocalizedStringKey, color: Color = .secondary) {
        self.text = Text(text)
        self.color = color
    }

    /// 已经本地化好的文字(如模型目录里的标签)。
    init(verbatim: String, color: Color = .secondary) {
        self.text = Text(verbatim: verbatim)
        self.color = color
    }

    var body: some View {
        text
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// 设置页的说明文字。
struct Hint: View {
    private let text: Text
    init(_ key: LocalizedStringKey) { text = Text(key) }
    /// 已经是最终文字(如路径、错误信息)时用这个,不做本地化查找。
    init(verbatim: String) { text = Text(verbatim: verbatim) }

    var body: some View {
        text
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
