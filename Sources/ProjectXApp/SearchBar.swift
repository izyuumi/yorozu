import SwiftUI
import AppKit
import ProjectXCore

/// ⌘F search over the main timeline. Hits come from `Engine.search`, newest first, and keep only messages on the main
/// timeline (open question 10). The current hit starts at the newest, so Return steps up to older ones.
@MainActor final class ChatSearch: ObservableObject {
    @Published var shown = false
    @Published var query = ""
    /// Message ids of the hits, oldest first, as they sit on screen.
    @Published private(set) var hits: [String] = []
    @Published private(set) var index = 0
    @Published private(set) var searching = false
    @Published private(set) var failure: String?
    var current: String? { hits.indices.contains(index) ? hits[index] : nil }
    /// The newest 500 hits are plenty for a chat; older ones would page in with `offset`.
    private static let limit = 500

    func run(_ model: AppModel,timeline: Set<String>) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { hits = []; failure = nil; return }
        searching = true; defer { searching = false }
        do {
            let found = try await model.search(query,limit: Self.limit).hits
            guard !Task.isCancelled else { return }
            hits = found.compactMap(\.messageID).filter(timeline.contains).reversed()
            index = hits.count - 1; failure = nil
        } catch { if !Task.isCancelled { hits = []; failure = error.localizedDescription } }
    }
    /// -1 for the older hit above, +1 for the newer one below; wraps around.
    func step(_ direction: Int) {
        guard !hits.isEmpty else { return }
        index = (index + direction + hits.count) % hits.count
    }
    func close() { shown = false; query = ""; hits = []; failure = nil }
}

/// The search field with its "n of N" count, previous and next, and Done (approved design).
struct SearchBar: View {
    @ObservedObject var search: ChatSearch
    @FocusState private var focused: Bool
    private enum Metrics { static let fieldRadius: CGFloat = 8, stepperRadius: CGFloat = 7 }
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search",text: $search.query).textFieldStyle(.plain).focused($focused)
                    .onSubmit { search.step(NSEvent.modifierFlags.contains(.shift) ? 1 : -1) }
                    .onExitCommand { search.close() }
                Text(count).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .help(search.failure ?? "")
            }
            .padding(.horizontal,8).padding(.vertical,5)
            .background(.background,in: RoundedRectangle(cornerRadius: Metrics.fieldRadius,style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Metrics.fieldRadius,style: .continuous).strokeBorder(.separator,lineWidth: 0.5) }
            ControlGroup {
                Button { search.step(-1) } label: { Image(systemName: "chevron.up") }.help("Previous match").accessibilityLabel("Previous match")
                Button { search.step(1) } label: { Image(systemName: "chevron.down") }.help("Next match").accessibilityLabel("Next match")
            }.fixedSize().disabled(search.hits.count < 2)
            Button("Done") { search.close() }
        }
        .controlSize(.small)
        .onAppear { focused = true }
    }
    private var count: String {
        if search.query.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if search.failure != nil { return String(localized: "Search failed") }
        if search.hits.isEmpty { return search.searching ? "" : String(localized: "No matches") }
        return String(localized: "\(search.index + 1) of \(search.hits.count)")
    }
}
