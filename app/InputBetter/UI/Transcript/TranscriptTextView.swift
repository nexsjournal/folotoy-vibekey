import AppKit
import SwiftUI

/// 字幕记录正文:只读、可选择的 NSTextView(macOS 上显示长日志 / 转录的标准做法)。
/// 之所以不用 SwiftUI 的 LazyVStack + 可选择 Text:后者在行复用时会出现文字上下颠倒的渲染错误,
/// 而且只能逐行选择;NSTextView 可以跨行选择、性能稳定。
///
/// 显示单位是「段」:同一次定稿的相邻句子合成一段(见 CaptionTranscript.paragraphs),只显示一个时间。
/// 正在说的一段(live)按同样的排版带时间显示在末尾、正文颜色较浅;定稿后从同一位置重排,
/// 时间来自同一个开始时刻,所以这一行只换颜色、不跳位置(Otter / Zoom 等实时转录的通行做法)。
///
/// 更新方式:只重排变化的尾部。译文是异步补上的,通常只影响最后几句,
/// 所以从第一处不同的段开始替换到末尾,前面的内容不动(长记录也不卡)。
struct TranscriptTextView: NSViewRepresentable {
    let transcript: CaptionTranscript
    /// 正在说、未定稿的一段(显示在末尾,带时间,正文颜色较浅)。
    let live: CaptionTranscript.Live?
    /// 新内容到达时是否自动滚到最底部。
    let followLatest: Bool
    /// 是否显示译文(记录窗口的「译文」菜单可以隐藏)。
    var showTranslations = true

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.setAccessibilityLabel(String(localized: "字幕记录", bundle: .l10n))
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let coordinator = context.coordinator
        let entries = transcript.entries
        // 换了一场会话,或切换了显示译文:全部重建。
        if coordinator.transcriptID != transcript.id || coordinator.showTranslations != showTranslations {
            coordinator.transcriptID = transcript.id
            coordinator.showTranslations = showTranslations
            coordinator.rendered = []
            coordinator.paragraphs = []
            coordinator.offsets = []
            coordinator.entriesEnd = 0
            storage.setAttributedString(NSAttributedString())
        }

        // 第一处不同的句子(内容或译文变了,或者是新句子)。
        let common = zip(coordinator.rendered, entries).prefix { $0 == $1 }.count
        if common == coordinator.rendered.count, common == entries.count, coordinator.live == live { return }

        // 第一处要重排的段:分段变了(新句子并进了上一段),或者段里有变化的句子。
        let paragraphs = transcript.paragraphs()
        let first = zip(coordinator.paragraphs, paragraphs)
            .prefix { $0 == $1 && $1.range.upperBound <= common }.count
        let start = first < coordinator.offsets.count ? coordinator.offsets[first] : coordinator.entriesEnd
        let tail = NSMutableAttributedString()
        var offsets = Array(coordinator.offsets.prefix(first))
        for paragraph in paragraphs[first...] {
            offsets.append(start + tail.length)
            tail.append(Self.render(text: transcript.text(of: paragraph),
                                    translation: showTranslations ? transcript.translation(of: paragraph) : nil,
                                    offset: transcript.offset(of: paragraph)))
        }
        let entriesEnd = start + tail.length
        if let live {
            tail.append(Self.render(text: live.text, translation: nil, offset: transcript.offset(of: live), live: true))
        }

        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
        storage.endEditing()

        coordinator.rendered = entries
        coordinator.paragraphs = paragraphs
        coordinator.offsets = offsets
        coordinator.entriesEnd = entriesEnd
        coordinator.live = live
        if followLatest { textView.scrollToEndOfDocument(nil) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 记住已经渲染的内容,用于只更新尾部。
    final class Coordinator {
        var transcriptID: UUID?
        var showTranslations = true
        var rendered: [CaptionTranscript.Entry] = []
        /// 已渲染的分段。
        var paragraphs: [CaptionTranscript.Paragraph] = []
        /// 每段在文本中的起始位置。
        var offsets: [Int] = []
        /// 所有定稿句子结束的位置(之后是未定稿内容)。
        var entriesEnd = 0
        var live: CaptionTranscript.Live?
    }

    // MARK: - 排版

    /// 时间列宽度:正文和译文换行后都对齐到这一列。
    private static let indent: CGFloat = 74

    private static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.defaultTabInterval = indent
        style.headIndent = indent
        style.lineSpacing = 2
        return style
    }

    private static var translationParagraph: NSParagraphStyle {
        let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
        style.paragraphSpacingBefore = 2
        return style
    }

    /// 一段:`时间 ⇥ 原文`,有译文时下一行 `⇥ 译文`,段与段之间留间距。
    /// `live`:正在说、未定稿的一段,正文用较浅的颜色(定稿后同一位置换成正常颜色)。
    static func render(text: String, translation: String?, offset: String, live: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let spacing = NSMutableParagraphStyle()
        spacing.setParagraphStyle(paragraph)
        spacing.paragraphSpacingBefore = 10
        result.append(NSAttributedString(string: offset, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: spacing,
        ]))
        result.append(NSAttributedString(string: "\t\(text)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: live ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: spacing,
        ]))
        if let translation, !translation.isEmpty {
            result.append(NSAttributedString(string: "\t\(translation)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: translationParagraph,
            ]))
        }
        return result
    }
}
