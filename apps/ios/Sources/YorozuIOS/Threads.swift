import SwiftUI
import YorozuWire

// The chat list on the phone (#405, owner 2026-10-14): one list, newest last message first, the Main chat among the
// threads while it is on; New chat drafts on top of it; swipe to Archive, Rename and Delete in the context menu.

extension PhoneModel {
    /// A thread's row from either list, when loaded.
    func thread(_ id: String) -> ThreadData? { threadList.first { $0.id == id } ?? archivedThreads.first { $0.id == id } }

    /// A thread's name: its row, else its topic record.
    func threadName(_ id: String) -> String? { thread(id)?.name ?? topics[id]?.label }

    /// The Chats dot: a chat needs the user (orange). Unread replies and running work are no reason to look.
    var attentionChats: Bool { chatRows().contains { $0.dot == .attention } }
}

/// The chat a dialog acts on.
struct ThreadRef: Identifiable, Equatable {
    let id: String
    let name: String
    let archived: Bool
    /// Work is running in it: Delete becomes Stop and Delete.
    var running = false
}

/// The list: New chat drafts, then every chat by its last message, then Archived. Opening a chat pushes it on iPhone and
/// shows it beside the list on iPad.
struct ThreadsScreen: View {
    let model: PhoneModel
    let onNewChat: () -> Void
    let onOpen: (ChatRoute) -> Void

    @State private var renaming: ThreadRef?
    @State private var deleting: ThreadRef?

    var body: some View {
        let rows = model.chatRows()
        List {
            HistoryStatus(model: model)
            ForEach(model.drafts.newChats, id: \.id) { item in
                Button { onOpen(.newChat(item.id)) } label: { DraftRow(draft: item.draft) }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .trailing) {
                        Button("Discard", systemImage: "trash", role: .destructive) { model.drafts.clear(Drafts.new(item.id), discardFiles: true) }
                    }
            }
            ForEach(rows) { row in
                ChatRowButton(model: model, row: row, open: onOpen, renaming: $renaming, deleting: $deleting)
            }
            Section {
                Button { onOpen(.archived) } label: { Label("Archived", systemImage: "archivebox") }
                    .foregroundStyle(.primary)
            } footer: {
                if let error = model.threadsError { Text(error) }
            }
        }
        .listStyle(.plain)
        .overlay {
            // An empty list says why: still downloading, or truly no chats yet.
            if rows.isEmpty && model.drafts.newChats.isEmpty {
                if model.historySynced {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Start one with New chat. Yorozu names it from your first message."))
                } else {
                    ContentUnavailableView("Downloading your chats", systemImage: "arrow.down.circle",
                                           description: Text("Your chat history appears here as it arrives from the host."))
                }
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onNewChat) { Image(systemName: "square.and.pencil") }
                    .keyboardShortcut("n")
                    .accessibilityLabel("New chat")
                    .help("New chat")
            }
        }
        .refreshable { await model.loadThreads(); await model.loadThreads(archived: true) }
        .threadDialogs(model: model, renaming: $renaming, deleting: $deleting)
    }
}

/// The archived chats; each comes back with Unarchive, and stays searchable meanwhile.
struct ArchivedThreadsScreen: View {
    let model: PhoneModel
    let onOpen: (ChatRoute) -> Void

    @State private var renaming: ThreadRef?
    @State private var deleting: ThreadRef?

    var body: some View {
        let rows = model.chatRows(archived: true)
        List {
            ForEach(rows) { ChatRowButton(model: model, row: $0, open: onOpen, renaming: $renaming, deleting: $deleting) }
        }
        .listStyle(.plain)
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView("No archived chats", systemImage: "archivebox",
                                       description: Text("Archived chats leave the list and stay searchable."))
            }
        }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
        .threadDialogs(model: model, renaming: $renaming, deleting: $deleting)
    }
}

/// Whether the history on this device is whole: a first download or a resumed one says so, never an empty list.
private struct HistoryStatus: View {
    let model: PhoneModel

