import SwiftUI
import YorozuWire

struct ConversationsView: View {
    private enum Pane: Hashable { case chat(String), crons }

    let model: AppModel
    @Binding var selection: String?
    @Binding var section: HomeView.Section
    let showsCrons: Bool
    var openBeside: ((String) -> Void)?
    var side: (String) -> PaneSide? = { _ in nil }
    var dragStarted: () -> Void = {}
    @State private var showingSettings = false
    @State private var showingArchived = false
    @State private var renaming: Conversation?
    @State private var newTitle = ""
    @State private var deleting: Conversation?

    var body: some View {
        list.sheet(isPresented: $showingSettings) { SettingsSheet(model: model) }
            #if os(iOS)
            .task { await AppStoreUpdate.shared.check(isDemo: model.isDemo) }
            #endif
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
        return List(selection: showsCrons ? pane : nil) {
            if model.isDemo {
                Label(String(localized: "Demo"), systemImage: "play.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("demo.indicator")
            }
            #if os(iOS)
            if let update = AppStoreUpdate.shared.available {
                Section {
                    HStack {
                        Link(destination: update.url) {
                            Label(String(localized: "Yorozu \(update.version) is available"), systemImage: "arrow.down.circle")
                        }
                        Spacer()
                        Button(String(localized: "Dismiss"), systemImage: "xmark") { AppStoreUpdate.shared.dismiss() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            #endif
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
            let pinned = conversations.filter { $0.pinnedAt != nil }.sorted { ($0.pinnedAt ?? 0) > ($1.pinnedAt ?? 0) }
            if !pinned.isEmpty {
                Section {
                    ForEach(pinned, content: row)
                } header: {
                    Text("Pinned")
                }
            }
            Section {
                ForEach(conversations.filter { $0.pinnedAt == nil }, content: row)
            } header: {
                if showsCrons || !pinned.isEmpty { Text("Chats") }
            }
            let archived = model.archivedList
            if !archived.isEmpty {
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
                    #if os(macOS)
                    .buttonStyle(.plain)
                    #endif
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
        .statusBanner(StatusBanner(model: model, convId: nil))
        .navigationSubtitleIfAvailable(model.outage != nil ? "" : model.state.label)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button(String(localized: "Settings"), systemImage: "gearshape") { showingSettings = true }
                    .accessibilityIdentifier("conversations.settings")
            }
            #endif
            ToolbarItem(placement: .primaryAction) { compose }
        }
    }

    private var compose: some View {
        Button(String(localized: "New Conversation"), systemImage: "square.and.pencil") { pane.wrappedValue = .chat(WireEvent.newId()) }
            .keyboardShortcut("n")
            .help(String(localized: "New Conversation"))
            .accessibilityIdentifier("conversations.new")
    }

    private func row(_ conversation: Conversation) -> some View {
        let archived = conversation.archived == true
        let archive = Button(archived ? String(localized: "Unarchive") : String(localized: "Archive"),
            systemImage: archived ? "tray.and.arrow.up" : "archivebox") {
            if !archived, selection == conversation.id { selection = nil }
            model.setArchived(conversation.id, !archived)
        }
        let pinned = conversation.pinnedAt != nil
        let pin = Button(pinned ? String(localized: "Unpin") : String(localized: "Pin"), systemImage: pinned ? "pin.slash" : "pin") {
            withAnimation { model.setPinned(conversation.id, !pinned) }
        }
        let delete = { (title: String) in Button(title, systemImage: "trash", role: .destructive) { deleting = conversation } }
        let label = ConversationRow(conversation: conversation, typing: model.typing.contains(conversation.id), side: side(conversation.id))
        return Group {
            if showsCrons {
                #if os(iOS)
                if openBeside != nil { label.conversationDrag(conversation.id, started: dragStarted) } else { label }
                #else
                label
                #endif
            } else {
                Button { selection = conversation.id } label: { label }
                    .foregroundStyle(.primary)
            }
        }
            .tag(Pane.chat(conversation.id))
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                ReadMarkButton(model: model, conversation: conversation)
                if !archived { pin.tint(.orange).disabled(!model.canPatch) }
            }
            .swipeActions(edge: .trailing) {
                delete(String(localized: "Delete")).disabled(!model.canPatch)
                archive.tint(.indigo).disabled(!model.canPatch)
            }
            .contextMenu {
                if let openBeside, side(conversation.id) == nil {
                    Button(String(localized: "Open Beside"), systemImage: "rectangle.split.2x1") { openBeside(conversation.id) }
                    Divider()
                }
                ReadMarkButton(model: model, conversation: conversation)
                Group {
                    if !archived { pin }
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

    private var problem: String? {
        switch model.state {
        case .unpaired: String(localized: "The host removed this device. Pair again to keep chatting.")
        case .updateRequired: String(localized: "The host speaks a newer version. Update Yorozu.")
        default: nil
        }
    }
}

private struct ReadMarkButton: View {
    let model: AppModel
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

private struct ConversationRow: View {
    let conversation: Conversation
    let typing: Bool
    let side: PaneSide?

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
            HStack(alignment: .firstTextBaseline) {
                Text(conversation.displayTitle)
                    .bold(conversation.unreadCount > 0)
                    .lineLimit(1)
                Spacer(minLength: LayoutMetrics.inner)
                Text(Self.time(conversation.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let dot { Image(systemName: "circle.fill").font(.caption2).foregroundStyle(dot) }
                if let side {
                    Image(systemName: side == .left ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel(side == .left ? Text("Open on the left") : Text("Open on the right"))
                }
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

    private static func time(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .omitted)
    }
}

