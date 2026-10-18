import AppKit
import SwiftUI

/// 字幕记录正文:只读、可选择的 NSTextView(macOS 上显示长日志 / 转录的标准做法)。
/// 之所以不用 SwiftUI 的 LazyVStack + 可选择 Text:后者在行复用时会出现文字上下颠倒的渲染错误,
/// 而且只能逐行选择;NSTextView 可以跨行选择、性能稳定。
///
/// 更新方式:只重排变化的尾部。译文是异步补上的,通常只影响最后几句,
/// 所以从第一处不同的句子开始替换到末尾,前面的内容不动(长记录也不卡)。
struct TranscriptTextView: NSViewRepresentable {
    let transcript: CaptionTranscript
    /// 正在说、未定稿的内容(显示在末尾,颜色较浅)。
    let partial: String
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
            coordinator.offsets = []
            storage.setAttributedString(NSAttributedString())
        }

        // 第一处不同的句子(内容或译文变了,或者是新句子)。
        let common = zip(coordinator.rendered, entries).prefix { $0 == $1 }.count
        if common == coordinator.rendered.count, common == entries.count, coordinator.partial == partial { return }

        let start = common < coordinator.offsets.count ? coordinator.offsets[common] : coordinator.entriesEnd
        let tail = NSMutableAttributedString()
        var offsets = Array(coordinator.offsets.prefix(common))
        for entry in entries[common...] {
            offsets.append(start + tail.length)
            tail.append(Self.render(entry, offset: transcript.offset(of: entry), showTranslation: showTranslations))
        }
        let entriesEnd = start + tail.length
        if !partial.isEmpty { tail.append(Self.renderPartial(partial)) }

        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
        storage.endEditing()

        coordinator.rendered = entries
        coordinator.offsets = offsets
        coordinator.entriesEnd = entriesEnd
        coordinator.partial = partial
        if followLatest { textView.scrollToEndOfDocument(nil) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 记住已经渲染的内容,用于只更新尾部。
    final class Coordinator {
        var transcriptID: UUID?
        var showTranslations = true
        var rendered: [CaptionTranscript.Entry] = []
        /// 每句在文本中的起始位置。
        var offsets: [Int] = []
        /// 所有定稿句子结束的位置(之后是未定稿内容)。
        var entriesEnd = 0
        var partial = ""
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

    /// 一句:`时间 ⇥ 原文`,有译文时下一行 `⇥ 译文`,句与句之间留间距。
    static func render(_ entry: CaptionTranscript.Entry, offset: String, showTranslation: Bool = true) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let spacing = NSMutableParagraphStyle()
        spacing.setParagraphStyle(paragraph)
        spacing.paragraphSpacingBefore = 10
        result.append(NSAttributedString(string: offset, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: spacing,
        ]))
        result.append(NSAttributedString(string: "\t\(entry.text)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: spacing,
        ]))
        if showTranslation, let translation = entry.translation, !translation.isEmpty {
            result.append(NSAttributedString(string: "\t\(translation)\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: translationParagraph,
            ]))
        }
        return result
    }

    static func renderPartial(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(paragraph)
        style.paragraphSpacingBefore = 10
        return NSAttributedString(string: "\t\(text)", attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
    }
}
