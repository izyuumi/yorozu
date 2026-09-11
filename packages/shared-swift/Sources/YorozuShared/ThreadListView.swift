import SwiftUI

/// Thread list shared by the Mac and iOS apps: Home pinned at the top, `+` creates a thread
/// with an optional title, a swipe archives anything but Home. Archived threads leave the
/// list. It owns the navigation stack, so `destination` is the chat view to push.
public struct ThreadListView<Destination: View>: View {
    private let threads: [ThreadSummary]
    private let onCreate: (String) -> Void
    private let onArchive: (ThreadSummary) -> Void
    private let destination: (ThreadSummary) -> Destination

    @State private var title = ""
    @State private var naming = false

    public init(
        threads: [ThreadSummary],
        onCreate: @escaping (String) -> Void,
        onArchive: @escaping (ThreadSummary) -> Void,
        @ViewBuilder destination: @escaping (ThreadSummary) -> Destination
    ) {
        self.threads = threads
        self.onCreate = onCreate
        self.onArchive = onArchive
        self.destination = destination
    }

    /// Pinned first, the rest in the order the Mac sent them; archived threads are not shown.
    private var visible: [ThreadSummary] {
        let live = threads.filter { !$0.archived }
        return live.filter(\.pinned) + live.filter { !$0.pinned }
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(visible, id: \.id) { thread in
                    NavigationLink {
                        destination(thread)
                    } label: {
                        Label(
                            thread.title,
                            systemImage: thread.pinned ? "house" : "bubble.left.and.bubble.right"
                        )
                    }
                    .swipeActions {
                        if !thread.pinned {
                            Button("Archive", systemImage: "archivebox", role: .destructive) {
                                onArchive(thread)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Threads")
            .toolbar {
                Button("New thread", systemImage: "plus") { naming = true }
            }
            .alert("New thread", isPresented: $naming) {
                TextField("Title (optional)", text: $title)
                Button("Create") {
                    onCreate(title)
                    title = ""
                }
                Button("Cancel", role: .cancel) { title = "" }
            }
        }
    }
}
