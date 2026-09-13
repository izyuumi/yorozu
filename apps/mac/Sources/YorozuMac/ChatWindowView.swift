import AppKit
import SwiftUI
import YorozuShared

/// The chat window: threads on the left, the chat on the right, and everything that is not
/// chat behind the gear. The detail half has its own `NavigationStack`, which is what the
/// subagent drill-down and the trace pages push onto.
///
/// A real window rather than the menu bar popover this used to be. A `MenuBarExtra` window has
/// no toolbar to put the thread's own controls in, cannot be resized, closes itself the moment
/// a share picker or a reader sheet takes focus, and gives the app no menu bar to hang ⌘N, ⌘F
/// or Stop off — so on the Mac half of the chat's features were simply unreachable. See
/// ``YorozuMacApp``, where the menu bar item is now the way to this window rather than the
/// place the chat lives.
struct ChatWindowView: View {
    @State private var selection: String?
    /// `.key` is this window being the key window of the active app, which is exactly the Mac's
    /// half of "somebody is looking at this": `.active` is a window in the active app that is
    /// not key, and `.inactive` is the whole app sitting behind something else.
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var sidecar = Sidecar.shared

    private var model: ChatModel { LocalChat.model }

    /// Falls back to the first thread, so archiving the selected one leaves a chat on screen.
    private var thread: ThreadSummary? {
        model.threads.first { $0.id == selection } ?? visibleThreads(model.threads).first
    }

    /// Opening the window is this app's "came back to the foreground": carry on with the most
    /// recent thread while it is still warm, and start a fresh draft once it is not. The first
    /// open of a launch happens before the sidecar has answered, so it waits for the list.
    private func open() {
        selection = threadToOpen(model.threads) ?? model.newDraft().id
    }

    var body: some View {
        NavigationSplitView {
            ThreadSidebar(
                threads: model.threads,
                selection: $selection,
                onCreate: { selection = model.newDraft().id },
                onRename: { model.rename($0, to: $1) },
                onArchive: model.setArchived,
                onPin: model.setPinned,
                onRead: { thread, read in
                    read ? model.markRead(thread.id) : model.markUnread(thread)
                },
                // Search reaches into this Mac's own thread logs, which is every word of them.
                messageText: { id in
                    (model.events[id] ?? []).compactMap {
                        if case .message(let data) = $0.payload { return data.text }
                        return nil
                    }
                    .joined(separator: " ")
                },
                exportMarkdown: model.markdown(of:)
            )
            // 220 rather than 180: a row is a title, a relative time and a line of preview, and
            // below about this the time starts eating the title it is meant to caption.
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            .safeAreaInset(edge: .bottom) { gear }
        } detail: {
            NavigationStack {
                if let thread {
                    ChatView(
                        model: model,
                        thread: thread,
                        offlineNotice: "Runtime not reachable — see Settings for its state."
                    )
                } else {
                    ContentUnavailableView("No thread", systemImage: "bubble.left.and.bubble.right")
                }
            }
        }
        // A floor rather than a fixed size: the window is resizable now, and the chat has to
        // stay legible at the narrowest a window is worth having.
        .frame(minWidth: 640, minHeight: 420)
        // Selecting something else is what discards a draft nothing was ever sent in, and what
        // tells the model which thread is being read — a reply landing in the open thread is
        // read on arrival, and one landing anywhere else raises a dot in the sidebar.
        .onChange(of: selection, initial: true) { old, new in
            if let old, old != new { model.discardDraft(old) }
            model.openThread = new
        }
        // A window sitting on a thread behind everything else is nobody reading it, so the
        // thread is only reported read while this window is the key one of the active app.
        .onChange(of: controlActiveState, initial: true) { _, state in
            model.foreground = state == .key
        }
        .onAppear { if model.listed { open() } }
        .onChange(of: model.listed) { _, listed in if listed { open() } }
        // Screenshot harness only: prints the window number `screencapture -l` wants. Inert
        // unless a showcase argument was passed — see ``Showcase``.
        .background(WindowNumberReporter())
    }

    /// Pairing, providers, browser, models and the wizard all moved into the Settings scene when
    /// the window became the chat; this is the way back to them, plus the sidecar's state.
    private var gear: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                CheckForUpdatesButton()
                Divider()
                Button("Quit Yorozu") { NSApp.terminate(nil) }
            } label: {
                Label("Yorozu", systemImage: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 0)
            Text(sidecar.state)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Relay state reported by the runtime")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Everything that is not chat. These used to be stacked in the menu bar window itself; the
/// window is the chat now, so they live in the standard Settings scene where ⌘, and the gear
/// menu both find them.
struct SettingsView: View {
    @ObservedObject var sidecar: Sidecar

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                pane { GeneralView() }
            }
            Tab("Providers", systemImage: "cpu") {
                pane { ProvidersView() }
            }
            Tab("Models", systemImage: "square.stack.3d.up") {
                pane { ModelsView() }
            }
            Tab("Devices", systemImage: "iphone.and.arrow.forward") {
                pane { DevicesView(sidecar: sidecar) }
            }
            Tab("Rules", systemImage: "checkmark.seal") {
                pane { RulesView() }
            }
            Tab("Permissions", systemImage: "lock.shield") {
                pane { PermissionsView() }
            }
        }
        .frame(width: 480, height: 460)
    }

    private func pane(@ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            content()
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
