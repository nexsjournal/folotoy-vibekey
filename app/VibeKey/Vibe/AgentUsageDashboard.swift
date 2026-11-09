import SwiftUI

/// 智能体页顶部的 Codex 用量看板。所有数字都来自 Codex 账户；没有数据时
/// 明确显示不可用，不用 0 或示例值冒充额度。
struct AgentUsageDashboard: View {
    @State private var model = AgentUsageModel()

    private let green = Color(red: 0.42, green: 0.98, blue: 0.62)
    private let dim = Color.white.opacity(0.52)
    private let panel = Color(red: 0.035, green: 0.062, blue: 0.047)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tabs
            total
            quota
            footer
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(panel)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(green.opacity(0.16), lineWidth: 1)
                }
        }
        .task {
            await model.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await model.refresh()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.snapshot == nil ? Color.orange : green)
                .frame(width: 7, height: 7)
                .shadow(color: (model.snapshot == nil ? Color.orange : green).opacity(0.6), radius: 4)
            Text(model.statusTitle)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
            if let remaining = model.snapshot?.weeklyRemainingPercent {
                Text(String(localized: "剩余 \(remaining)%", bundle: .l10n))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(dim)
            } else if model.isLoading {
                ProgressView().controlSize(.small).tint(green)
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(CodexUsageSnapshot.Period.allCases) { period in
                let selected = model.period == period
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { model.period = period }
                } label: {
                    Text(period.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(selected ? green : dim)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected ? green.opacity(0.12) : Color.white.opacity(0.035))
                                .overlay(alignment: .bottom) {
                                    if selected {
                                        Rectangle().fill(green).frame(height: 1.5)
                                    }
                                }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let snapshot = model.snapshot, snapshot.todayIsLocalEstimate, model.period != .all {
                Text("本机会话估算")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(dim.opacity(0.7))
            }
        }
    }

    private var total: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.period.caption)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(dim)
            Text(model.amountText)
                .font(.system(size: 34, weight: .medium, design: .monospaced))
                .foregroundStyle(model.snapshot == nil ? dim : Color.white.opacity(0.96))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(model.amountDetail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(dim.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var quota: some View {
        if let snapshot = model.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("每周额度")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(dim)
                    Spacer()
                    if let remaining = snapshot.weeklyRemainingPercent {
                        Text(String(localized: "剩余 \(remaining)%", bundle: .l10n))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(green)
                    } else {
                        Text("暂无数据")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(dim)
                    }
                }
                quotaBar(remaining: snapshot.weeklyRemainingPercent ?? 0,
                         available: snapshot.weeklyRemainingPercent != nil)
                if let reset = snapshot.weeklyResetsAt {
                    Text(CodexUsageFormat.resetCountdown(reset))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(dim)
                }
                Divider().overlay(green.opacity(0.12))
                HStack {
                    Text("套餐")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(dim)
                    Spacer()
                    Text(snapshot.planName ?? "—")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
                if let credits = snapshot.resetCredits, credits > 0 {
                    HStack {
                        Text("重置券")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(dim)
                        Spacer()
                        Text(verbatim: "\(credits)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(green)
                    }
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            }
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(green)
                    Text("正在读取 Codex 用量…")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(dim)
                }
            } else {
                Text(model.error ?? String(localized: "暂无数据", bundle: .l10n))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(dim)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重新读取") { Task { await model.refresh() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.035))
        }
    }

    private func quotaBar(remaining: Int, available: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                if available {
                    Capsule()
                        .fill(LinearGradient(colors: [green.opacity(0.65), green],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, geo.size.width * CGFloat(remaining) / 100))
                }
            }
        }
        .frame(height: 5)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let snapshot = model.snapshot {
                Text(CodexUsageFormat.updatedAt(snapshot.updatedAt))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(dim.opacity(0.65))
            }
            Text("每 60 秒刷新")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(dim.opacity(0.45))
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("刷新")
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(model.isLoading ? dim.opacity(0.4) : green)
            }
            .buttonStyle(.plain)
            .disabled(model.isLoading)
        }
    }
}

@MainActor @Observable
final class AgentUsageModel {
    var snapshot: CodexUsageSnapshot?
    var error: String?
    var isLoading = false
    var period: CodexUsageSnapshot.Period = .today

    var statusTitle: String {
        if isLoading && snapshot == nil { return String(localized: "Codex / 读取中", bundle: .l10n) }
        if snapshot == nil { return String(localized: "Codex / 未连接", bundle: .l10n) }
        return String(localized: "Codex / 待命中", bundle: .l10n)
    }

    var amountText: String {
        guard let value = snapshot?.tokens(for: period) else { return "—" }
        return CodexUsageFormat.tokens(value)
    }

    var amountDetail: String {
        guard let value = snapshot?.tokens(for: period) else {
            return String(localized: "暂无数据", bundle: .l10n)
        }
        return String(localized: "\(CodexUsageFormat.compactTokens(value)) tokens", bundle: .l10n)
    }

    func refresh() async {
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await CodexUsageService.load()
            error = nil
        } catch {
            if snapshot == nil {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// 只给当前看板用的短标签；放在这里避免把用量文案散到 SettingsView。
extension CodexUsageSnapshot.Period {
    var title: String {
        switch self {
        case .today: String(localized: "今日", bundle: .l10n)
        case .week: String(localized: "本周", bundle: .l10n)
        case .all: String(localized: "累计", bundle: .l10n)
        }
    }

    var caption: String {
        switch self {
        case .today: "TODAY TOKENS"
        case .week: "WEEK TOKENS"
        case .all: "TOTAL TOKENS"
        }
    }
}
