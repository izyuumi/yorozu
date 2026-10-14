import SwiftUI
import YorozuWire

/// Where the chat's navigation stack can go.
enum ChatRoute: Hashable {
    /// A job's page in Scheduled (#319), by job id.
    case job(String)
    /// `focus`: a message or task to scroll to.
    case topic(String, focus: String?)
    /// The Mac's page around a message outside the cache.
    case page(String)
    /// The main chat as a page over the thread list (owner, 2026-10-14), the archived threads, and New
    /// chat's empty thread with the id its first message creates.
    case main
    case archived
    case newChat(String)
}

/// Where a search hit opens.
enum HitTarget {
    case main(String)
    case topic(String, focus: String?)
    case page(String)
    /// A sub-chat step older than the cache: nothing on the phone to open.
    case none
}

extension PhoneModel {
    func target(of hit: SearchHitData) -> HitTarget {
        let heldMessage = hit.messageId.flatMap { id in bubbles.first { $0.id == id } }
        if let topicId = hit.topicId, topics[topicId] != nil {
            if let id = hit.messageId {
                guard let heldMessage else { return .page(id) }
                // A result the topic hides behind its task card: the card, opened.
                if hidesInTopic(heldMessage), let taskId = heldMessage.taskId { return .topic(topicId, focus: taskId) }
                return .topic(topicId, focus: id)
            }
            return .topic(topicId, focus: hit.taskId.flatMap { tasks[$0] != nil ? $0 : nil })
        }
        if let id = hit.messageId { return heldMessage != nil ? .main(id) : .page(id) }
        return .none
    }
}

/// Search over the history on this device (#405): every chat, archived ones included and marked, offline too. The
/// system's search: the Search tab's field (iPhone's tab bar, the sidebar on iPad) with a scope to leave archived chats out.
struct SearchScreen: View {
    let model: PhoneModel
    let onOpen: (PhoneModel.LocalHit) -> Void

    private enum Scope: Hashable { case all, active }

    @State private var query = ""
    @State private var scope = Scope.all
    @State private var hits: [PhoneModel.LocalHit] = []
    @State private var searched = ""

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let shown = scope == .all ? hits : hits.filter { !$0.archived }
        List {
            if !trimmed.isEmpty, !shown.isEmpty {
                Section {
                    ForEach(shown) { row($0) }
                } header: {
                    Text("\(shown.count) results")
                } footer: {
                    if !model.historySynced { Text("Chat history is still downloading to this device, so some results may be missing.") }
                }
            }
        }
        .listStyle(.plain)
        .overlay { placeholder(shown) }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .automatic, prompt: Text("Search chats"))
        .searchScopes($scope, activation: .onSearchPresentation) {
            Text("All chats").tag(Scope.all)
            Text("Not archived").tag(Scope.active)
        }
        .autocorrectionDisabled()
        // Typing searches after a short pause, on the device: no host needed. Again as the history loads or changes (a
        // chat deleted elsewhere drops out of the results at once).
        .task(id: "\(trimmed)|\(model.historyLoading)|\(model.deletedThreads.count)|\(model.bubbles.count)") {
            guard !trimmed.isEmpty else { hits = []; searched = ""; return }
            guard (try? await Task.sleep(for: .milliseconds(200))) != nil else { return }
            hits = model.searchLocal(trimmed)
            searched = trimmed
        }
    }

    @ViewBuilder
    private func placeholder(_ shown: [PhoneModel.LocalHit]) -> some View {
        if trimmed.isEmpty {
            ContentUnavailableView("Search your chats", systemImage: "magnifyingglass",
                                   description: Text("Every chat on this device, archived ones too, even offline."))
        } else if searched == trimmed && shown.isEmpty {
            ContentUnavailableView.search(text: trimmed)
        }
    }

    private func row(_ hit: PhoneModel.LocalHit) -> some View {
        let place = hit.threadId ?? hit.topicId
        let source = place.flatMap { model.threadName($0) } ?? (hit.threadId == nil && hit.topicId == nil ? String(localized: "Main chat") : String(localized: "Chat"))
        return Button { onOpen(hit) } label: {
            VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                HStack {
                    Text(verbatim: source).fontWeight(.semibold).lineLimit(1)
                    if hit.archived {
                        Text("Archived")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, LayoutMetrics.inner)
                            .background(.fill.tertiary, in: Capsule())
                    }
                    Spacer()
                    Text(verbatim: ChatTime.label(hit.ts)).foregroundStyle(.secondary)
                }
                .font(.footnote)
                Text(highlighted(hit.snippet))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            .accessibilityElement(children: .combine)
        }
        .foregroundStyle(.primary)
    }

    /// The query's words marked in the snippet.
    private func highlighted(_ snippet: String) -> AttributedString {
        var text = AttributedString(snippet)
        for word in trimmed.split(whereSeparator: \.isWhitespace) {
            let word = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"*"))
            guard !word.isEmpty else { continue }
            var from = text.startIndex
            while from < text.endIndex, let range = text[from...].range(of: word, options: .caseInsensitive) {
                text[range].inlinePresentationIntent = .stronglyEmphasized
                from = range.upperBound
            }
        }
        return text
    }
}

/// A search hit outside the cache: the Mac's page around it, for reading only.
struct PageScreen: View {
    let model: PhoneModel
    let messageId: String

    @State private var position = ScrollPosition(edge: .top)
    @State private var details: PhoneModel.Bubble?

    var body: some View {
        let reply = model.page?.messageId == messageId ? model.page : nil
        let bubbles = reply?.bubbles ?? []
        let paired = model.state == .paired
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                ForEach(bubbles) { bubble in
                    MessageRow(bubble: bubble, header: nil, onShowRequest: {}, onShowDetails: { details = bubble })
                        .padding(bubble.id == messageId ? LayoutMetrics.tight : 0)
                        .background {
                            if bubble.id == messageId {
                                RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous)
                                    .fill(Color.yellow.opacity(0.18))
                            }
                        }
                        .readableRow()
                        .id(bubble.id)
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, LayoutMetrics.gutter)
        }
        .scrollPosition($position)
        .onChange(of: bubbles.count, initial: true) { _, count in
            if count > 0 { position.scrollTo(id: messageId, anchor: .center) }
        }
        // Asks on opening, and again when a request that did not go left no page. A request the relay
        // dropped is asked again by `PhoneModel` on the next `.paired`.
        .task(id: paired) {
            if paired, model.page?.messageId != messageId { await model.loadPage(around: messageId) }
        }
        .overlay {
            if let error = reply?.error {
                ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if bubbles.isEmpty && !paired {
                ContentUnavailableView("Search needs the host", systemImage: "wifi.slash",
                                       description: Text("The host runs the search. Connect to it to search."))
            } else if bubbles.isEmpty {
                ProgressView()
            }
        }
        .navigationTitle("In context")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $details) { MessageDetails(bubble: $0) }
    }
}
