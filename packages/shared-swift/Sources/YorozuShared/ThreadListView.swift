import SwiftUI

/// Pinned first, the rest in the order the runtime sent them; archived threads are not shown.
/// Both thread lists order themselves with it.
public func visibleThreads(_ threads: [ThreadSummary]) -> [ThreadSummary] {
    let live = threads.filter { !$0.archived }
    return live.filter(\.pinned) + live.filter { !$0.pinned }
}

/// `+` and the sheet behind it, shared by both lists: a thread may be created unnamed, and the
/// runtime titles it.
public struct NewThreadButton: View {
    private let onCreate: (String) -> Void

    @State private var title = ""
    @State private var naming = false

    public init(onCreate: @escaping (String) -> Void) {
        self.onCreate = onCreate
    }

    public var body: some View {
        Button("New thread", systemImage: "plus") { naming = true }
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

/// The phone's thread list: Home pinned at the top, `+` creates a thread with an optional
/// title, a swipe archives anything but Home. It owns the navigation stack, so `destination` is
/// the chat view to push. The Mac shows the same threads as a ``ThreadSidebar`` instead, because
/// its chat lives beside the list rather than on top of it.
public struct ThreadListView<Destination: View>: View {
    private let threads: [ThreadSummary]
    private let onCreate: (String) -> Void
    private let onArchive: (ThreadSummary) -> Void
    private let destination: (ThreadSummary) -> Destination

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

    public var body: some View {
        NavigationStack {
            List {
                ForEach(visibleThreads(threads), id: \.id) { thread in
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
            .toolbar { NewThreadButton(onCreate: onCreate) }
        }
    }
}

/// The Mac's thread list: the sidebar half of a split view, so picking a thread selects it
/// rather than pushing it. Same ordering, same `+`, and archive from the row's context menu
/// because there is nothing to swipe with a mouse.
public struct ThreadSidebar: View {
    private let threads: [ThreadSummary]
    @Binding private var selection: String?
    private let onCreate: (String) -> Void
    private let onArchive: (ThreadSummary) -> Void

    public init(
        threads: [ThreadSummary],
        selection: Binding<String?>,
        onCreate: @escaping (String) -> Void,
        onArchive: @escaping (ThreadSummary) -> Void
    ) {
        self.threads = threads
        self._selection = selection
        self.onCreate = onCreate
        self.onArchive = onArchive
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(visibleThreads(threads), id: \.id) { thread in
                Label(
                    thread.title,
                    systemImage: thread.pinned ? "house" : "bubble.left.and.bubble.right"
                )
                .tag(thread.id)
                .contextMenu {
                    if !thread.pinned {
                        Button("Archive", systemImage: "archivebox") { onArchive(thread) }
                    }
                }
            }
        }
        .navigationTitle("Threads")
        .toolbar { NewThreadButton(onCreate: onCreate) }
    }
}
