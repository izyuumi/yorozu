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
    @State private var session = MacChatSession.shared
    @State private var selection: String?
    /// `.key` is this window being the key window of the active app, which is exactly the Mac's
    /// half of "somebody is looking at this": `.active` is a window in the active app that is
    /// not key, and `.inactive` is the whole app sitting behind something else.
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openSettings) private var openSettings

    private var model: ChatModel { session.model }

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
                workingThreads: model.generating,
                selection: $selection,
                projects: model.projects,
                onCreate: { agent, cwd in selection = model.newDraft(agent: agent, cwd: cwd).id },
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
            .navigationSplitViewColumnWidth(
                min: LayoutMetrics.sidebarMinWidth,
                ideal: LayoutMetrics.sidebarIdealWidth,
                max: LayoutMetrics.sidebarMaxWidth
            )
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
        .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
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
        HStack(spacing: 8) {
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
            Label {
                Text(connectionLabel)
            } icon: {
                Image(systemName: model.state == .paired ? "circle.fill" : "circle.dotted")
                    .font(.system(size: 7))
                    .foregroundStyle(model.state == .paired ? .green : .secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help("Relay state reported by the runtime")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var connectionLabel: String {
        switch model.state {
        case .paired: "Connected"
        case .connecting, .joined: "Connecting"
        case .closed: "Offline"
        }
    }
}

/// Everything that is not chat. These used to be stacked in the menu bar window itself; the
/// window is the chat now, so they live in the standard Settings scene where ⌘, and the gear
/// menu both find them.
struct SettingsView: View {
    private enum SettingsSection: String, CaseIterable, Identifiable {
        case general, devices, permissions, providers, approvals, rules

        var id: Self { self }
        var presentation: (title: String, symbol: String) {
            switch self {
            case .general: ("General", "gearshape")
            case .devices: ("Devices", "iphone.and.arrow.forward")
            case .permissions: ("Permissions", "lock.shield")
            case .providers: ("Providers", "point.3.connected.trianglepath.dotted")
            case .approvals: ("Approvals", "hand.raised")
            case .rules: ("Rules", "checklist")
            }
        }
    }

    @ObservedObject var sidecar: Sidecar
    @State private var session = MacChatSession.shared
    @State private var selection: SettingsSection? = .general

    private var sections: [SettingsSection] {
        session.role == .host ? SettingsSection.allCases : [.general]
    }

    var body: some View {
        NavigationSplitView {
            List(sections, selection: $selection) { section in
                Label(section.presentation.title, systemImage: section.presentation.symbol)
                    .tag(section)
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
        } detail: {
            pane { selectedView }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 580)
        .onChange(of: session.role) { _, role in
            if role != .host { selection = .general }
        }
    }

    private func pane(@ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text((selection ?? .general).presentation.title)
                    .font(.title2.weight(.semibold))
                content()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(.background)
    }

    @ViewBuilder private var selectedView: some View {
        switch selection ?? .general {
        case .general: GeneralView()
        case .devices: DevicesView(sidecar: sidecar)
        case .permissions: PermissionsView(showsTitle: false)
        case .providers:
            ProvidersView()
            Divider().padding(.vertical, 4)
            ModelsView()
            Divider().padding(.vertical, 4)
            BrowserView()
        case .approvals: ApprovalFloorView()
        case .rules: RulesView()
        }
    }
}
