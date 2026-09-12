import SwiftUI

/// Most recently active first; archived threads are not shown. Both thread lists order
/// themselves with it, and an unsent draft leads because its activity is the moment it was made.
public func visibleThreads(_ threads: [ThreadSummary]) -> [ThreadSummary] {
    threads.filter { !$0.archived }.sorted { $0.lastActivity > $1.lastActivity }
}

/// How stale the newest thread may be and still be the one an app opens itself.
public let openWindow: TimeInterval = 2 * 60 * 60

/// Which thread to open on launch, or on coming back to the foreground: the most recent one
/// while it is still warm, and `nil` — meaning start a fresh draft — once it has gone cold.
///
/// Pure, so both apps decide the same way and a test can move `now` rather than the clock.
public func threadToOpen(
    _ threads: [ThreadSummary],
    now: Date = Date(),
    within: TimeInterval = openWindow
) -> String? {
    guard let newest = visibleThreads(threads).first,
        now.timeIntervalSince1970 - newest.lastActivity / 1000 <= within
    else { return nil }
    return newest.id
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
    Label(thread.displayTitle, systemImage: "bubble.left.and.bubble.right")
    .foregroundStyle(thread.title.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
}

/// The phone's thread list: newest first, `+` starts a fresh draft, and a swipe renames or
/// archives. It owns the navigation stack, so `destination` is the chat view to push and `path`
/// is what lets the app open a thread by itself on launch. The path holds thread ids rather than
/// summaries, so a draft that becomes a real thread mid-push keeps drawing.
///
/// `onSettings` puts a gear beside the `+`. It is a callback rather than a view slot because the
/// bar belongs to the navigation stack this view owns, so a caller cannot reach it from outside;
/// optional because only the phone has a settings screen to open.
///
/// The Mac shows the same threads as a ``ThreadSidebar`` instead, because its chat lives beside
/// the list rather than on top of it.
public struct ThreadListView<Destination: View>: View {
    private let threads: [ThreadSummary]
    @Binding private var path: [String]
    private let onCreate: () -> Void
    private let onRename: (ThreadSummary, String) -> Void
    private let onArchive: (ThreadSummary) -> Void
    private let onSettings: (() -> Void)?
    private let destination: (ThreadSummary) -> Destination

    @State private var renaming: ThreadSummary?

    public init(
        threads: [ThreadSummary],
        path: Binding<[String]>,
        onCreate: @escaping () -> Void,
        onRename: @escaping (ThreadSummary, String) -> Void,
        onArchive: @escaping (ThreadSummary) -> Void,
        onSettings: (() -> Void)? = nil,
        @ViewBuilder destination: @escaping (ThreadSummary) -> Destination
    ) {
        self.threads = threads
        self._path = path
        self.onCreate = onCreate
        self.onRename = onRename
        self.onArchive = onArchive
        self.onSettings = onSettings
        self.destination = destination
    }

    public var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(visibleThreads(threads), id: \.id) { thread in
                    NavigationLink(value: thread.id) {
                        threadLabel(thread)
                    }
                    .swipeActions {
                        Button("Archive", systemImage: "archivebox", role: .destructive) {
                            onArchive(thread)
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
                if let onSettings {
                    Button("Settings", systemImage: "gear", action: onSettings)
                }
            }
            .navigationDestination(for: String.self) { id in
                if let thread = threads.first(where: { $0.id == id }) {
                    destination(thread)
                }
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
                        Button("Archive", systemImage: "archivebox") { onArchive(thread) }
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
