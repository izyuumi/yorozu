import SwiftUI

/// Pinned first, the rest in the order the runtime sent them; archived threads are not shown.
/// Both thread lists order themselves with it.
public func visibleThreads(_ threads: [ThreadSummary]) -> [ThreadSummary] {
    let live = threads.filter { !$0.archived }
    return live.filter(\.pinned) + live.filter { !$0.pinned }
}

/// The rename prompt both lists put behind their Rename action. Binding the thread rather than a
/// flag is what carries which row was picked; the field is seeded with the title it has now.
private struct RenameAlert: ViewModifier {
    @Binding var thread: ThreadSummary?
    let onRename: (ThreadSummary, String) -> Void

    @State private var title = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: thread) { _, picked in title = picked?.title ?? "" }
            .alert(
                "Rename thread",
                isPresented: Binding(get: { thread != nil }, set: { if !$0 { thread = nil } }),
                presenting: thread
            ) { picked in
                TextField("Title", text: $title)
                Button("Rename") { onRename(picked, title) }
                Button("Cancel", role: .cancel) {}
            }
    }
}

extension View {
    fileprivate func renameAlert(
        _ thread: Binding<ThreadSummary?>,
        onRename: @escaping (ThreadSummary, String) -> Void
    ) -> some View {
        modifier(RenameAlert(thread: thread, onRename: onRename))
    }
}

/// The row both lists draw: the thread's title, or the placeholder it wears until the runtime
/// has named it.
private func threadLabel(_ thread: ThreadSummary) -> some View {
    Label(
        thread.displayTitle,
        systemImage: thread.pinned ? "house" : "bubble.left.and.bubble.right"
    )
    .foregroundStyle(thread.title.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
}

/// The phone's thread list: Home pinned at the top, `+` creates an unnamed thread the runtime
/// titles from its first reply, and a swipe renames or archives anything but Home. It owns the
/// navigation stack, so `destination` is the chat view to push. The Mac shows the same threads as
/// a ``ThreadSidebar`` instead, because its chat lives beside the list rather than on top of it.
public struct ThreadListView<Destination: View>: View {
    private let threads: [ThreadSummary]
    private let onCreate: () -> Void
    private let onRename: (ThreadSummary, String) -> Void
    private let onArchive: (ThreadSummary) -> Void
    private let destination: (ThreadSummary) -> Destination

    @State private var renaming: ThreadSummary?

    public init(
        threads: [ThreadSummary],
        onCreate: @escaping () -> Void,
        onRename: @escaping (ThreadSummary, String) -> Void,
        onArchive: @escaping (ThreadSummary) -> Void,
        @ViewBuilder destination: @escaping (ThreadSummary) -> Destination
    ) {
        self.threads = threads
        self.onCreate = onCreate
        self.onRename = onRename
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
                        threadLabel(thread)
                    }
                    .swipeActions {
                        if !thread.pinned {
                            Button("Archive", systemImage: "archivebox", role: .destructive) {
                                onArchive(thread)
                            }
                        }
                        Button("Rename", systemImage: "pencil") { renaming = thread }
                    }
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { renaming = thread }
                    }
                }
            }
            .navigationTitle("Threads")
            .toolbar {
                Button("New thread", systemImage: "plus", action: onCreate)
            }
        }
        .renameAlert($renaming, onRename: onRename)
    }
}

/// The Mac's thread list: the sidebar half of a split view, so picking a thread selects it
/// rather than pushing it. Same ordering, same `+`, and rename and archive from the row's context
/// menu because there is nothing to swipe with a mouse.
public struct ThreadSidebar: View {
    private let threads: [ThreadSummary]
    @Binding private var selection: String?
    private let onCreate: () -> Void
    private let onRename: (ThreadSummary, String) -> Void
    private let onArchive: (ThreadSummary) -> Void

    @State private var renaming: ThreadSummary?

    public init(
        threads: [ThreadSummary],
        selection: Binding<String?>,
        onCreate: @escaping () -> Void,
        onRename: @escaping (ThreadSummary, String) -> Void,
        onArchive: @escaping (ThreadSummary) -> Void
    ) {
        self.threads = threads
        self._selection = selection
        self.onCreate = onCreate
        self.onRename = onRename
        self.onArchive = onArchive
    }

    public var body: some View {
        List(selection: $selection) {
            ForEach(visibleThreads(threads), id: \.id) { thread in
                threadLabel(thread)
                    .tag(thread.id)
                    .contextMenu {
                        Button("Rename", systemImage: "pencil") { renaming = thread }
                        if !thread.pinned {
                            Button("Archive", systemImage: "archivebox") { onArchive(thread) }
                        }
                    }
            }
        }
        .navigationTitle("Threads")
        .toolbar {
            Button("New thread", systemImage: "plus", action: onCreate)
        }
        .renameAlert($renaming, onRename: onRename)
    }
}
