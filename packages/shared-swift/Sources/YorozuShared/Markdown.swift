import Foundation
import SwiftUI

/// The Markdown an agent actually replies in, in two halves.
///
/// Inline spans — bold, italic, inline code, links — are Foundation's job: `AttributedString`
/// parses them and SwiftUI draws them. What Foundation's inline mode throws away is the block
/// structure, so headings, fenced code, lists and tables are parsed here instead. That split is
/// the whole reason this file is small: nothing re-implements emphasis.
///
/// Everything is written for text that is still arriving. A reply mid-stream routinely ends in
/// an unclosed `**` or an unterminated fence, and neither is an error — it is a sentence the
/// model has not finished yet.

/// One block of a rendered reply.
public enum MarkdownBlock: Equatable, Sendable {
    /// Inline Markdown; the newlines inside one are the author's, not block breaks.
    case paragraph(String)
    case heading(level: Int, text: String)
    /// A fenced block. Verbatim: nothing inside it is inline Markdown.
    case code(language: String?, text: String)
    case list(ordered: Bool, items: [String])
    /// A pipe table. Ragged rows are kept as they came — padding them is the view's problem.
    case table(header: [String], rows: [[String]])
    case rule
}

/// Splits a reply into blocks. Never fails and never drops text: anything it does not
/// recognise comes back as a paragraph, which is exactly how plain prose arrives.
public func markdownBlocks(_ text: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var paragraph: [String] = []
    let lines = text.components(separatedBy: .newlines)
    var index = 0

    func flushParagraph() {
        let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !joined.isEmpty { blocks.append(.paragraph(joined)) }
        paragraph = []
    }

    while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Fences first: everything else is only a block if it is not inside one.
        if let fence = openingFence(trimmed) {
            flushParagraph()
            let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
            var body: [String] = []
            index += 1
            while index < lines.count,
                !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence)
            {
                body.append(lines[index])
                index += 1
            }
            // Past the closing fence, or past the end when the reply is still streaming one.
            index += 1
            blocks.append(
                .code(language: language.isEmpty ? nil : language, text: body.joined(separator: "\n"))
            )
            continue
        }

        if trimmed.isEmpty {
            flushParagraph()
            index += 1
            continue
        }

        if isRule(trimmed) {
            flushParagraph()
            blocks.append(.rule)
            index += 1
            continue
        }

        if let heading = heading(trimmed) {
            flushParagraph()
            blocks.append(heading)
            index += 1
            continue
        }

        // A table needs its separator row to be one: a lone `|` line is just prose.
        if trimmed.hasPrefix("|"), index + 1 < lines.count,
            isTableSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces))
        {
            flushParagraph()
            let header = tableCells(trimmed)
            index += 2
            var rows: [[String]] = []
            while index < lines.count {
                let row = lines[index].trimmingCharacters(in: .whitespaces)
                guard row.hasPrefix("|") else { break }
                rows.append(tableCells(row))
                index += 1
            }
            blocks.append(.table(header: header, rows: rows))
            continue
        }

        if listMarker(trimmed) != nil {
            flushParagraph()
            let ordered = orderedMarker(trimmed) != nil
            var items: [String] = []
            while index < lines.count {
                let item = lines[index].trimmingCharacters(in: .whitespaces)
                if let marker = listMarker(item), (orderedMarker(item) != nil) == ordered {
                    items.append(String(item.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
                    index += 1
                } else if !item.isEmpty, !items.isEmpty, lines[index].hasPrefix(" "), listMarker(item) == nil {
                    // An indented continuation belongs to the item above it rather than
                    // starting a paragraph that would break the list in two.
                    items[items.count - 1] += " " + item
                    index += 1
                } else {
                    break
                }
            }
            blocks.append(.list(ordered: ordered, items: items))
            continue
        }

        paragraph.append(line)
        index += 1
    }
    flushParagraph()
    return blocks
}

/// ``` or ~~~, and whichever it is has to be the one that closes it.
private func openingFence(_ trimmed: String) -> String? {
    for fence in ["```", "~~~"] where trimmed.hasPrefix(fence) { return fence }
    return nil
}

