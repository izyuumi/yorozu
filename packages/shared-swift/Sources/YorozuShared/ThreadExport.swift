import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A thread as a Markdown file: what it was called, when it was exported, and every message in
/// order with who said it and when. Tool use is kept — it is often the substance of the answer —
/// but collapsed, so the transcript reads as a conversation and the machinery is one click away
/// in anything that renders Markdown's HTML.
///
/// Pure, so the formatting is a test rather than a screenshot of a share sheet.
public func threadMarkdown(
    thread: ThreadSummary,
    events: [YorozuEvent],
    now: Date = Date(),
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    var stamp = Date.FormatStyle(date: .abbreviated, time: .shortened)
    stamp.locale = locale
    stamp.timeZone = timeZone

    var lines = ["# \(thread.displayTitle)", "", "*Exported \(now.formatted(stamp))*"]
    for row in chatRows(from: events) {
        switch row {
        case .message(let event):
            guard case .message(let data) = event.payload else { break }
            lines += ["", "## \(data.role == .user ? "You" : "Yorozu") — \(event.date.formatted(stamp))", ""]
            if let attachment = data.attachment {
                lines += ["*Attached: \(attachment.name) (\(attachment.size))*", ""]
            }
            lines.append(data.text.isEmpty ? "*(no text)*" : data.text)
        case .tools(let activities):
            lines += ["", collapsed(title: toolsTitle(activities), body: activities.map(toolLine))]
        case .delegation(let card):
            let inner = card.events.compactMap { event -> String? in
                guard case .message(let data) = event.payload, !data.text.isEmpty else { return nil }
                return data.text
            }
            lines += [
                "",
                collapsed(
                    title: "Delegated to \(card.agentId)",
                    body: inner.isEmpty ? ["*(no reply)*"] : inner
                ),
            ]
        case .approval(let event):
            guard case .approvalCard(let card) = event.payload else { break }
            lines += ["", "> **Approval asked** — \(card.actionClass): \(card.target)"]
        case .proposal(let event):
            guard case .ruleProposal(let data) = event.payload else { break }
            lines += ["", "> **Rule suggested** — \(data.rule.summary)"]
        case .question(let event):
            guard case .questionCard(let card) = event.payload else { break }
            lines += ["", "> **Question asked** — \(card.question)"]
        case .progress(let event):
            guard case .progressCard(let card) = event.payload else { break }
            lines += [
                "",
                collapsed(
                    title: card.title,
                    body: card.steps.map { "- \($0.label) — \($0.state.rawValue)" }
                ),
            ]
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

/// A run of tool use as one collapsed note. `<details>` is HTML, but it is the one thing every
/// Markdown renderer worth exporting to understands as "folded away".
private func collapsed(title: String, body: [String]) -> String {
    """
    <details><summary>\(title)</summary>

    \(body.joined(separator: "\n"))

    </details>
    """
}

private func toolsTitle(_ activities: [ToolActivity]) -> String {
    activities.count == 1 ? "Ran \(activities[0].name)" : "Ran \(activities.count) tools"
}

private func toolLine(_ activity: ToolActivity) -> String {
    let args = activity.argsSummary
    let mark = activity.running ? "…" : (activity.ok ? "ok" : "failed")
    return "- `\(activity.name)` \(args.isEmpty ? "" : "(\(args)) ")— \(mark)"
}

extension YorozuEvent {
    /// The event's timestamp as a date. Epoch milliseconds on the wire.
    public var date: Date { Date(timeIntervalSince1970: Double(ts) / 1000) }
}

/// A thread's Markdown, ready for a share sheet. Written to a real `.md` file only when
/// something actually asks for it, so opening the menu costs nothing.
public struct ThreadMarkdown: Transferable, Sendable {
    public let title: String
    public let text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }

    /// A file name with nothing in it a file system would object to.
    public var filename: String {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(
            separator: "-"
        )
        let trimmed = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "Thread" : String(trimmed.prefix(60))) + ".md"
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { markdown in
            let url = URL.temporaryDirectory.appending(path: markdown.filename)
            try Data(markdown.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// The one export control, so the chat's toolbar and the list's context menu offer exactly the
/// same thing. `markdown` is a closure because building it walks the whole thread, and a menu
/// that is never opened should not have paid for that.
public struct ExportThreadButton: View {
    private let title: String
    private let markdown: () -> String

    public init(title: String, markdown: @escaping () -> String) {
        self.title = title
        self.markdown = markdown
    }

    public var body: some View {
        ShareLink(
            item: ThreadMarkdown(title: title, text: markdown()),
            preview: SharePreview(title, image: Image(systemName: "doc.text"))
        ) {
            Label("Export as Markdown", systemImage: "square.and.arrow.up")
        }
    }
}
