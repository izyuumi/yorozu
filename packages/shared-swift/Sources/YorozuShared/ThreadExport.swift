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

    var lines = ["# \(thread.displayTitle)", "", "*\(String(localized: "Exported \(now.formatted(stamp))", locale: locale))*"]
    for row in chatRows(from: events) {
        switch row {
        case .work(let work):
            for entry in work.entries {
                switch entry {
                case .thought(let thought):
                    lines += ["", "> \(thought.text)"]
                case .tools(let activities):
                    lines += ["", collapsed(title: toolsTitle(activities, locale: locale), body: activities.map { toolLine($0, locale: locale) })]
                case .delegation(let card):
                    let inner = card.events.compactMap { event -> String? in
                        guard case .message(let data) = event.payload, !data.text.isEmpty else { return nil }
                        return data.text
                    }
                    lines += [
                        "",
                        collapsed(
                            title: String(localized: "Delegated to \(card.agentId)", locale: locale),
                            body: inner.isEmpty ? ["*\(String(localized: "(no reply)", locale: locale))*"] : inner
                        ),
                    ]
                case .progress(let event):
                    guard case .progressCard(let card) = event.payload else { break }
                    lines += [
                        "",
                        collapsed(
                            title: card.title,
                            body: (card.note.map { [$0, ""] } ?? []) + card.steps.map { "- \($0.label) — \(progressState($0.state, locale: locale))" }
                        ),
                    ]
                }
            }
        case .message(let event):
            guard case .message(let data) = event.payload else { break }
            lines += ["", "## \(data.role == .user ? String(localized: "You", locale: locale) : "Yorozu") — \(event.date.formatted(stamp))", ""]
            for attachment in data.attachments {
                lines += ["*\(String(localized: "Attached: \(attachment.name) (\(attachment.size))", locale: locale))*", ""]
            }
            if !data.text.isEmpty { lines.append(data.text) }
            if data.interrupted == true { lines += ["", "*\(String(localized: "Stopped", locale: locale))*"] }
            else if data.text.isEmpty { lines.append("*\(String(localized: "(no text)", locale: locale))*") }
        case .changes(let event):
            guard case .turnChanges(let data) = event.payload else { break }
            lines += ["", data.files.count == 1 ? String(localized: "1 changed file", locale: locale) : String(localized: "\(data.files.count) changed files", locale: locale)]
            lines += data.files.map { "- \($0.path): +\($0.added) −\($0.removed)" }
        case .approval(let event):
            guard case .approvalCard(let card) = event.payload else { break }
            lines += ["", "> **\(String(localized: "Approval asked", locale: locale))** — \(card.actionClass): \(card.target)"]
        case .unreadable:
            lines += ["", "> *\(String(localized: "Update Yorozu to see this event.", locale: locale))*"]
        case .proposal(let event):
            guard case .ruleProposal(let data) = event.payload else { break }
            lines += ["", "> **\(String(localized: "Rule suggested", locale: locale))** — \(data.rule.summary)"]
        case .question(let event):
            guard case .questionCard(let card) = event.payload else { break }
            lines += ["", "> **\(String(localized: "Question asked", locale: locale))** — \(card.question)"]
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

private func toolsTitle(_ activities: [ToolActivity], locale: Locale) -> String {
    activities.count == 1 ? String(localized: "Ran \(activities[0].name)", locale: locale) : String(localized: "Ran \(activities.count) tools", locale: locale)
}

private func toolLine(_ activity: ToolActivity, locale: Locale) -> String {
    let args = activity.argsSummary
    let mark = activity.running ? "…" : (activity.ok ? String(localized: "ok", locale: locale) : String(localized: "failed", locale: locale))
    return "- `\(activity.name)` \(args.isEmpty ? "" : "(\(args)) ")— \(mark)"
}

private func progressState(_ state: ProgressStep.State, locale: Locale) -> String {
    switch state {
    case .pending: String(localized: "pending", locale: locale)
    case .running: String(localized: "running", locale: locale)
    case .done: String(localized: "done", locale: locale)
    case .failed: String(localized: "failed", locale: locale)
    }
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
        return (trimmed.isEmpty ? String(localized: "Thread") : String(trimmed.prefix(60))) + ".md"
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { markdown in
            let url = URL.temporaryDirectory.appending(path: markdown.filename)
            try Data(markdown.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// Export lives in the thread list's low-frequency actions, outside the chat toolbar.
/// `markdown` is a closure because building it walks the whole thread, and a menu
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
            Label("Export as Markdown…", systemImage: "square.and.arrow.up")
        }
    }
}
