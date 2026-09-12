import AppKit
import SwiftUI
import YorozuShared

/// The chat's own commands in the menu bar, where a Mac looks for them: ⌘N for a thread, ⌘F to
/// search one, ⌘E to export it, ⌘. to stop a turn, and the per-thread model as a submenu.
///
/// Every item acts on whatever the chat window is showing, which the views publish as
/// ``ChatCommands`` and ``ThreadCommands``. An action that is not available right now arrives
/// nil and its item draws disabled, so the menu never offers something that would do nothing.
struct ChatMenus: Commands {
    @FocusedValue(\.chatCommands) private var chat
    @FocusedValue(\.threadCommands) private var threads

    var body: some Commands {
        // Replaces the whole New group: an app with one kind of document has one New.
        CommandGroup(replacing: .newItem) {
            Button("New Thread") { threads?.newThread() }
                .keyboardShortcut("n")
                .disabled(threads == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Thread") { chat?.find() }
                .keyboardShortcut("f")
                .disabled(chat == nil)
        }
        CommandMenu("Thread") {
            Button("Export as Markdown…") { export() }
                .keyboardShortcut("e")
                .disabled(chat == nil)
            Menu("Model") { models }
                .disabled(chat?.models.isEmpty != false)
        }
        CommandMenu("Chat") {
            Button("Stop") { chat?.stop?() }
                .keyboardShortcut(".")
                .disabled(chat?.stop == nil)
        }
    }

    /// Default, then every spec the runtime published, with a tick against the one in force —
    /// the same choices the chat's own "…" menu offers, from the same ``ChatCommands``.
    @ViewBuilder private var models: some View {
        if let chat {
            Picker(
                "Model",
                selection: Binding(get: { chat.model }, set: { chat.setModel($0) })
            ) {
                Text("Default").tag(String?.none)
                ForEach(chat.models) { option in
                    Text(option.menuLabel).tag(String?.some(option.id))
                }
            }
            .pickerStyle(.inline)
        }
    }

    /// The same share picker `ShareLink` puts behind the chat's own Export, driven directly:
    /// a `ShareLink` in a menu bar command has no view to anchor its popover to, and the key
    /// window's content view is the anchor a menu-driven share wants anyway.
    private func export() {
        guard let chat, let view = NSApp.keyWindow?.contentView else { return }
        let markdown = ThreadMarkdown(title: chat.exportTitle, text: chat.exportMarkdown())
        let url = URL.temporaryDirectory.appending(path: markdown.filename)
        guard (try? Data(markdown.text.utf8).write(to: url, options: .atomic)) != nil else { return }
        NSSharingServicePicker(items: [url]).show(
            relativeTo: .zero,
            of: view,
            preferredEdge: .minY
        )
    }
}

/// Whether the chat window is open, which is what decides the app's activation policy.
///
/// The app is an `LSUIElement` agent, so it launches with no Dock icon and no menu bar — and a
/// menu bar is where the commands above have to appear. While the chat window is up the app is
/// an ordinary one; when it closes it goes back to being just the status item.
@MainActor
enum WindowPresence {
    private static var open = 0

    static func opened() {
        open += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closed() {
        open -= 1
        guard open <= 0 else { return }
        open = 0
        NSApp.setActivationPolicy(.accessory)
    }
}
