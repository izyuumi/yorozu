import SwiftUI

/// The archive, reached from Settings: what was put away, most recently active first. A row
/// opens its thread as the thread list would, and Restore sends it back to that list.
public struct ArchivedThreadsView: View {
    private struct Archive {
        var threads: [ThreadSummary]
        var hostLabel: (String) -> String? = { _ in nil }
        var messageText: (String) -> String
        var open: (ThreadSummary) -> Void
        var restore: (ThreadSummary) -> Void
    }

    /// Read in `body` rather than at init, so a restore redraws this list whoever presents it.
    private let archive: () -> Archive
    @State private var query = ""

    public init(model: ChatModel, onOpen: @escaping (String) -> Void) {
        archive = {
            Archive(
                threads: model.threads.filter(\.archived).sorted { $0.lastActivity > $1.lastActivity },
                messageText: { id in
                    (model.events[id] ?? []).compactMap {
                        if case .message(let data) = $0.payload { return data.text }
                        return nil
                    }
                    .joined(separator: "\n\n")
                },
                open: { onOpen($0.id) },
                restore: { model.setArchived($0, false) }
            )
        }
    }

    /// Every host's archive in one list, each row labelled with its host when there are several.
    public init(hosts: MultiHostModel, onOpen: @escaping (HostThreadID) -> Void) {
        archive = {
            let adapter = HostThreadListAdapter(session: hosts)
            return Archive(
                threads: adapter.threads.filter(\.archived),
                hostLabel: adapter.hostLabel,
                messageText: adapter.messageText,
                open: { if let id = adapter.resolve($0.id)?.id { onOpen(id) } },
                restore: { thread in adapter.perform(thread) { $0.setArchived($1, false) } }
            )
        }
    }

    public var body: some View {
        let archive = archive()
        let shown = archive.threads.filter {
            threadMatches($0, query: query, body: archive.messageText($0.id))
                || !searchRanges(in: archive.hostLabel($0.id) ?? "", term: query).isEmpty
        }
        List {
            Section {
                ForEach(shown) { row($0, in: archive) }
            } footer: {
                if !shown.isEmpty {
                    Text("Restored threads return to the thread list.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(YorozuPalette.canvas)
        .overlay { if shown.isEmpty { empty } }
        .navigationTitle("Archived threads")
        #if os(iOS)
            .searchable(text: $query, prompt: "Search archived threads")
        #else
            // A sheet on the Mac has no toolbar for a search field or a title to sit in.
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

    @ViewBuilder private func row(_ thread: ThreadSummary, in archive: Archive) -> some View {
        let restore = Button("Restore", systemImage: "tray.and.arrow.up") { archive.restore(thread) }
        #if os(iOS)
            Button { archive.open(thread) } label: { label(thread, in: archive, chevron: true) }
                .buttonStyle(.plain)
            .swipeActions(edge: .leading) { restore.tint(.blue) }
            .swipeActions(edge: .trailing) { restore.tint(.blue) }
            .contextMenu { restore }
            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        #else
            HStack {
                Button { archive.open(thread) } label: { label(thread, in: archive) }
                    .buttonStyle(.plain)
                Button("Restore") { archive.restore(thread) }
            }
            .contextMenu { restore }
            // The plain Mac list already supplies 8 points around its row content.
            .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        #endif
    }

    private func label(_ thread: ThreadSummary, in archive: Archive, chevron: Bool = false) -> ThreadRow {
        ThreadRow(thread: thread, highlightQuery: query, chevron: chevron,
                  hostLabel: archive.hostLabel(thread.id), marksArchived: false)
    }

    @ViewBuilder private var empty: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView("No archived threads", systemImage: "archivebox",
                                   description: Text("Threads you archive will be here."))
        } else {
            ContentUnavailableView.search(text: query)
        }
    }
}
