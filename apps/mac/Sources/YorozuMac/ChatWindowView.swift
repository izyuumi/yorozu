import AppKit
import SwiftUI
import YorozuShared

/// The menu bar window: threads on the left, the chat on the right, and everything that is not
/// chat behind the gear. The detail half has its own `NavigationStack`, which is what the
/// subagent drill-down and the trace pages push onto.
struct ChatWindowView: View {
    @State private var selection: String?
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
                onArchive: model.archive
            )
            .frame(minWidth: 180)
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
        .frame(width: 720, height: 480)
        // Selecting something else is what discards a draft nothing was ever sent in.
        .onChange(of: selection) { old, new in
            if let old, old != new { model.discardDraft(old) }
        }
        .onAppear { if model.listed { open() } }
        .onChange(of: model.listed) { _, listed in if listed { open() } }
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
