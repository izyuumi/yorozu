import AppKit
import SwiftUI
import YorozuShared

/// The chat's own commands in the menu bar, where a Mac looks for them: ⌘N for a thread, ⌘F to
/// search one, ⇧⌘E to export it, ⌘. to stop a turn, and the per-thread model as a submenu.
/// ⇧⌘E rather than ⌘E, which the system reserves for Use Selection for Find.
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
        // One app menu rather than two with an item or two each: everything here acts on the
        // open thread, and a menu is where a Mac keeps commands it has to be able to find again.
        CommandMenu("Thread") {
            Button("Stop") { chat?.stop?() }
                .keyboardShortcut(".")
                .disabled(chat?.stop == nil)
            Menu("Model") { models }
                .disabled(chat?.models.isEmpty != false)
            Divider()
            Button("Export as Markdown…") { export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(chat == nil)
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

struct HostQuitCommands: Commands {
    let backgroundOnly: Bool

    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            if backgroundOnly {
                Button("Close Yorozu Windows") { AppDelegate.closeWindows() }
                    .keyboardShortcut("q")
            } else {
                Button("Quit Yorozu") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
    }
}

/// Host-only presentation preference. A client Mac never enters this mode even if it was
/// previously a host; switching back to host restores the saved choice.
enum HostWindowMode {
    static let key = "backgroundOnlyHost"
    static let updateRelaunchKey = "backgroundOnlyUpdateRelaunch"

    static func active(role: MacRole?, enabled: Bool) -> Bool { role == .host && enabled }

    @MainActor static var active: Bool {
        active(role: MacChatSession.shared.role, enabled: UserDefaults.standard.bool(forKey: key))
    }

    @MainActor static var openQuickChat: (() -> Void)?
    @MainActor static var pendingExplicitOpen = false

    @MainActor static func requestQuickChat() {
        guard active else { return }
        if let openQuickChat { openQuickChat() }
        else { pendingExplicitOpen = true }
    }

    @MainActor static func routeQuickChat(threadID: String, eventID: String?, kind: MacAttentionKind?) {
        guard MacChatSession.shared.role == .host else { return }
        QuickChatRouter.shared.target = QuickChatTarget(threadID: threadID, eventID: eventID, kind: kind)
        if let openQuickChat { openQuickChat() }
        else { pendingExplicitOpen = true }
    }
}

struct QuickChatTarget: Identifiable {
    let id = UUID()
    let threadID: String
    let eventID: String?
    let kind: MacAttentionKind?
}

enum MacAttentionKind: String {
    case answer, approval, question, failure
}

@MainActor @Observable
final class QuickChatRouter {
    static let shared = QuickChatRouter()
    var target: QuickChatTarget?
}

/// Whether the full chat window is open, which decides the normal app's activation policy.
///
/// The app is an `LSUIElement` agent, so it launches with no Dock icon and no menu bar — and a
/// menu bar is where the commands above have to appear. While the chat window is up the app is
/// an ordinary one; when it closes it goes back to being just the status item.
@MainActor
enum WindowPresence {
    private static var open = 0

    /// Whether anything is on screen that a relaunch would interrupt. Read by the updater
    /// before it installs — see ``UpdaterDelegate``.
    static var isOpen: Bool { open > 0 }

    static func opened() {
        open += 1
        NSApp.setActivationPolicy(HostWindowMode.active ? .accessory : .regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closed() {
        open -= 1
        guard open <= 0 else { return }
        open = 0
        NSApp.setActivationPolicy(.accessory)
    }

    static func modeChanged() {
        NSApp.setActivationPolicy(HostWindowMode.active || !isOpen ? .accessory : .regular)
    }
}
