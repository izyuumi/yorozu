import SwiftUI
import YorozuWire

/// The conversation list beside the open conversation: a sidebar on iPad and Mac, a stack on iPhone (the split view
/// collapses by itself). "+" opens a new `convId`, which joins the list with its first message.
struct ConversationsView: View {
    let model: V3Model

    @State private var selection: String?
    @State private var showingHost = false

    var body: some View {
        NavigationSplitView {
            list
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: LayoutMetrics.sidebarMinWidth, ideal: LayoutMetrics.sidebarIdealWidth,
                    max: LayoutMetrics.sidebarMaxWidth)
                #endif
        } detail: {
            if let selection {
                V3ChatView(model: model, convId: selection).id(selection)
            } else {
                ContentUnavailableView("No conversation selected", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .sheet(isPresented: $showingHost) { HostSheet(model: model) }
    }

    private var list: some View {
        let conversations = model.list
        return List(selection: $selection) {
            if let problem {
                Section {
                    Label { Text(problem) } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(YorozuPalette.warning)
                    }
                    Button(String(localized: "Pair Again")) { model.unpair() }
                }
            }
            ForEach(conversations) { conversation in
                ConversationRow(conversation: conversation, typing: model.typing.contains(conversation.id))
                    .tag(conversation.id)
            }
        }
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView("No conversations yet", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Start one with +."))
            }
        }
        .navigationTitle("Chats")
        .navigationSubtitleIfAvailable(model.state.label)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(String(localized: "Host"), systemImage: "info.circle") { showingHost = true }
                    .help(String(localized: "Host"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "New Conversation"), systemImage: "plus") { selection = V3Event.newId() }
                    .keyboardShortcut("n")
                    .help(String(localized: "New Conversation"))
                    .accessibilityIdentifier("conversations.new")
            }
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

/// The first message stands for the title until titles land (#428); the latest message below it.
private struct ConversationRow: View {
    let conversation: Conversation
    let typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
            HStack(alignment: .firstTextBaseline) {
                Text(conversation.preview.isEmpty ? String(localized: "New Conversation") : conversation.preview)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: LayoutMetrics.inner)
                Text(Self.time(conversation.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    /// The time today, the date on any other day.
    private static func time(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The paired host: its key, the relay, the link state, and Unpair.
private struct HostSheet: View {
    let model: V3Model
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(String(localized: "Host key"), value: model.fingerprint ?? "")
                    LabeledContent(String(localized: "Relay"), value: model.pairing.flatMap { URL(string: $0.pairing.relayUrl)?.host() } ?? "")
                    LabeledContent(String(localized: "Status"), value: model.state.label)
                    if let at = model.pairing?.pairedAt {
                        LabeledContent(String(localized: "Paired"), value: at.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section {
                    Button(String(localized: "Unpair This Device"), role: .destructive) { confirming = true }
                } footer: {
                    Text("Removes the keys and cached conversations from this device. On the host, `openclaw yorozu devices remove` removes it there.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } }
            }
            .confirmationDialog(String(localized: "Unpair this device?"), isPresented: $confirming, titleVisibility: .visible) {
                Button(String(localized: "Unpair"), role: .destructive) {
                    dismiss()
                    model.unpair()
                }
            }
        }
    }
}
