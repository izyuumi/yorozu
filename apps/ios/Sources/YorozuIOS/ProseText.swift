#if os(macOS)
import AppKit
import SwiftUI

// Consecutive prose blocks of one message drawn as one read-only NSTextView, so a selection can run across
// paragraphs, headings, lists and quotes. SwiftUI `Text` selects one view at a time and has no hanging indent.
struct ProseText: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    @Environment(\.textZoom) private var zoom

    static func isProse(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .paragraph, .heading: true
        case .list(let items): items.allSatisfy { $0.blocks.allSatisfy(isProse) }
        case .quote(let blocks): blocks.allSatisfy(isProse)
        case .code, .table, .rule, .image: false
        }
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let text = Self.render(blocks, zoom: zoom)
        if view.textStorage?.isEqual(to: text) != true { view.textStorage?.setAttributedString(text) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    // MARK: Attributed text

    private static let blockSpacing: CGFloat = 8
    private static let itemSpacing: CGFloat = 4
    private static let indent: CGFloat = 18

    private static func render(_ blocks: [MarkdownBlock], zoom: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        append(blocks, to: out, level: 0, quoted: false, zoom: zoom)
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    private static func append(_ blocks: [MarkdownBlock], to out: NSMutableAttributedString, level: Int, quoted: Bool, zoom: CGFloat,
                               marker: String? = nil) {
        var marker = marker
        for (i, block) in blocks.enumerated() {
            let spacing = i == blocks.count - 1 && level > 0 ? itemSpacing : blockSpacing
            switch block {
            case .paragraph(let text):
                out.append(line(text, style: .body, level: level, quoted: quoted, zoom: zoom, marker: marker, spacing: spacing))
            case .heading(let depth, let text):
                let style: NSFont.TextStyle = depth == 1 ? .title2 : depth == 2 ? .title3 : .headline
                out.append(line(text, style: style, bold: true, level: level, quoted: quoted, zoom: zoom, marker: marker, spacing: spacing))
            case .list(let items):
                for item in items { append(item.blocks, to: out, level: level + 1, quoted: quoted, zoom: zoom, marker: item.marker) }
                trimSpacing(out, to: spacing)
            case .quote(let inner):
                append(inner, to: out, level: level + 1, quoted: true, zoom: zoom)
            case .code, .table, .rule, .image:
                continue
            }
            marker = nil
        }
    }

    private static func line(_ text: AttributedString, style: NSFont.TextStyle, bold: Bool = false, level: Int, quoted: Bool,
                             zoom: CGFloat, marker: String?, spacing: CGFloat) -> NSAttributedString {
        let base = NSFont.preferred(style, zoom: zoom)
        let color: NSColor = quoted ? .secondaryLabelColor : .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = CGFloat(level) * indent
        paragraph.firstLineHeadIndent = marker == nil ? paragraph.headIndent : paragraph.headIndent - indent
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
        paragraph.paragraphSpacing = spacing
        let out = NSMutableAttributedString()
        if let marker {
            out.append(NSAttributedString(string: marker + "\t", attributes: [.font: base, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var traits: NSFontDescriptor.SymbolicTraits = bold ? .bold : []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular) : base
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        out.append(NSAttributedString(string: "\n", attributes: [.font: base]))
        out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        return out
    }

    // The last line of a list takes the spacing of the block that holds it.
    private static func trimSpacing(_ out: NSMutableAttributedString, to spacing: CGFloat) {
        guard out.length > 0, let style = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) as? NSParagraphStyle,
              let copy = style.mutableCopy() as? NSMutableParagraphStyle else { return }
        copy.paragraphSpacing = spacing
        let start = (out.string as NSString).paragraphRange(for: NSRange(location: out.length - 1, length: 0))
        out.addAttribute(.paragraphStyle, value: copy, range: start)
    }
}
#endif
