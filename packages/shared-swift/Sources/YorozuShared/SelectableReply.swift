#if os(iOS)
    import SwiftUI
    import UIKit

    /// What a bubble's prose looks like when it is a `UITextView` rather than a `Text`: the
    /// typeface design and colours the bubble set with SwiftUI modifiers, which a UIKit view
    /// cannot read back out of the environment.
    struct ProseStyle: Equatable {
        var serif: Bool
        var ink: UIColor
        var tint: UIColor

        /// The same relative sizes ``MarkdownText`` gives headings, so both paths track
        /// Dynamic Type alike. Bold, italic and code become font traits here.
        func font(heading level: Int?, traits: UIFontDescriptor.SymbolicTraits = []) -> UIFont {
            let (style, weight): (UIFont.TextStyle, UIFont.Weight) = switch level {
            case 1: (.title2, .bold)
            case 2: (.title3, .semibold)
            case 3: (.headline, .semibold)
            case .some: (.subheadline, .semibold)
            case nil: (.body, .regular)
            }
            let design: UIFontDescriptor.SystemDesign = traits.contains(.traitMonoSpace) ? .monospaced : serif ? .serif : .default
            var descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style)
            descriptor = descriptor.withDesign(design) ?? descriptor
            descriptor = descriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
            descriptor = descriptor.withSymbolicTraits(traits.subtracting(.traitMonoSpace)) ?? descriptor
            return UIFont(descriptor: descriptor, size: 0)
        }
    }

    extension EnvironmentValues {
        /// Set by a message bubble. Nil everywhere a reply stays SwiftUI `Text`.
        @Entry var proseStyle: ProseStyle?
    }

    /// A whole reply as one read-only, non-scrolling `UITextView`: the one control on iOS whose
    /// long press selects by word and letter, and one view rather than one per block so the
    /// selection runs across paragraphs. SwiftUI's `Text` selects itself whole.
    ///
    /// Prose, headings and lists are text. A code block, table or rule is a placeholder
    /// character the width of the line, with the same SwiftUI view the Mac draws laid over it —
    /// so the Copy button, language label and sideways scroll stay — and copying a selection
    /// that spans one puts the block's source text where the placeholder was.
    struct SelectableReply: UIViewRepresentable {
        let blocks: [MarkdownBlock]
        let highlight: String
        let style: ProseStyle

        func makeUIView(context: Context) -> ReplyTextView {
            let view = ReplyTextView()
            view.isEditable = false
            view.isScrollEnabled = false
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.adjustsFontForContentSizeCategory = true
            return view
        }

        func updateUIView(_ view: ReplyTextView, context: Context) {
            view.tintColor = style.tint
            view.linkTextAttributes = [.foregroundColor: style.tint, .underlineStyle: NSUnderlineStyle.single.rawValue]
            view.show(blocks, highlight: highlight, style: style)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReplyTextView, context: Context) -> CGSize? {
            if let width = proposal.width, width.isFinite { uiView.measureBlocks(width: width) }
            let fitted = uiView.sizeThatFits(CGSize(width: proposal.width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
            // The proposed width, not the text's: a short line still owns its whole row.
            return CGSize(width: proposal.width ?? fitted.width, height: fitted.height)
        }
    }

    final class ReplyTextView: UITextView {
        private var shown: (blocks: [MarkdownBlock], highlight: String, style: ProseStyle)?
        private var overlays: [UIView] = []
        private var measuredWidth: CGFloat?

        /// TextKit 1, built by hand: its layout manager is what answers where a placeholder
        /// landed. (`init(usingTextLayoutManager:)` would do the same, but that convenience
        /// initialiser skips a Swift subclass's stored properties.)
        init() {
            let storage = NSTextStorage()
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: .zero)
            container.widthTracksTextView = true
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            super.init(frame: .zero, textContainer: container)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        /// Rebuilds the text only when something it is made from changed: the cell this sits in
        /// is updated far more often than a finished reply is.
        func show(_ blocks: [MarkdownBlock], highlight: String, style: ProseStyle) {
            if let shown, shown.blocks == blocks, shown.highlight == highlight, shown.style == style { return }
            shown = (blocks, highlight, style)
            measuredWidth = nil
            overlays.forEach { $0.removeFromSuperview() }
            attributedText = replyDocument(blocks, highlight: highlight, style: style)
            overlays = attachments.map { $0.host.view }
            overlays.forEach(addSubview)
            setNeedsLayout()
        }

        private var attachments: [BlockAttachment] {
            var found: [BlockAttachment] = []
            attributedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedText.length)) { value, _, _ in
                if let block = value as? BlockAttachment { found.append(block) }
            }
            return found
        }

        /// Asks each hosted block how tall it is at this width, before the text is laid out
        /// around it. TextKit asks the attachment for its bounds off the main actor, where a
        /// hosting controller cannot be measured, so the answer is worked out here first.
        func measureBlocks(width: CGFloat) {
            guard width != measuredWidth else { return }
            measuredWidth = width
            for block in attachments {
                block.height = block.host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
            }
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: attributedText.length), actualCharacterRange: nil)
        }

        override func layoutSubviews() {
            measureBlocks(width: bounds.width)
            super.layoutSubviews()
            attributedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributedText.length)) { value, range, _ in
                guard let block = value as? BlockAttachment else { return }
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var frame = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                frame.origin.x += textContainerInset.left
                frame.origin.y += textContainerInset.top
                block.host.view.frame = frame
            }
        }

        /// The selection as text, with each placeholder replaced by the block it stood for.
        override func copy(_ sender: Any?) {
            let selection = attributedText.attributedSubstring(from: selectedRange)
            let text = NSMutableString(string: selection.string)
            selection.enumerateAttribute(.attachment, in: NSRange(location: 0, length: selection.length), options: .reverse) { value, range, _ in
                if let block = value as? BlockAttachment { text.replaceCharacters(in: range, with: block.source) }
            }
            UIPasteboard.general.string = text as String
        }
    }

    /// A block drawn by SwiftUI, standing in the text as one character the width of the line.
    private final class BlockAttachment: NSTextAttachment {
        /// What the block copies as.
        let source: String
        let host: UIHostingController<AnyView>
        /// Set by ``ReplyTextView/measureBlocks(width:)`` before layout reads it.
        nonisolated(unsafe) var height: CGFloat = 0

        @MainActor init(source: String, view: some View) {
            self.source = source
            host = UIHostingController(rootView: AnyView(view))
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            super.init(data: nil, ofType: nil)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        /// Nothing: the hosted view is drawn over this spot. Left to itself TextKit draws a
        /// "missing attachment" page icon there.
        nonisolated override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
            UIImage()
        }

        nonisolated override func attachmentBounds(
            for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
            glyphPosition position: CGPoint, characterIndex charIndex: Int
        ) -> CGRect {
            CGRect(x: 0, y: 0, width: lineFrag.width, height: height)
        }
    }

    /// The gap between blocks and between a list's items, as the SwiftUI stacks space them.
    private let blockGap: CGFloat = 8
    private let itemGap: CGFloat = 4
    private let listIndent: CGFloat = 18

    /// The reply as one attributed string, block by block.
    @MainActor private func replyDocument(_ blocks: [MarkdownBlock], highlight: String, style: ProseStyle) -> NSAttributedString {
        let document = NSMutableAttributedString()
        let hosted = { (view: any View) -> any View in
            view.environment(\.searchHighlight, highlight).tint(Color(uiColor: style.tint))
        }
        for (offset, block) in blocks.enumerated() {
            let last = offset == blocks.count - 1
            let gap = last ? 0 : blockGap
            let paragraph = NSMutableParagraphStyle()
            switch block {
            case .paragraph(let text):
                document.append(finished(prose(.chatInline(text, highlight: highlight), style: style), paragraph, gap: gap, last: last))
            case .heading(let level, let text):
                paragraph.paragraphSpacingBefore = offset == 0 ? 0 : 4
                document.append(finished(prose(.chatInline(text, highlight: highlight), level: level, style: style), paragraph, gap: gap, last: last))
            case .list(let ordered, let items):
                for (index, item) in items.enumerated() {
                    let itemParagraph = NSMutableParagraphStyle()
                    itemParagraph.headIndent = listIndent
                    itemParagraph.tabStops = [NSTextTab(textAlignment: .left, location: listIndent)]
                    let marker = NSMutableAttributedString(
                        string: (ordered ? "\(index + 1)." : "•") + "\t",
                        attributes: [.font: style.font(heading: nil), .foregroundColor: UIColor.secondaryLabel]
                    )
                    let lastItem = index == items.count - 1
                    marker.append(prose(.chatInline(item, highlight: highlight), style: style))
                    document.append(finished(marker, itemParagraph, gap: lastItem ? gap : itemGap, last: last && lastItem))
                }
            case .code(let language, let text):
                document.append(placeholder(BlockAttachment(source: text, view: hosted(CodeBlock(language: language, code: text))), paragraph, gap: gap, last: last))
            case .table(let header, let rows):
                let source = ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
                document.append(placeholder(BlockAttachment(source: source, view: hosted(MarkdownTable(header: header, rows: rows).fontDesign(style.serif ? .serif : .default))), paragraph, gap: gap, last: last))
            case .rule:
                document.append(placeholder(BlockAttachment(source: "———", view: hosted(Divider())), paragraph, gap: gap, last: last))
            }
        }
        return document
    }

    @MainActor private func placeholder(_ attachment: BlockAttachment, _ paragraph: NSMutableParagraphStyle, gap: CGFloat, last: Bool) -> NSAttributedString {
        let piece = NSMutableAttributedString(attachment: attachment)
        return finished(piece, paragraph, gap: gap, last: last)
    }

    /// Foundation's inline intents are what SwiftUI draws bold, italic and code from, and UIKit
    /// draws none of them; nor do SwiftUI-scoped colours (the search highlight, the code
    /// background) survive `NSAttributedString.init`. Both are re-applied here.
    private func prose(_ text: AttributedString, level: Int? = nil, style: ProseStyle) -> NSMutableAttributedString {
        let piece = NSMutableAttributedString(text)
        piece.addAttributes(
            [.font: style.font(heading: level), .foregroundColor: style.ink],
            range: NSRange(location: 0, length: piece.length)
        )
        for run in text.runs {
            let range = NSRange(run.range, in: text)
            let intent = run.inlinePresentationIntent ?? []
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if intent.contains(.code) { traits.insert(.traitMonoSpace) }
            if !traits.isEmpty {
                piece.addAttribute(.font, value: style.font(heading: level, traits: traits), range: range)
            }
            if intent.contains(.strikethrough) {
                piece.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if let background = run.swiftUI.backgroundColor {
                piece.addAttribute(.backgroundColor, value: UIColor(background), range: range)
            }
        }
        return piece
    }

    /// Ends the block: a newline unless it is the last, the paragraph style throughout, and the
    /// gap after it on its final line only — a newline the author wrote inside a paragraph is a
    /// line break, not a block break, and gets no gap.
    private func finished(_ piece: NSMutableAttributedString, _ paragraph: NSMutableParagraphStyle, gap: CGFloat, last: Bool) -> NSAttributedString {
        if !last { piece.append(NSAttributedString(string: "\n")) }
        let body = NSRange(location: 0, length: max(0, piece.length - (last ? 0 : 1)))
        piece.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: piece.length))
        let lastBreak = (piece.string as NSString).range(of: "\n", options: .backwards, range: body)
        let start = lastBreak.location == NSNotFound ? 0 : lastBreak.location + 1
        let spaced = paragraph.mutableCopy() as! NSMutableParagraphStyle
        spaced.paragraphSpacing = gap
        piece.addAttribute(.paragraphStyle, value: spaced, range: NSRange(location: start, length: piece.length - start))
        return piece
    }
#endif