private func heading(_ trimmed: String) -> MarkdownBlock? {
    let hashes = trimmed.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes) else { return nil }
    let rest = String(trimmed.dropFirst(hashes))
    // `#hashtag` is not a heading; ATX wants the space.
    guard rest.first == " " else { return nil }
    // A closing run of hashes is decoration rather than text: `## Totals ##` is one heading.
    return .heading(
        level: hashes,
        text: rest.trimmingCharacters(in: CharacterSet(charactersIn: " #"))
    )
}

private func isRule(_ trimmed: String) -> Bool {
    guard trimmed.count >= 3 else { return false }
    return ["-", "*", "_"].contains { mark in trimmed.allSatisfy { String($0) == mark } }
}

/// The `- `, `* `, `+ ` or `1. ` that starts an item, or nil.
private func listMarker(_ trimmed: String) -> String? {
    for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) { return bullet }
    return orderedMarker(trimmed)
}

/// `12. ` or `12) `, returned whole so the caller can drop exactly it.
private func orderedMarker(_ trimmed: String) -> String? {
    let digits = trimmed.prefix(while: \.isNumber)
    guard !digits.isEmpty, digits.count <= 9 else { return nil }
    let rest = trimmed.dropFirst(digits.count)
    guard let separator = rest.first, separator == "." || separator == ")",
        rest.dropFirst().first == " "
    else { return nil }
    return "\(digits)\(separator) "
}

private func isTableSeparator(_ trimmed: String) -> Bool {
    guard trimmed.hasPrefix("|") else { return false }
    let cells = tableCells(trimmed)
    guard !cells.isEmpty else { return false }
    return cells.allSatisfy { cell in
        let body = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return !body.isEmpty && body.allSatisfy { $0 == "-" }
    }
}

private func tableCells(_ trimmed: String) -> [String] {
    var row = Substring(trimmed)
    if row.hasPrefix("|") { row = row.dropFirst() }
    if row.hasSuffix("|") { row = row.dropLast() }
    return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}

extension AttributedString {
    /// One paragraph, heading or table cell as SwiftUI can draw it: bold, italic, inline code
    /// and links, and nothing that would need a block of its own.
    ///
    /// Never throws. A half-written span is the normal state of a streaming reply, so anything
    /// Foundation will not parse falls back to the literal text the model sent.
    /// `highlight` is the thread's search term, if any: every occurrence of it in the rendered
    /// text gets a background. Empty — the usual case — costs a length check and nothing else.
    public static func chatInline(_ markdown: String, highlight: String = "") -> AttributedString {
        guard
            var attributed = try? AttributedString(
                markdown: markdown,
                options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        else { return AttributedString(markdown).highlighting(highlight) }
        // SwiftUI honours the strong and emphasis intents by itself but leaves code looking
        // like prose, so that one run style is applied here. Ranges are collected first:
        // writing to the string while walking its runs invalidates the walk.
        let code = attributed.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map(\.range)
        for range in code {
            attributed[range].font = .body.monospaced()
            attributed[range].backgroundColor = .secondary.opacity(0.15)
        }
        return attributed.highlighting(highlight)
    }
}

extension AttributedString {
    /// The whole reply as one attributed string, block by block, for a place that has to select
    /// across it — the phone's Select sheet. Inline Markdown is rendered; the block kinds are
    /// spelled out plainly (a code fence as monospaced text, a list as its items with markers, a
    /// table as its rows) rather than drawn, because the point here is the words, not the look.
    public static func chatDocument(_ markdown: String) -> AttributedString {
        var document = AttributedString()
        for (offset, block) in markdownBlocks(markdown).enumerated() {
            if offset > 0 { document += AttributedString("\n\n") }
            switch block {
            case .paragraph(let text):
                document += chatInline(text)
            case .heading(_, let text):
                var heading = chatInline(text)
                heading.font = .headline
                document += heading
            case .code(_, let text):
                var code = AttributedString(text)
                code.font = .body.monospaced()
                document += code
            case .list(let ordered, let items):
                for (index, item) in items.enumerated() {
                    if index > 0 { document += AttributedString("\n") }
                    document += AttributedString(ordered ? "\(index + 1). " : "• ")
                    document += chatInline(item)
                }
            case .table(let header, let rows):
                for (index, row) in ([header] + rows).enumerated() {
                    if index > 0 { document += AttributedString("\n") }
                    document += AttributedString(row.joined(separator: "  ·  "))
                }
            case .rule:
                document += AttributedString("———")
            }
        }
        return document
    }
}
