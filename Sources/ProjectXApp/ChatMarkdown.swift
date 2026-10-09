import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One block of a chat message's Markdown. Inline styling (bold, italic, code, links) stays in the `AttributedString`.
enum MarkdownBlock {
    struct ListItem { let marker: String; let blocks: [MarkdownBlock] }
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case list([ListItem])
    case quote([MarkdownBlock])
    case code(language: String?, String)
    /// Rows hold one cell per column; missing cells are empty.
    case table(header: [AttributedString], rows: [[AttributedString]])
    case rule
    /// A local image file. Remote images stay links in their paragraph (#311 open question 9).
    case image(URL, alt: String)
}

/// Parses chat Markdown into blocks with Foundation's parser, whose presentation intents carry the block structure.
enum ChatMarkdown {
    private typealias Run = (text: AttributedString, path: ArraySlice<PresentationIntent.IntentType>)
    private final class Box { let blocks: [MarkdownBlock]; init(_ blocks: [MarkdownBlock]) { self.blocks = blocks } }
    /// Keyed by the source text, so a view rebuilt for the same message never parses twice. NSCache is thread-safe.
    nonisolated(unsafe) private static let cache = NSCache<NSString, Box>()

    static func blocks(_ text: String) -> [MarkdownBlock] {
        if let hit = cache.object(forKey: text as NSString) { return hit.blocks }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return [.paragraph(AttributedString(text))] }
        // Intents come innermost first; the path runs outermost first so each level peels one off.
        let runs = parsed.runs.map { run -> Run in
            (AttributedString(parsed[run.range]), ArraySlice((run.presentationIntent?.components ?? []).reversed()))
        }
        let value = build(runs[...])
        cache.setObject(Box(value), forKey: text as NSString)
        return value
    }

    /// Consecutive runs whose outermost remaining intent is the same block.
    private static func groups(_ runs: ArraySlice<Run>) -> [(intent: PresentationIntent.IntentType?, runs: ArraySlice<Run>)] {
        var out: [(PresentationIntent.IntentType?, ArraySlice<Run>)] = []
        var start = runs.startIndex
        for i in runs.indices where runs[i].path.first?.identity != runs[start].path.first?.identity {
            out.append((runs[start].path.first, runs[start..<i])); start = i
        }
        if start < runs.endIndex { out.append((runs[start].path.first, runs[start...])) }
        return out
    }

    private static func inner(_ runs: ArraySlice<Run>) -> ArraySlice<Run> { ArraySlice(runs.map { ($0.text, $0.path.dropFirst()) }) }
    private static func joined(_ runs: ArraySlice<Run>) -> AttributedString { runs.reduce(into: AttributedString()) { $0 += $1.text } }

    private static func build(_ runs: ArraySlice<Run>) -> [MarkdownBlock] {
        groups(runs).flatMap { intent, group -> [MarkdownBlock] in
            switch intent?.kind {
            case .header(let level): return [.heading(level: level, joined(group))]
            case .codeBlock(let language):
                var code = String(joined(group).characters)
                if code.hasSuffix("\n") { code.removeLast() }
                return [.code(language: language, code)]
            case .thematicBreak: return [.rule]
            case .blockQuote: return [.quote(build(inner(group)))]
            case .orderedList, .unorderedList:
                let ordered = if case .orderedList = intent?.kind { true } else { false }
                return [.list(groups(inner(group)).map { item, runs in
                    let marker = if ordered, case .listItem(let ordinal) = item?.kind { "\(ordinal)." } else { "•" }
                    return .init(marker: marker, blocks: build(inner(runs)))
                })]
            case .table(let columns): return [table(inner(group), columns: columns.count)]
            default: return paragraph(group) // a paragraph, or text outside any block
            }
        }
    }

    private static func table(_ runs: ArraySlice<Run>, columns: Int) -> MarkdownBlock {
        let rows = groups(runs).map { _, row in
            var cells = Array(repeating: AttributedString(), count: columns)
            for (cell, runs) in groups(inner(row)) {
                if case .tableCell(let column) = cell?.kind, cells.indices.contains(column) { cells[column] = joined(runs) }
            }
            return cells
        }
        return .table(header: rows.first ?? [], rows: Array(rows.dropFirst()))
    }

    /// Local images split the paragraph into image blocks; remote ones stay in the text as links.
    private static func paragraph(_ runs: ArraySlice<Run>) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = [], text = AttributedString()
        func flush() {
            if !String(text.characters).allSatisfy(\.isWhitespace) { blocks.append(.paragraph(text)) }
            text = AttributedString()
        }
        for run in runs {
            guard let url = run.text.imageURL else { text += run.text; continue }
            let alt = String(run.text.characters)
            if let file = localFile(url) { flush(); blocks.append(.image(file, alt: alt)); continue }
            var link = AttributedString(alt.isEmpty ? url.absoluteString : alt)
            link.link = url
            text += link
        }
        flush()
        return blocks
    }

    /// `file:` URLs and bare absolute or `~` paths; anything with another scheme is remote.
    private static func localFile(_ url: URL) -> URL? {
        if url.isFileURL { return url }
        guard url.scheme == nil, url.path.hasPrefix("/") || url.path.hasPrefix("~") else { return nil }
        return URL(fileURLWithPath: (url.path as NSString).expandingTildeInPath)
    }
}

