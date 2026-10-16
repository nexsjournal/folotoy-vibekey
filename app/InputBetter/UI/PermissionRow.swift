import SwiftUI

/// 权限行:图标 + 说明 + 状态 / 授权按钮。
struct PermissionRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let granted: Bool
    var buttonTitle: LocalizedStringKey = "授权"
    let action: () -> Void

    var body: some View {
        Card {
            HStack(spacing: DS.Space.m) {
                GradientIcon(symbol: symbol, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.s)
                if granted {
                    Label("已授权", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.success)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button(buttonTitle, action: action).buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .animation(.spring(duration: 0.3), value: granted)
    }
}
