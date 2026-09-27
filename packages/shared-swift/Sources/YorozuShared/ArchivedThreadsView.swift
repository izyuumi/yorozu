import SwiftUI

/// Archived threads live outside the working list, but retain the same rows and search.
public struct ArchivedThreadsView: View {
    private let threads: [ThreadSummary]
    private let hostLabel: (String) -> String?
    private let messageText: (String) -> String
    private let onOpen: (ThreadSummary) -> Void
    private let onRestore: (ThreadSummary) -> Void
    @State private var query = ""

    public init(model: ChatModel, onOpen: @escaping (String) -> Void) {
        threads = model.threads.filter(\.archived).sorted { $0.lastActivity > $1.lastActivity }
        hostLabel = { _ in nil }
        messageText = { id in
            (model.events[id] ?? []).compactMap {
                if case .message(let data) = $0.payload { return data.text }
                return nil
            }
            .joined(separator: "\n\n")
        }
        self.onOpen = { onOpen($0.id) }
        onRestore = { model.setArchived($0, false) }
    }

    public init(hosts: MultiHostModel, onOpen: @escaping (HostThreadID) -> Void) {
        let adapter = HostThreadListAdapter(session: hosts)
        threads = adapter.threads.filter(\.archived).sorted { $0.lastActivity > $1.lastActivity }
        hostLabel = adapter.hostLabel
        messageText = adapter.messageText
        self.onOpen = { thread in
            if let id = adapter.resolve(thread.id)?.id { onOpen(id) }
        }
        onRestore = { thread in adapter.perform(thread) { $0.setArchived($1, false) } }
    }

    private var shownThreads: [ThreadSummary] {
        threads.filter {
            threadMatches($0, query: query, body: messageText($0.id))
                || !searchRanges(in: hostLabel($0.id) ?? "", term: query).isEmpty
        }
    }

    private var searchNeedle: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var body: some View {
        list
            .overlay { empty }
            .navigationTitle("Archived threads")
            #if os(iOS)
            .searchable(text: $query, prompt: "Search archived threads")
            #else
            .safeAreaInset(edge: .top) {
                VStack(alignment: .leading) {
                    Text("Archived threads").font(.headline)
                    TextField("Search archived threads", text: $query)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(LayoutMetrics.stack)
                .background(YorozuPalette.canvas)
            }
            #endif
    }

    private var list: some View {
        List {
            Section {
                ForEach(shownThreads) { thread in row(thread) }
            } footer: {
                Text("Restored threads return to the thread list.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(YorozuPalette.canvas)
    }

    @ViewBuilder private func row(_ thread: ThreadSummary) -> some View {
        #if os(iOS)
        Button { onOpen(thread) } label: {
            ThreadRow(thread: thread, highlightQuery: query, chevron: true,
                      hostLabel: hostLabel(thread.id), marksArchived: false)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button("Restore", systemImage: "tray.and.arrow.up") { onRestore(thread) }
                .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button("Restore", systemImage: "tray.and.arrow.up") { onRestore(thread) }
                .tint(.blue)
        }
        .contextMenu { restore(thread) }
        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        #else
        HStack {
            Button { onOpen(thread) } label: {
                ThreadRow(thread: thread, highlightQuery: query, hostLabel: hostLabel(thread.id), marksArchived: false)
            }
            .buttonStyle(.plain)
            Button("Restore") { onRestore(thread) }
        }
        .contextMenu { restore(thread) }
        .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        #endif
    }

    private func restore(_ thread: ThreadSummary) -> some View {
        Button("Restore", systemImage: "tray.and.arrow.up") { onRestore(thread) }
    }

    @ViewBuilder private var empty: some View {
        if shownThreads.isEmpty {
            if searchNeedle.isEmpty {
                ContentUnavailableView("No archived threads", systemImage: "archivebox",
                                       description: Text("Threads you archive will be here."))
            } else {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}
