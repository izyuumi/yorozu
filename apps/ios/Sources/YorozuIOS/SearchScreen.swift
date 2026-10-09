import SwiftUI
import YorozuWire

/// Where the chat's navigation stack can go.
enum ChatRoute: Hashable {
    case topics
    /// The job list (#319), while the Mac takes `jobs-v1`.
    case jobs
    /// `focus`: a message or task to scroll to.
    case topic(String, focus: String?)
    case search
    /// The Mac's page around a message outside the cache.
    case page(String)
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

/// Search over the Mac's full history: scopes on top, hits with snippets, the field at the bottom.
struct SearchScreen: View {
    let model: PhoneModel
    let onOpen: (SearchHitData) -> Void
    let onClose: () -> Void

    private enum Scope: Hashable { case all, main, subChats }

    @State private var query = ""
    @State private var scope = Scope.all
    @FocusState private var focused: Bool
    /// The query and link the held results answer: returning from a hit does not search again.
    @State private var searched: String?
    @State private var appeared = false
    /// Pages fetched on their own for a query and scope with too few hits; then "Load more" takes over.
    @State private var autoPages = (key: "", count: 0)

    /// A scope shows at least this many hits before it stops fetching pages on its own.
    private static let scopedFill = 20
    private static let autoPageLimit = 5

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var paired: Bool { model.state == .paired }
    private var autoKey: String { "\(trimmed)|\(scope)" }
    private var autoCount: Int { autoPages.key == autoKey ? autoPages.count : 0 }

    /// A scope still fills itself from the next pages: the Mac's pages are unscoped, so one can add nothing.
    private func autoFilling(_ hits: [SearchHitData]) -> Bool {
        scope != .all && model.search?.nextOffset != nil && hits.count < Self.scopedFill && autoCount < Self.autoPageLimit
    }

    var body: some View {
        let result = model.search
        let hits = (result?.hits ?? []).filter {
            switch scope {
            case .all: true
            case .main: $0.topicId == nil
            case .subChats: $0.topicId != nil
            }
        }
        List {
            Section {
                Picker("Scope", selection: $scope) {
                    Text("All").tag(Scope.all)
                    Text("Main").tag(Scope.main)
                    Text("Activities").tag(Scope.subChats)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            if paired, !trimmed.isEmpty, let result, result.error == nil, !hits.isEmpty || (scope != .all && result.nextOffset != nil) {
                Section {
                    ForEach(Array(hits.enumerated()), id: \.offset) { index, hit in
                        row(hit)
                            .onAppear {
                                // The last hit asks for the next page.
                                guard index == hits.count - 1, let next = result.nextOffset else { return }
                                Task { await model.search(trimmed, offset: next) }
                            }
                    }
                    // Scrolling to the last hit cannot ask again when a page added none: the user asks.
                    if scope != .all, let next = result.nextOffset, !autoFilling(hits) {
                        Button("Load more") { Task { await model.search(trimmed, offset: next) } }
                    }
                } header: {
                    // The Mac counts every scope; a scope counts only what has loaded.
                    if scope == .all {
                        Text("\(result.total) results")
                    } else if result.nextOffset != nil {
                        Text("\(hits.count) loaded")
                    } else {
                        Text("\(hits.count) results")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { placeholder(result, hits) }
        // Typing searches after a short pause; a new link searches again. Unchanged held results stay.
        .task(id: "\(trimmed)|\(paired)") {
            let key = "\(trimmed)|\(paired)"
            guard paired, !trimmed.isEmpty else { searched = nil; return }
            guard key != searched || model.search == nil else { return }
            guard (try? await Task.sleep(for: .milliseconds(350))) != nil else { return }
            autoPages = ("", 0)
            searched = key
            await model.search(trimmed)
        }
        // A scope with too few hits fetches the next pages itself, up to a bound.
        .task(id: "\(autoKey)|\(result?.hits.count ?? -1)|\(result?.nextOffset ?? -1)") {
            // Only for the held query: while typing, the results still answer the previous one.
            guard paired, searched == "\(trimmed)|\(paired)", result?.error == nil, let next = result?.nextOffset,
                  autoFilling(hits) else { return }
            autoPages = (autoKey, autoCount + 1)
            await model.search(trimmed, offset: next)
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            focused = true
        }
        .yorozuBottomBar { field }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
    }

    @ViewBuilder
    private func placeholder(_ result: SearchResultData?, _ hits: [SearchHitData]) -> some View {
        if !paired {
            ContentUnavailableView("Search needs the host", systemImage: "wifi.slash",
                                   description: Text("The host runs the search. Connect to it to search."))
        } else if trimmed.isEmpty {
            ContentUnavailableView("Search everything", systemImage: "magnifyingglass",
                                   description: Text("The main chat and every activity, on the host."))
        } else if let error = result?.error {
            ContentUnavailableView("Couldn't search", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if result == nil {
            ProgressView()
        } else if hits.isEmpty, result?.nextOffset != nil, scope != .all {
            // Still filling the scope; past the bound, "Load more" shows instead.
            if autoFilling(hits) { ProgressView() }
        } else if hits.isEmpty {
            ContentUnavailableView.search(text: trimmed)
        }
    }

    private func row(_ hit: SearchHitData) -> some View {
        let target = model.target(of: hit)
        let source = hit.topicId.map { model.topics[$0]?.label ?? String(localized: "Activity") } ?? String(localized: "Main")
        return Button { onOpen(hit) } label: {
            VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                HStack {
                    Text(verbatim: source)
                        .fontWeight(.semibold)
                        .foregroundStyle(hit.topicId == nil ? Color.secondary : YorozuPalette.vermilion)
                        .lineLimit(1)
                    Spacer()
                    Text(verbatim: MessageTime.day.string(from: MessageTime.date(hit.created)))
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                Text(highlighted(hit.snippet))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                if case .none = target {
                    Text("Older than this device keeps. Open it on the host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled({ if case .none = target { true } else { false } }())
    }

    /// The query's words marked in the snippet (the Mac's snippets carry no markers).
    private func highlighted(_ snippet: String) -> AttributedString {
        var text = AttributedString(snippet)
        for word in trimmed.split(whereSeparator: \.isWhitespace) {
            let word = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"*"))
            guard !word.isEmpty else { continue }
            var from = text.startIndex
            while from < text.endIndex, let range = text[from...].range(of: word, options: .caseInsensitive) {
                text[range].backgroundColor = Color.yellow.opacity(0.4)
                from = range.upperBound
            }
        }
        return text
    }

    private var field: some View {
        HStack(spacing: LayoutMetrics.inner) {
            HStack(spacing: LayoutMetrics.inner) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, LayoutMetrics.gutter)
            .frame(minHeight: controlTarget)
            .yorozuGlass(in: Capsule())
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: controlTarget, height: controlTarget)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .yorozuGlass(in: Circle())
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, LayoutMetrics.stack)
        .padding(.vertical, LayoutMetrics.inner)
        .frame(maxWidth: LayoutMetrics.composerWidth)
        .frame(maxWidth: .infinity)
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
