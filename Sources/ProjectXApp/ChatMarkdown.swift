import SwiftUI

extension AttributedString {
    /// Markdown flattened into one AttributedString so a single selectable `Text` keeps block structure.
    /// `Text` ignores `presentationIntent`, so blocks become newlines, list markers and fonts here.
    init(chatMarkdown source: String) {
        guard let parsed = try? AttributedString(markdown: source, options: .init(failurePolicy: .returnPartiallyParsedIfPossible)) else { self.init(source); return }
        self.init()
        var previous: [PresentationIntent.IntentType] = []
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            let blocks = run.presentationIntent?.components ?? [] // innermost first
            if !previous.isEmpty, blocks.first?.identity != previous.first?.identity {
                let isCell = if case .tableCell = blocks.first?.kind { true } else { false }
                let sameRow = isCell && blocks.count > 1 && previous.count > 1 && blocks[1] == previous[1]
                self += AttributedString(sameRow ? "\t" : blocks.last == previous.last ? "\n" : "\n\n")
            }
            for (i, block) in blocks.enumerated() {
                switch block.kind {
                case .header(let level): piece.font = (level == 1 ? Font.title2 : level == 2 ? .title3 : .headline).bold()
                case .codeBlock:
                    piece.font = .system(.body, design: .monospaced); piece.backgroundColor = .secondary.opacity(0.15)
                    if piece.characters.last == "\n" { piece.characters.removeLast() }
                case .blockQuote: piece.foregroundColor = .secondary
                case .tableHeaderRow: piece.inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
                case .listItem(let ordinal) where i == 1 && !previous.contains(block):
                    let depth = blocks.filter { if case .listItem = $0.kind { true } else { false } }.count
                    let marker = i + 1 < blocks.count && blocks[i + 1].kind == .orderedList ? "\(ordinal). " : "• "
                    piece = AttributedString(String(repeating: "    ", count: depth - 1) + marker) + piece
                default: break
                }
            }
            self += piece
            previous = blocks
        }
    }
}
