import SwiftUI

/// Draws what ``markdownBlocks`` parsed. Platform-neutral, because the Mac's chat window shows
/// the same replies the phone does.

public struct MarkdownText: View {
    private let blocks: [MarkdownBlock]
    /// Drawn after the last block while the reply is still arriving.
    private let cursor: Bool
    @Environment(\.searchHighlight) private var highlight

    public init(_ markdown: String, cursor: Bool = false) {
        self.blocks = markdownBlocks(markdown)
        self.cursor = cursor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { offset, _ in
                view(at: offset)
            }
        }
        // The phone's timeline hosts each row in a collection cell, which can propose less
        // height than the prose needs; without this a list item or paragraph is cut off at a
        // couple of lines with an ellipsis instead of wrapping to its full length.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func view(at offset: Int) -> some View {
        let last = offset == blocks.count - 1
        switch blocks[offset] {
        case .paragraph(let text):
            // The cursor sits inside the paragraph's own text so it follows the last word to
            // wherever the line wrapped, rather than sitting under it on a line of its own.
            (Text(AttributedString.chatInline(text, highlight: highlight)) + (cursor && last ? Text(" ") : Text("")))
                .overlayCursor(cursor && last)
        case .heading(let level, let text):
            Text(AttributedString.chatInline(text, highlight: highlight))
                .font(headingFont(level))
                .padding(.top, offset == 0 ? 0 : 4)
        case .code(let language, let text):
            CodeBlock(language: language, code: text)
        case .list(let ordered, let items):
            MarkdownList(ordered: ordered, items: items)
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        case .rule:
            Divider()
        }
    }

    /// Relative sizes, so every heading tracks Dynamic Type instead of pinning a point size.
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.bold)
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }
}

extension View {
    /// A blinking caret at the end of a streaming reply. Trailing-aligned over the trailing
    /// space the caller appended, which is the gap it is meant to sit in.
    @ViewBuilder func overlayCursor(_ show: Bool) -> some View {
        if show { modifier(TypingCursor()) } else { self }
    }
}

/// The caret itself. Reduce Motion gets a steady one rather than no cursor at all: the point is
/// to say the reply is unfinished, and that still needs saying.
private struct TypingCursor: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = true

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            Capsule()
                .frame(width: 2)
                .frame(height: 14)
                .opacity(on ? 1 : 0)
                .foregroundStyle(.tint)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 0.6).repeatForever()) { on = false }
                }
                .accessibilityHidden(true)
        }
    }
}

/// A fenced block: monospaced, scrolled sideways rather than wrapped, and copyable in one tap.
private struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language {
                    Text(language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    copyToPasteboard(code)
                    withAnimation { copied = true }
                } label: {
                    Label(copied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .labelStyle(.iconOnly)
                        .frame(minWidth: controlTarget, minHeight: controlTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityLabel(copied ? String(localized: "Copied") : String(localized: "Copy code"))
                // Says "Copied" for a moment, then goes back to offering the copy again.
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { copied = false }
                }
            }
            .padding(.horizontal, 10)

            // Wrapping code changes what it means, so it scrolls instead.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct MarkdownList: View {
    let ordered: Bool
    let items: [String]
    @Environment(\.searchHighlight) private var highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ordered ? "\(offset + 1)." : "•")
                        .foregroundStyle(.secondary)
                        // Numbers line up their own column; a wide list stays a list.
                        .monospacedDigit()
                    Text(AttributedString.chatInline(item, highlight: highlight))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A pipe table as a grid. A table wider than the bubble scrolls sideways, as a code block
/// does, rather than degrading into something that is no longer a table.
private struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    @Environment(\.searchHighlight) private var highlight

    private var columns: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            grid.padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(cells(header).enumerated()), id: \.offset) { _, cell in
                    Text(AttributedString.chatInline(cell, highlight: highlight))
                        .font(.footnote.weight(.semibold))
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(cells(row).enumerated()), id: \.offset) { _, cell in
                        Text(AttributedString.chatInline(cell, highlight: highlight))
                            .font(.footnote)
                    }
                }
            }
        }
        .lineLimit(1)
    }

    /// Ragged rows padded to the widest, so every grid row has the same number of cells and
    /// the columns stay aligned.
    private func cells(_ row: [String]) -> [String] {
        row + Array(repeating: "", count: max(0, columns - row.count))
    }
}
