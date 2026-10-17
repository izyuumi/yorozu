import SwiftUI
import YorozuWire

/// The conversation list: the sidebar on iPad and Mac, with an Automations row above it, and the Chats tab's root on iPhone.
/// Compose opens a new `convId`, which joins the list with its first message.
struct ConversationsView: View {
    /// What the list selects: a conversation, or the Crons row of the sidebar.
    private enum Pane: Hashable { case chat(String), crons }

    let model: V3Model
    /// The open conversation; the Crons section sets it too (#432).
    @Binding var selection: String?
    @Binding var section: V3HomeView.Section
    /// The sidebar's Crons row; the iPhone has a Crons tab instead.
    let showsCrons: Bool
    @State private var showingSettings = false
    /// The Archived rows are shown below the list (#428).
    @State private var showingArchived = false
    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var deleting: Conversation?

    var body: some View {
        list.sheet(isPresented: $showingSettings) { V3SettingsSheet(model: model) }
    }

    private var pane: Binding<Pane?> {
        Binding {
            showsCrons && section == .crons ? .crons : selection.map(Pane.chat)
        } set: { pane in
            switch pane {
            case .crons: section = .crons
            case .chat(let convId):
                section = .chats
                selection = convId
            case nil:
                section = .chats
                selection = nil
            }
        }
    }

