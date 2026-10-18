import AppKit
import SwiftUI

/// 字幕条的译文区(Apple Music 歌词式):
/// - 平时跟随最新:每句单独成段,底部对齐,新句子把旧句子往上推时平滑滚动;
///   亮度按新旧递减(最新最亮),滚动后一眼找到新内容从哪里开始;还没定下来的暂定译文更暗。
/// - 用户可以自己往回滚(触控板 / 鼠标滚轮)看前面没读完的句子:一滚就停止跟随,
///   右下角出现「回到最新」;点它、滚回最底部,或停止滚动 6 秒后自动回到跟随(和 Apple Music 歌词一样)。
///   往回看时所有已定的句子都用接近全亮的颜色,方便阅读。
/// - 保留最近 40 句(RollingCaptions.maxTranslationLines),更早的在字幕记录窗口里。
/// 字幕条锁定(鼠标穿透)时收不到滚动事件,只能跟随最新。
/// 是否"用户在往回看"只按鼠标在译文区上时的真实滚轮事件判断(见 installScrollMonitor),不从滚动位置推断。
struct TranslationScrollView: View {
    let lines: [TranslationLine]
    let fontSize: CGFloat
    /// 框的最大行数(设置 › 实时字幕 › 译文行数)。
    let maxLines: Int
    /// 原文区不显示时为 true:原文已是目标语言的句子在这里用原文顶上(细体、略暗),否则这句在屏幕上就没了。
    var showSameLanguage = false

    @State private var following = true
    @State private var contentHeight: CGFloat = 0
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var resumeTask: Task<Void, Never>?
    /// 鼠标在译文区上时装的本地滚轮事件监听(移开 / 消失时移除)。
    @State private var scrollMonitor: Any?

    /// 停止滚动多久后自动回到最新。
    private static let resumeDelay: Duration = .seconds(6)

    private var spacing: CGFloat { fontSize * 0.2 }
    private var maxHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        return lineHeight * CGFloat(maxLines) + spacing * CGFloat(max(0, maxLines - 1))
    }

    private var visibleLines: [TranslationLine] { showSameLanguage ? lines : lines.filter { !$0.sameLanguage } }

    var body: some View {
        let lines = visibleLines
        let settledIDs = lines.filter { !$0.provisional }.map(\.id)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(lines) { line in
                    Text(verbatim: line.text)
                        .fontWeight(line.sameLanguage ? .regular : .semibold)
                        .foregroundStyle(.white.opacity(opacity(of: line, settledIDs: settledIDs)))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: fontSize, weight: .semibold))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.never)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        // 内容不满时按实际高度(刚开始不留空白),满了固定为最大行数的高度。
        .frame(height: min(max(contentHeight, 1), maxHeight))
        // 判断"用户在往回看"只看真实的滚轮 / 触控板事件(鼠标在译文区上时):
        // 不能用滚动位置的变化来推断——跟随时程序自己的滚动、暂定译文变短导致的位置回收,
        // 都会让位置往上变,误判后「回到最新」会闪一下(实测)。
        .onHover { hovering in
            if hovering { installScrollMonitor() } else { removeScrollMonitor() }
        }
        // 用户自己滚回最底部:直接恢复跟随。
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 2
        } action: { _, atBottom in
            if atBottom, !following { resume() }
        }
        // 跟随时,只在内容会"移动"时(增删句子、某段大约多出一行)平滑滚到底;暂定译文逐字变化不做动画。
        .onChange(of: visibleLines.map { "\($0.id)#\($0.text.count / 24)" }) {
            guard following else { return }
            withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(edge: .bottom) }
        }
        // 顶部淡出:被裁掉一半的旧句子渐隐,表示上面还有内容。
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.15), .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: fontSize * 0.7)
                Color.black
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !following {
                Button(action: resume) {
                    Label("回到最新", systemImage: "arrow.down")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.18)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .help(String(localized: "回到最新的译文（停止滚动几秒后也会自动回来）", bundle: .l10n))
            }
        }
        .animation(.easeOut(duration: 0.2), value: following)
        .onDisappear {
            resumeTask?.cancel()
            removeScrollMonitor()
        }
    }

    /// 已定的句子:跟随时最新的 1.0,往上依次 0.82、0.68(最低 0.6);往回看时都 0.92;暂定内容 0.55。
    private func opacity(of line: TranslationLine, settledIDs: [String]) -> Double {
        guard !line.provisional, let index = settledIDs.lastIndex(of: line.id) else { return 0.55 }
        guard following else { return 0.92 }
        let age = settledIDs.count - 1 - index
        return max(0.6, 1 - Double(age) * 0.16)
    }

    /// 监听滚轮事件(只观察,原样放行给 ScrollView):往上滚 → 停止跟随;停止跟随期间每次滚动都重新计时 6 秒。
    /// 往下滚不停止跟随(已经在底部时往下滚没有意义,滚回底部由 atBottom 恢复跟随)。
    /// 本地监听器在主线程回调。
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                guard contentHeight > maxHeight + 1 else { return }   // 内容没超出框,滚不动
                if event.scrollingDeltaY > 0 { userScrolled() }
                if !following { scheduleResume() }
            }
            return event
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    private func userScrolled() {
        resumeTask?.cancel()
        following = false
    }

    private func scheduleResume() {
        resumeTask?.cancel()
        resumeTask = Task {
            try? await Task.sleep(for: Self.resumeDelay)
            guard !Task.isCancelled else { return }
            resume()
        }
    }

    private func resume() {
        resumeTask?.cancel()
        following = true
        withAnimation(.easeOut(duration: 0.3)) { position.scrollTo(edge: .bottom) }
    }
}
