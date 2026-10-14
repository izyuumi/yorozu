import Foundation
import YorozuWire

/// One row of the one chat list (#405): a thread, or the Main chat while it is on, newest last visible message first.
/// Status changes, worker steps and renames never move a row; only a visible message does.
struct ChatRow: Identifiable, Equatable {
    enum Dot: Equatable {
        /// An unread reply or finished work: clears once read.
        case unread
        /// An unanswered question, a pending approval or a blocker: clears only once resolved, never by reading.
        case attention
    }
    var id: String
    var name: String
    /// A short excerpt of the last visible message, its own words (never activity text).
    var preview: String
    /// The last visible message's time, epoch ms; what orders the list.
    var time: Int
    var dot: Dot?
    /// Work is running: a small spinner by the time, whatever the dot.
    var running: Bool
    var archived: Bool
    /// Work not yet in a final state, running or not (an uncertain run, a stop not confirmed): Delete is Stop and Delete.
    var openWork = false
    var isMain: Bool { id == ThreadData.mainId }
    /// The name as the list shows it: the Main chat's default unless it was renamed.
    var shownName: String { isMain && name.isEmpty ? String(localized: "Main chat") : name }
    var thread: ThreadData?

    static func newestFirst(_ a: ChatRow, _ b: ChatRow) -> Bool { (a.time, a.id) > (b.time, b.id) }

    /// A preview's words without Markdown markers (`**`, `` ` ``, links), as the row shows them.
    static func plain(_ text: String) -> String {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? text
    }
}

extension PhoneModel {
    /// A thread's row from either list, when loaded.
    func thread(_ id: String) -> ThreadData? { threadList.first { $0.id == id } ?? archivedThreads.first { $0.id == id } }

    /// A thread's name: its row, else its topic record.
    func threadName(_ id: String) -> String? { thread(id)?.name ?? topics[id]?.label }

    /// The list as the host last said, cached for offline use, with what this device knows sooner on top: messages still in
    /// its outbox (a new chat sent offline shows at once), and a chat it has just read losing its unread dot.
    func chatRows(archived: Bool = false) -> [ChatRow] {
        let known = statusKnown
        var rows: [ChatRow] = (archived ? archivedThreads : threadList)
            .filter { !jobTopicIds.contains($0.id) && !deletedThreads.contains($0.id) }
            .map { row(for: $0, known: known) }
        // The Main chat is a row like any other (#405): its name, and in the archived list once archived.
        // A deleted Main chat leaves the list until its next message.
        if mainChat == true, (hostSettings?.mainArchived == true) == archived, mainRow?.lastMessageAt != nil || !timeline.isEmpty {
            let main = mainRow ?? ThreadData(id: ThreadData.mainId, name: "", origin: "main", sourceMessageId: nil, summary: nil, created: 0,
                                             lastActivity: 0, archivedAt: nil, state: nil, lastMessageId: timeline.last?.id, unread: 0,
                                             lastMessageAt: timeline.last?.ts, preview: timeline.last?.shownPreview)
            var r = row(for: main, known: known)
            r.name = hostSettings?.mainName ?? ""
            r.archived = archived
            rows.append(r)
        }
        // The outbox: the newest unsent message of each chat, which the host's rows cannot know yet.
        let pending = Dictionary(grouping: bubbles.filter { $0.seq == nil && $0.user && !Self.jobOnlyKinds.contains($0.kind ?? "") }) {
            $0.threadId ?? ThreadData.mainId
        }
        for (id, sent) in pending {
            guard let newest = sent.max(by: { $0.ts < $1.ts }) else { continue }
            if let i = rows.firstIndex(where: { $0.id == id }) {
                if newest.ts > rows[i].time { rows[i].time = newest.ts; rows[i].preview = newest.shownPreview }
            } else if !archived, id != ThreadData.mainId || mainChat == true, !deletedThreads.contains(id) {
                let name = id == ThreadData.mainId ? "" : threadName(id) ?? Self.provisionalName(sent.min(by: { $0.ts < $1.ts })?.text ?? "")
                rows.append(ChatRow(id: id, name: name, preview: newest.shownPreview, time: newest.ts, dot: nil, running: false, archived: false))
            }
        }
        return rows.sorted(by: ChatRow.newestFirst)
    }

    private func row(for t: ThreadData, known: Bool) -> ChatRow {
        let preview = ChatRow.plain(t.previewNotice.map { NoticeText.text(code: $0.code, params: $0.params, fallback: t.preview ?? "") } ?? t.preview ?? "")
        // Read here a moment ago: the host's next row agrees.
        let readHere = t.lastMessageId != nil && sentReads[t.id] == t.lastMessageId
        let dot: ChatRow.Dot? = t.attention == true ? .attention : (t.unread > 0 && !readHere ? .unread : nil)
        return ChatRow(id: t.id, name: t.name, preview: preview, time: t.lastMessageAt ?? t.created, dot: dot,
                       running: known && t.running == true, archived: t.archivedAt != nil, openWork: t.openWork == true || t.running == true, thread: t)
    }

    /// A new chat's name until the host names it: its first line, as the host does.
    static func provisionalName(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return line.isEmpty ? String(localized: "New chat") : line.count > 40 ? String(line.prefix(39)) + "…" : line
    }
}

extension PhoneModel.Bubble {
    /// One line of a message for a list row.
    var shownPreview: String {
        let text = notice.map { NoticeText.text(code: $0.code, params: $0.params, fallback: self.text) } ?? self.text
        let line = ChatRow.plain(String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(200)))
        return line.isEmpty && !files.isEmpty ? files.map(\.name).joined(separator: ", ") : line
    }
}

/// Where the reader left each chat (#405): the first message on screen while not at the bottom; nil means at the bottom,
/// following new messages. On this device only, across relaunches.
enum ReadingPositions {
    private static let key = "readingPositionsV1"
    static func get(_ chat: String) -> String? { (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[chat] }
    static func set(_ message: String?, chat: String) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        guard all[chat] != message else { return }
        all[chat] = message
        // A bounded map: the newest positions matter.
        if all.count > 500 { all.keys.prefix(all.count - 500).forEach { all[$0] = nil } }
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// What deleting a chat does, said before it happens: for good, on every device and in search; memories stay.
enum DeleteWording {
    /// Delete on the Main chat's row: its own messages; what it started stays.
    static func main(running: Bool) -> String {
        let base = String(localized: "The Main chat's messages and the work they started are deleted for good on every device, and from search. Chats you started and long-term memories Yorozu saved stay.")
        return running ? base + "\n\n" + String(localized: "Work is running in this chat: it is stopped first. If the stop can't be confirmed, the chat is kept and nothing is deleted.") : base
    }
    static func message(running: Bool) -> String {
        let base = String(localized: "The chat and its messages are deleted for good on every device, and from search. Long-term memories Yorozu already saved from it stay.")
        return running ? base + "\n\n" + String(localized: "Work is running in this chat: it is stopped first. If the stop can't be confirmed, the chat is kept and nothing is deleted.") : base
    }
}