    private var list: some View {
        let conversations = model.list
        // Only the sidebar selects: a stack's list selects in edit mode alone, so on iPhone each row is a button.
        return List(selection: showsCrons ? pane : nil) {
            if let problem {
                Section {
                    Label { Text(problem) } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(YorozuPalette.warning)
                    }
                    Button(String(localized: "Pair Again")) { model.unpair() }
                }
            }
            if showsCrons {
                Label(String(localized: "Automations"), systemImage: "clock").tag(Pane.crons)
            }
            Section {
                ForEach(conversations, content: row)
            } header: {
                if showsCrons { Text("Chats") }
            }
            let archived = model.archivedList
            if !archived.isEmpty {
                // One row at the list's end opens and closes the Archived rows below it, the same on every device.
                Section {
                    Button {
                        withAnimation { showingArchived.toggle() }
                    } label: {
                        Label {
                            Text("Archived")
                        } icon: {
                            Image(systemName: "archivebox")
                        }
                        .badge(archived.count)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityValue(showingArchived ? Text("Shown") : Text("Hidden"))
                    .accessibilityIdentifier("conversations.archived")
                    if showingArchived { ForEach(archived, content: row) }
                }
            }
        }
        .alert(String(localized: "Rename Conversation"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming) { conversation in
            TextField(String(localized: "Title"), text: $newTitle)
                .accessibilityIdentifier("conversations.rename.field")
            Button(String(localized: "Rename")) { model.rename(conversation.id, to: newTitle) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text("Leave it empty to use the automatic title.")
        }
        .confirmationDialog(String(localized: "Delete this conversation?"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting) { conversation in
            Button(String(localized: "Delete"), role: .destructive) {
                if selection == conversation.id { selection = nil }
                model.delete(conversation.id)
            }
        } message: { _ in
            Text("It is deleted on the host and on every device, with its history.")
        }
        .overlay {
            if conversations.isEmpty && model.archivedList.isEmpty {
                ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Start one with the compose button."))
            }
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitleIfAvailable(model.state.label)
        .toolbar {
            // The Mac has its Settings window (⌘,) instead.
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button(String(localized: "Settings"), systemImage: "gearshape") { showingSettings = true }
                    .accessibilityIdentifier("conversations.settings")
            }
            #endif
            // Compose at the bottom trailing corner, as Mail and Notes have it; the Mac has no bottom bar.
            #if os(iOS)
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                compose
            }
            #else
            ToolbarItem(placement: .primaryAction) { compose }
            #endif
        }
    }

    private var compose: some View {
        Button(String(localized: "New Conversation"), systemImage: "square.and.pencil") { pane.wrappedValue = .chat(V3Event.newId()) }
            .keyboardShortcut("n")
            .help(String(localized: "New Conversation"))
            .accessibilityIdentifier("conversations.new")
    }

    /// One conversation's row with its actions: Mark as Read or Unread from the leading edge (as in #410), Archive and
    /// Delete from the trailing edge, all of them and Rename in its menu. Changes need the host, so they wait for a session.
    private func row(_ conversation: Conversation) -> some View {
        let archived = conversation.archived == true
        let archive = Button(archived ? String(localized: "Unarchive") : String(localized: "Archive"),
            systemImage: archived ? "tray.and.arrow.up" : "archivebox") {
            if !archived, selection == conversation.id { selection = nil }
            model.setArchived(conversation.id, !archived)
        }
        let delete = { (title: String) in Button(title, systemImage: "trash", role: .destructive) { deleting = conversation } }
        let label = ConversationRow(conversation: conversation, typing: model.typing.contains(conversation.id))
        return Group {
            if showsCrons {
                label
            } else {
                Button { selection = conversation.id } label: { label }
                    .foregroundStyle(.primary)
            }
        }
            .tag(Pane.chat(conversation.id))
            .swipeActions(edge: .leading, allowsFullSwipe: true) { V3ReadMarkButton(model: model, conversation: conversation) }
            .swipeActions(edge: .trailing) {
                delete(String(localized: "Delete")).disabled(!model.canPatch)
                archive.tint(.indigo).disabled(!model.canPatch)
            }
            .contextMenu {
                V3ReadMarkButton(model: model, conversation: conversation)
                Group {
                    Button(String(localized: "Rename…"), systemImage: "pencil") {
                        newTitle = conversation.title ?? ""
                        renaming = conversation
                    }
                    archive
                    Divider()
                    delete(String(localized: "Delete…"))
                }
                .disabled(!model.canPatch)
            }
    }

    /// A state the user must act on, instead of a list that silently never updates.
    private var problem: String? {
        switch model.state {
        case .unpaired: String(localized: "The host removed this device. Pair again to keep chatting.")
        case .updateRequired: String(localized: "The host speaks a newer version. Update Yorozu.")
        default: nil
        }
    }
}

/// Mark as Read or Mark as Unread for one conversation; nothing before its first reply.
private struct V3ReadMarkButton: View {
    let model: V3Model
    let conversation: Conversation

    var body: some View {
        if conversation.latestReply != nil {
            let unread = conversation.unreadCount > 0
            Button(unread ? String(localized: "Mark as Read") : String(localized: "Mark as Unread"),
                systemImage: unread ? "envelope.open" : "envelope.badge") {
                if unread { model.markRead(conversation.id, explicit: true) } else { model.markUnread(conversation.id) }
            }
            .tint(.blue)
        }
    }
}

/// The title (#428; the first message until the host has made one), the latest message below it.
private struct ConversationRow: View {
    let conversation: Conversation
    let typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
            HStack(alignment: .firstTextBaseline) {
                Text(conversation.displayTitle)
                    // Bold while unread, regular once read (#429).
                    .bold(conversation.unreadCount > 0)
                    .lineLimit(1)
                Spacer(minLength: LayoutMetrics.inner)
                Text(Self.time(conversation.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // A dot, not a count (owner, 2026-10-17): orange when a run failed, blue for unread replies.
                if let dot { Image(systemName: "circle.fill").font(.caption2).foregroundStyle(dot) }
            }
            Group {
                if typing {
                    Text("Typing…").foregroundStyle(.tint)
                } else {
                    Text(conversation.lastText)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(conversation.needsAttention ? Text("Needs attention") : conversation.unreadCount > 0 ? Text("Unread") : Text(""))
    }

    private var dot: Color? {
        if conversation.needsAttention { return .orange }
        return conversation.unreadCount > 0 ? .blue : nil
    }

    /// The time today, the date on any other day.
    private static func time(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .omitted)
    }
}

