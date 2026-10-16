import SwiftUI

/// 模型卡片:图标 + 名称 + 标签 + 说明 + 大小,右侧根据状态显示下载 / 进度 / 启用。
/// 引导页和设置页共用。
struct ModelCard: View {
    let model: ModelInfo
    let state: ModelState
    let isActive: Bool
    let onUse: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    var onDelete: (() -> Void)?
    /// 云端模型:打开配置(API Key 等)。
    var onConfigure: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Card(highlighted: isActive) {
            HStack(spacing: DS.Space.m) {
                GradientIcon(symbol: model.symbol, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.name).font(.system(size: 13.5, weight: .semibold))
                        if isActive, state == .installed {
                            Tag(text: "使用中", color: DS.success)
                        } else if let badge = model.badge {
                            Tag(verbatim: badge)
                        }
                    }
                    Text(model.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(verbatim: model.cloudProvider == nil ? "\(model.size) · \(model.engineName) · Apple Silicon" : model.size)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: DS.Space.s)
                trailing
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if state == .installed { onUse() } }
        .onHover { hovering = $0 }
        .contextMenu {
            if let onConfigure {
                Button("编辑配置", action: onConfigure)
            } else if let onDelete, state == .installed, model.engine != .appleSpeech {
                Button("删除模型", role: .destructive, action: onDelete)
            }
        }
        .animation(.easeOut(duration: 0.2), value: state)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .installed:
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(DS.success)
                    .transition(.scale.combined(with: .opacity))
            } else {
                HStack(spacing: 6) {
                    if let onConfigure {
                        Button(action: onConfigure) { Image(systemName: "gearshape") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("编辑配置")
                    }
                    Button("使用", action: onUse).buttonStyle(SecondaryButtonStyle())
                }
            }
        case .downloading(let progress):
            HStack(spacing: DS.Space.s) {
                ProgressRing(progress: progress)
                Button(action: onCancel) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("取消下载")
            }
        case .notInstalled:
            if let onConfigure {
                Button("配置", action: onConfigure).buttonStyle(SecondaryButtonStyle())
            } else {
                Button(model.engine == .appleSpeech ? LocalizedStringKey("安装") : LocalizedStringKey("下载"), action: onDownload)
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Button("重试", action: onDownload).buttonStyle(SecondaryButtonStyle())
                Text(message).font(.system(size: 10)).foregroundStyle(DS.danger).lineLimit(1).frame(maxWidth: 140, alignment: .trailing)
            }
        case .unsupported(let message):
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// 下载进度环,中间显示百分比。
struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(DS.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)
            Text(verbatim: "\(Int(progress * 100))")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 30, height: 30)
    }
}

/// 模型列表(按推荐顺序)。
struct ModelList: View {
    let models: ModelManager
    let cloud: CloudASRStore
    @Binding var selection: String
    var allowsDelete = false
    /// 要列出的模型(默认全部:本地模型在前,云端在后)。
    var items: [ModelInfo] = ModelCatalog.all
    /// 正在编辑配置的云端服务(弹出配置表单)。
    @State private var editing: CloudProvider?

    var body: some View {
        VStack(spacing: DS.Space.s) {
            ForEach(items) { model in
                ModelCard(
                    model: model,
                    state: models.state(model.id),
                    isActive: selection == model.id,
                    onUse: { selection = model.id },
                    onDownload: {
                        models.download(model.id)
                        // 还没有可用模型时,开始下载的这个自动成为当前模型。
                        if !models.isInstalled(selection) { selection = model.id }
                    },
                    onCancel: { models.cancel(model.id) },
                    onDelete: allowsDelete ? { models.delete(model.id) } : nil,
                    onConfigure: model.cloudProvider.map { provider in { editing = provider } })
            }
        }
        .sheet(item: $editing) { provider in
            CloudConfigSheet(provider: provider, store: cloud) {
                // 第一次配置好且当前模型不可用时,自动选用它。
                if !models.isInstalled(selection) { selection = provider.modelID }
            }
        }
    }
}
