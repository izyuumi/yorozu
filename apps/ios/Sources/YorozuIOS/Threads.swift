import SwiftUI
import YorozuWire

// Threads on the phone (`threads-v1`, owner 2026-10-13): the thread list as a navigation stack, with the main chat
// pinned on top, New chat, Show more, the archived list, and rename, archive and delete.

extension ThreadData {
    /// The Mac's status rule over the current task's state (`TopicStatus`).
    var status: TopicStatus {
        switch state {
        case "working", "queued", "amendment_pending": .running
        case "failed", "uncertain", "cancellation_requested": .attention
        case "done": .done
        default: .idle
        }
    }

    var bySecretary: Bool { origin != "user" }
}

extension PhoneModel {
    /// A thread's row from either list, when loaded.
    func thread(_ id: String) -> ThreadData? { threadList.first { $0.id == id } ?? archivedThreads.first { $0.id == id } }

    /// A thread's name: its row, else its topic record.
    func threadName(_ id: String) -> String? { thread(id)?.name ?? topics[id]?.label }
}

/// The thread a dialog acts on.
struct ThreadRef: Identifiable, Equatable {
    let id: String
    let name: String
    let archived: Bool
}

/// The thread list: the main chat, then threads by latest activity in Needs attention, Running and Recent, a page at a
/// time behind Show more; the Scheduled row and the archived list below.
struct ThreadsScreen: View {
    let model: PhoneModel
    let onMainChat: () -> Void
    let onNewChat: () -> Void

    @State private var renaming: ThreadRef?
    @State private var deleting: ThreadRef?

    var body: some View {
        let rows = model.threadList.filter { !model.jobTopicIds.contains($0.id) }
        List {
            Section {
                Button(action: onMainChat) {
                    Label { Text("Main chat") } icon: { Image(systemName: "pin.fill").foregroundStyle(YorozuPalette.vermilion) }
                }
                .foregroundStyle(.primary)
            }
            if model.jobsSupported == true { JobsRow(jobs: model.jobs) }
            section(String(localized: "Needs attention"), rows.filter { $0.status == .attention })
            section(String(localized: "Running"), rows.filter { $0.status == .running })
            section(String(localized: "topics.section.recent", defaultValue: "Recent"), rows.filter { $0.status == .done || $0.status == .idle })
            Section {
                if model.threadsNext != nil {
                    Button("Show more") { Task { await model.loadThreads(more: true) } }
                }
                NavigationLink(value: ChatRoute.archived) { Label("Archived", systemImage: "archivebox") }
            } footer: {
                if let error = model.threadsError { Text(error) }
                else if model.state != .paired { Text("Status unknown until the host is connected.") }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onNewChat) { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New chat")
                    .help("New chat")
            }
        }
        .task(id: model.state == .paired) { await model.loadThreads() }
        .threadDialogs(model: model, renaming: $renaming, deleting: $deleting)
    }

    @ViewBuilder
    private func section(_ title: String, _ rows: [ThreadData]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { ThreadRow(model: model, thread: $0, renaming: $renaming, deleting: $deleting) }
            }
        }
    }
}

/// The archived threads, a page at a time; each can come back with Unarchive.
struct ArchivedThreadsScreen: View {
    let model: PhoneModel

    @State private var renaming: ThreadRef?
    @State private var deleting: ThreadRef?

    var body: some View {
        List {
            ForEach(model.archivedThreads) { ThreadRow(model: model, thread: $0, renaming: $renaming, deleting: $deleting) }
            if model.archivedNext != nil {
                Button("Show more") { Task { await model.loadThreads(archived: true, more: true) } }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if model.archivedThreads.isEmpty {
                ContentUnavailableView("No archived chats", systemImage: "archivebox",
                                       description: Text("Archived chats leave the list and stay searchable."))
            }
        }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.state == .paired) { await model.loadThreads(archived: true) }
        .threadDialogs(model: model, renaming: $renaming, deleting: $deleting)
    }
}

/// One thread: its status, name (a marker on threads the secretary started), the last activity and its unread count.
private struct ThreadRow: View {
    let model: PhoneModel
    let thread: ThreadData
    @Binding var renaming: ThreadRef?
    @Binding var deleting: ThreadRef?

    var body: some View {
        let ref = ThreadRef(id: thread.id, name: thread.name, archived: thread.archivedAt != nil)
        NavigationLink(value: ChatRoute.topic(thread.id, focus: nil)) {
            HStack(spacing: LayoutMetrics.stack) {
                ThreadSymbol(status: model.state == .paired ? thread.status : nil)
                VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                    HStack(spacing: LayoutMetrics.tight) {
                        if thread.bySecretary {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Started by Secretary")
                        }
                        Text(thread.name).lineLimit(1)
                    }
                    Text(MessageTime.day.string(from: MessageTime.date(thread.lastActivity)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let refusal = model.threadRefusals[thread.id] {
                        Text(refusal).font(.footnote).foregroundStyle(YorozuPalette.warning)
                    }
                }
                Spacer(minLength: 0)
                if thread.unread > 0 {
                    Text(thread.unread, format: .number)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, LayoutMetrics.inner)
                        .padding(.vertical, LayoutMetrics.hair)
                        .background(YorozuPalette.vermilion, in: Capsule())
                        .accessibilityLabel(String(localized: "\(thread.unread) unread"))
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = ref }
            Button(ref.archived ? String(localized: "Unarchive") : String(localized: "Archive"),
                   systemImage: ref.archived ? "tray.and.arrow.up" : "archivebox") {
                Task { await model.control(thread: ref.id, ref.archived ? .unarchive : .archive) }
            }
            .tint(.indigo)
        }
        .contextMenu { ThreadMenu(model: model, ref: ref, renaming: $renaming, deleting: $deleting) }
        .disabled(model.threadControls.values.contains(thread.id))
    }
}

/// Rename, Archive or Unarchive, and Delete, for a row's context menu and a thread's toolbar menu.
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
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = ref }
        }
        .disabled(!model.canControlThread(ref.id))
    }
}

/// A thread's status symbol, with its name for VoiceOver; nil is unknown.
private struct ThreadSymbol: View {
    let status: TopicStatus?

    var body: some View {
        Group {
            switch status {
            case nil: Image(systemName: "questionmark.circle").foregroundStyle(.secondary).accessibilityLabel("Status unknown")
            case .running: ProgressView().controlSize(.small).tint(YorozuPalette.vermilion).accessibilityLabel("Running")
            case .attention: Image(systemName: "exclamationmark.triangle").foregroundStyle(YorozuPalette.warning).accessibilityLabel("Needs attention")
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(YorozuPalette.sage).accessibilityLabel("Done")
            case .idle: Image(systemName: "bubble.left").foregroundStyle(.secondary).accessibilityLabel("Idle")
            }
        }
        .font(.title3)
    }
}

extension View {
    /// The rename alert and the delete confirmation; `onDeleted` runs once a delete was sent.
    func threadDialogs(model: PhoneModel, renaming: Binding<ThreadRef?>, deleting: Binding<ThreadRef?>, onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(ThreadDialogs(model: model, renaming: renaming, deleting: deleting, onDeleted: onDeleted))
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
                Button("Delete", role: .destructive) {
                    Task { if await model.control(thread: ref.id, .delete) { onDeleted() } }
                }
            } message: { _ in
                Text("Its messages are removed for good, from search and from what Yorozu can recall. Memory already taken from them stays.")
            }
    }
}
