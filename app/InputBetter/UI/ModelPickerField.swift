import SwiftUI

/// 模型选择框(LLM 配置、云端识别配置共用):
/// - 有可选模型时显示下拉菜单,列表来自接口(或服务商的已知模型);
/// - 末尾的"手动输入…"切换成文本框,用于列表里没有的模型;没有任何选项时直接显示文本框;
/// - 右侧显示获取进度 / 重新获取按钮,获取失败的原因显示在下方。
/// 只负责展示和编辑绑定值,获取列表由调用方完成(传入 options / loading / error / onRefresh)。
struct ModelPickerField: View {
    @Binding var selection: String
    let options: [ModelOption]
    var loading = false
    var error: String?
    /// 重新获取列表;nil 表示不支持(不显示按钮)。
    var onRefresh: (() -> Void)?
    var placeholder: String = ""

    /// 用户选择了"手动输入…"。
    @State private var typing = false

    private static let customTag = "\u{0}custom"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if typing || options.isEmpty {
                    TextField("", text: $selection, prompt: Text(verbatim: placeholder))
                    if !options.isEmpty {
                        Button { typing = false } label: { Image(systemName: "list.bullet") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("从列表选择")
                    }
                } else {
                    picker
                    Spacer(minLength: 0)
                }
                if loading {
                    ProgressView().controlSize(.small)
                } else if let onRefresh {
                    Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("重新获取模型列表")
                }
            }
            if let error {
                Text(verbatim: error)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.danger)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var picker: some View {
        Picker("", selection: Binding(
            get: { selection },
            set: { value in
                if value == Self.customTag { typing = true } else { selection = value }
            })) {
            if selection.isEmpty {
                Text("选择模型").tag("")
            } else if !options.contains(where: { $0.id == selection }) {
                // 当前值不在列表里(手动填过或服务端已下线),仍然显示出来,不悄悄改掉。
                Text(verbatim: selection).tag(selection)
            }
            ForEach(options) { option in
                Text(verbatim: option.displayName).tag(option.id)
            }
            Divider()
            Text("手动输入…").tag(Self.customTag)
        }
        .labelsHidden()
        .fixedSize()
    }
}