/// A chat message's Markdown as blocks, one lazy row each, so very long answers lay out only what is on screen.
/// Selection is per block (one `Text` each); copying the whole answer is the caller's job.
struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    init(_ text: String) { blocks = ChatMarkdown.blocks(text) }
    init(blocks: [MarkdownBlock]) { self.blocks = blocks }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: MarkdownMetrics.blockSpacing) {
            ForEach(blocks.indices, id: \.self) { MarkdownBlockView(block: blocks[$0]) }
        }
        .textSelection(.enabled)
    }
}

/// Spacing inside the renderer, which owns its geometry; its width always comes from the container.
private enum MarkdownMetrics {
    static let blockSpacing: CGFloat = 8
    static let itemSpacing: CGFloat = 4
    static let inset: CGFloat = 10
    static let tight: CGFloat = 4
    static let quoteBar: CGFloat = 3
    static let radius: CGFloat = 9
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(text)
        case .heading(let level, let text):
            Text(text).font(level == 1 ? .title2 : level == 2 ? .title3 : .headline).bold()
        case .list(let items):
            VStack(alignment: .leading, spacing: MarkdownMetrics.itemSpacing) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: MarkdownMetrics.tight) {
                        Text(verbatim: items[i].marker).monospacedDigit().foregroundStyle(.secondary)
                        Stack(blocks: items[i].blocks)
                    }
                }
            }
        case .quote(let blocks):
            Stack(blocks: blocks)
                .foregroundStyle(.secondary)
                .padding(.leading, MarkdownMetrics.inset)
                .overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: MarkdownMetrics.quoteBar) }
        case .code(let language, let code):
            CodeBlock(language: language, code: code)
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)
        case .rule:
            Divider()
        case .image(let url, let alt):
            ImageBlock(url: url, alt: alt)
        }
    }
}

/// Nested blocks (list items, quotes) are short, so they stack eagerly.
private struct Stack: View {
    let blocks: [MarkdownBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownMetrics.blockSpacing) {
            ForEach(blocks.indices, id: \.self) { MarkdownBlockView(block: blocks[$0]) }
        }
    }
}

private struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: language ?? "").font(.caption.monospaced())
                Spacer()
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? "Code copied" : "Copy code")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, MarkdownMetrics.inset)
            .padding(.vertical, MarkdownMetrics.tight)
            Divider()
            ScrollView(.horizontal) {
                Text(verbatim: code).font(.callout.monospaced()).padding(MarkdownMetrics.inset)
            }
        }
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: MarkdownMetrics.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MarkdownMetrics.radius, style: .continuous).strokeBorder(.separator))
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #else
        UIPasteboard.general.string = code
        #endif
        copied = true
    }
}

/// Cells keep their natural width; a wide table scrolls sideways instead of wrapping.
private struct TableBlock: View {
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow { ForEach(header.indices, id: \.self) { cell(header[$0]).fontWeight(.semibold).background(.fill.quaternary) } }
                ForEach(rows.indices, id: \.self) { r in
                    Divider()
                    GridRow { ForEach(rows[r].indices, id: \.self) { cell(rows[r][$0]) } }
                }
            }
        }
        .font(.callout.monospacedDigit())
        .clipShape(RoundedRectangle(cornerRadius: MarkdownMetrics.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MarkdownMetrics.radius, style: .continuous).strokeBorder(.separator))
    }

    private func cell(_ text: AttributedString) -> some View {
        Text(text)
            .padding(.horizontal, MarkdownMetrics.inset)
            .padding(.vertical, MarkdownMetrics.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A local image at its natural size, or scaled down to the width it is given; never fetched from the network.
private struct ImageBlock: View {
    let url: URL
    let alt: String

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownMetrics.tight) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    ViewThatFits(in: .horizontal) {
                        image
                        image.resizable().scaledToFit()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: MarkdownMetrics.radius, style: .continuous))
                } else if phase.error != nil {
                    Label(url.lastPathComponent, systemImage: "photo").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .accessibilityLabel(alt.isEmpty ? url.lastPathComponent : alt)
            if !alt.isEmpty { Text(verbatim: alt).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