    var body: some View {
        if model.historyWriteFailed {
            Label("Couldn't save chats on this device. Free up some space; Yorozu keeps trying.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if !model.historySynced && model.historySupported != false && model.hasPairing {
            HStack(spacing: LayoutMetrics.inner) {
                if model.state == .paired { ProgressView().controlSize(.small) } else { Image(systemName: "icloud.slash").foregroundStyle(.secondary) }
                Text(model.state == .paired ? "Downloading chat history…" : "Chat history is incomplete on this device. It finishes downloading when the host is connected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A New chat not sent yet.
private struct DraftRow: View {
    let draft: Drafts.Draft

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
            HStack {
                Text("Draft").fontWeight(.semibold).foregroundStyle(YorozuPalette.vermilion)
                Spacer()
                Text(ChatTime.label(draft.updated)).font(.footnote).foregroundStyle(.secondary)
            }
            Text(draft.text.isEmpty ? draft.files.map(\.chosen.name).joined(separator: ", ") : draft.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// When a row's last message was: the time today, the weekday this week, else the date.
@MainActor enum ChatTime {
    static func label(_ ts: Int) -> String {
        let date = MessageTime.date(ts), calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let week = calendar.date(byAdding: .day, value: -6, to: .now), date > week { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(date: .numeric, time: .omitted)
    }
}

/// One chat: its name, an excerpt of its last message, the time with a small spinner while work runs, and one filled dot.
private struct ChatRowButton: View {
    let model: PhoneModel
    let row: ChatRow
    let open: (ChatRoute) -> Void
    @Binding var renaming: ThreadRef?
    @Binding var deleting: ThreadRef?

    var body: some View {
        let ref = ThreadRef(id: row.id, name: row.name, archived: row.archived, running: row.running)
        Button { open(row.isMain ? .main : .topic(row.id, focus: nil)) } label: { ChatRowLabel(row: row, refusal: model.threadRefusals[row.id]) }
            .foregroundStyle(.primary)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if !row.isMain {
                    Button(row.archived ? String(localized: "Unarchive") : String(localized: "Archive"),
                           systemImage: row.archived ? "tray.and.arrow.up" : "archivebox") {
                        Task { await model.control(thread: ref.id, ref.archived ? .unarchive : .archive) }
                    }
                    .tint(.indigo)
                }
            }
            .contextMenu { if !row.isMain { ThreadMenu(model: model, ref: ref, renaming: $renaming, deleting: $deleting) } }
            .disabled(model.threadControls.values.contains(row.id))
    }
}

struct ChatRowLabel: View {
    let row: ChatRow
    var refusal: String?

    private enum Metrics { static let dot: CGFloat = 10 }

    var body: some View {
        HStack(alignment: .top, spacing: LayoutMetrics.stack) {
            VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                Text(row.isMain ? String(localized: "Main chat") : row.name).fontWeight(.semibold).lineLimit(1)
                Text(row.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                if let refusal { Text(refusal).font(.footnote).foregroundStyle(YorozuPalette.warning) }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: LayoutMetrics.inner) {
                HStack(spacing: LayoutMetrics.tight) {
                    if row.running { ProgressView().controlSize(.mini) }
                    Text(ChatTime.label(row.time)).font(.footnote).foregroundStyle(.secondary)
                }
                if let dot = row.dot {
                    Circle().fill(dot == .attention ? Color.orange : Color.blue).frame(width: Metrics.dot, height: Metrics.dot)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(row))
    }

    /// Name, status, last message and time, in that order; the dot and spinner as words.
    static func label(_ row: ChatRow) -> String {
        var parts = [row.isMain ? String(localized: "Main chat") : row.name]
        if row.dot == .attention { parts.append(String(localized: "Needs your attention")) }
        else if row.dot == .unread { parts.append(String(localized: "Unread")) }
        if row.running { parts.append(String(localized: "Working")) }
        if row.archived { parts.append(String(localized: "Archived")) }
        parts.append(row.preview)
        parts.append(ChatTime.label(row.time))
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Rename and Delete (and Archive or Unarchive) for a row's context menu and a chat's toolbar menu.
struct ThreadMenu: View {
    let model: PhoneModel
    let ref: ThreadRef
    @Binding var renaming: ThreadRef?
    @Binding var deleting: ThreadRef?

    var body: some View {
        Group {
            Button("Rename", systemImage: "pencil") { renaming = ref }
            Button(ref.archived ? String(localized: "Unarchive") : String(localized: "Archive"),
                   systemImage: ref.archived ? "tray.and.arrow.up" : "archivebox") {
                Task { await model.control(thread: ref.id, ref.archived ? .unarchive : .archive) }
            }
            Button(ref.running ? String(localized: "Stop and Delete") : String(localized: "Delete"), systemImage: "trash", role: .destructive) { deleting = ref }
        }
        .disabled(!model.canControlThread(ref.id))
    }
}

extension View {
    /// The rename alert and the delete confirmation; `onDeleted` runs once a delete was sent.
    func threadDialogs(model: PhoneModel, renaming: Binding<ThreadRef?>, deleting: Binding<ThreadRef?>, onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(ThreadDialogs(model: model, renaming: renaming, deleting: deleting, onDeleted: onDeleted))
    }
}

/// What deleting a chat does, said before it happens: for good, on every device and in search; memories stay.
enum DeleteWording {
    static func message(running: Bool) -> String {
        let base = String(localized: "The chat and its messages are deleted for good on every device, and from search. Long-term memories Yorozu already saved from it stay.")
        return running ? base + "\n\n" + String(localized: "Work is running in this chat: it is stopped first. If the stop can't be confirmed, the chat is kept and nothing is deleted.") : base
    }
}

private struct ThreadDialogs: ViewModifier {
    let model: PhoneModel
    @Binding var renaming: ThreadRef?
    @Binding var deleting: ThreadRef?
    let onDeleted: () -> Void

    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { ref in
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, name != ref.name { Task { await model.control(thread: ref.id, .rename, name: name) } }
                }
            }
            .onChange(of: renaming) { _, ref in if let ref { name = ref.name } }
            .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { ref in
                Button(ref.running ? String(localized: "Stop and Delete") : String(localized: "Delete"), role: .destructive) {
                    // Stop and Delete waits for the host's answer: the chat goes only once its work stopped.
                    let stop = ref.running && model.historySupported == true
                    Task { if await model.control(thread: ref.id, stop ? .stopAndDelete : .delete) { onDeleted() } }
                }
            } message: { ref in
                Text(DeleteWording.message(running: ref.running))
            }
    }
}

extension ThreadData {
    /// Started by the secretary from the main chat.
    var bySecretary: Bool { origin != "user" }
}
