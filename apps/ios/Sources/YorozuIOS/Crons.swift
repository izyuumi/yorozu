import SwiftUI
import YorozuWire

/// The paired app's sections, Chats and Automations (cron jobs, #432), in one navigation structure: on iPad and Mac a split view whose
/// sidebar holds Automations, the conversations and the Archived ones, with the open conversation or the cron jobs beside
/// it; on iPhone (any compact width) a tab bar with a stack in each tab.
struct HomeView: View {
    enum Section: Hashable { case chats, crons }

    let model: AppModel

    @State private var section = Section.chats
    /// The open conversation; the Crons section sets it too. Side by side, the focused one.
    @State private var selection: String?
    /// The second conversation side by side (owner, 2026-10-21): kept on a phone and on iPhone Duo closed, shown again when there is room.
    @State private var pair = ChatPair()
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columns = NavigationSplitViewVisibility.automatic
    @State private var windowWidth: CGFloat = 0
    /// A conversation is being dragged from the list onto the conversation area.
    @State private var dragging = false
    #endif

    var body: some View {
        Group {
            #if os(iOS)
            if sizeClass == .compact { tabs } else { split }
            #else
            split
            #endif
        }
        .opensRequestedConversation(model, selection: $selection)
        .inAppNotices(model) { open($0, automation: nil) }
        // Deleted on another device while open here.
        .onChange(of: model.deleted) { _, convId in
            if convId != nil, pair.partner == convId { pair.close(pair.focusedSide == .left ? .right : .left, selection: &selection) }
            if convId != nil, selection == convId { selection = nil }
        }
        #if os(iOS)
        .onChange(of: selection) { old, new in
            dragging = false
            pair.selectionChanged(from: old, to: new, compact: sizeClass == .compact, selection: &selection)
        }
        .onChange(of: sizeClass) { _, size in pair.selectionChanged(from: nil, to: selection, compact: size == .compact, selection: &selection) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        #endif
    }

    private func side(_ convId: String) -> PaneSide? { pair.side(of: convId, selection: selection) }

    private var split: some View {
        #if os(iOS)
        NavigationSplitView(columnVisibility: $columns) {
            ConversationsView(model: model, selection: $selection, section: $section, showsCrons: true,
                openBeside: { convId in withAnimation(.snappy) { pair.openBeside(convId, selection: &selection) } }, side: side,
                dragStarted: { dragging = true })
        } detail: {
            if section == .crons {
                CronsView(model: model, open: open)
            } else if selection != nil {
                ChatPairView(model: model, selection: $selection, pair: $pair, columns: $columns, dragging: $dragging,
                    windowWidth: windowWidth)
            } else {
                ContentUnavailableView("No conversation selected", systemImage: "bubble.left.and.bubble.right")
            }
        }
        #else
        NavigationSplitView {
            ConversationsView(model: model, selection: $selection, section: $section, showsCrons: true)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: LayoutMetrics.sidebarMinWidth, ideal: LayoutMetrics.sidebarIdealWidth,
                    max: LayoutMetrics.sidebarMaxWidth)
                #endif
        } detail: {
            if section == .crons {
                CronsView(model: model, open: open)
            } else if let selection {
                ChatView(model: model, convId: selection).id(selection)
            } else {
                ContentUnavailableView("No conversation selected", systemImage: "bubble.left.and.bubble.right")
            }
        }
        #endif
    }

    private var tabs: some View {
        TabView(selection: $section) {
            Tab(String(localized: "Chats"), systemImage: "bubble.left.and.bubble.right", value: Section.chats) {
                NavigationStack {
                    ConversationsView(model: model, selection: $selection, section: $section, showsCrons: false, side: side)
                        .navigationDestination(item: $selection) { convId in
                            ChatView(model: model, convId: convId)
                                .id(convId)
                                #if os(iOS)
                                .safeAreaInset(edge: .top, spacing: 0) { PairSwitcher(model: model, selection: $selection, pair: $pair) }
                                #endif
                                // A new conversation without going back to the list (owner, 2026-10-23).
                                .toolbar {
                                    ToolbarItem(placement: .primaryAction) {
                                        Button(String(localized: "New Conversation"), systemImage: "square.and.pencil") { selection = V3Event.newId() }
                                            .accessibilityIdentifier("chat.new")
                                    }
                                }
                        }
                        #if os(iOS)
                        // A conversation has the whole screen: the composer sits where the tab bar was. Decided here, by
                        // the selection, so the bar returns as the back animation starts; hidden from the conversation
                        // itself, iOS brought it back only after the animation had ended.
                        .toolbar(selection == nil ? .visible : .hidden, for: .tabBar)
                        #endif
                }
            }
            Tab(String(localized: "Automations"), systemImage: "clock", value: Section.crons) {
                NavigationStack { CronsView(model: model, open: open) }
            }
        }
    }

    /// Shows a conversation in Chats, with `automation` attached in its composer.
    private func open(_ convId: String, automation: V3CronJob?) {
        if let automation { model.automationDrafts[convId] = automation }
        selection = convId
        section = .chats
    }
}

/// Every cron job of the plugin's agent (#415), shown as Automations: name, schedule, next run and last status, disabled ones greyed.
/// Read-only: changes go through the agent, from "Edit in Chat", which attaches the job to a new conversation.
struct CronsView: View {
    let model: AppModel
    let open: (_ convId: String, _ automation: V3CronJob?) -> Void

    @State private var failure: V3CronJob?

    var body: some View {
        let jobs = model.crons ?? []
        List {
            if let error = model.cronsError {
                Section {
                    Label { Text("Couldn’t read the automations: \(error)") } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(YorozuPalette.warning)
                    }
                }
            }
            Section {
                ForEach(jobs) { row($0) }
            } footer: {
                if !jobs.isEmpty {
                    Text("To add or change an automation, use Edit in Chat: the agent makes the change.")
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .overlay {
            if model.crons == nil, model.state == .ready {
                ProgressView()
            } else if jobs.isEmpty {
                ContentUnavailableView("No automations", systemImage: "clock",
                    description: Text(model.state == .ready ? "Ask the agent in a chat to schedule something." : model.state.label))
            }
        }
        .refreshable { await model.refreshCrons() }
        // On appear, and again whenever the link comes back.
        .task(id: model.state == .ready) {
            if model.state == .ready { await model.refreshCrons() }
        }
        .navigationTitle("Automations")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitleIfAvailable(model.state == .ready ? "" : model.state.label)
        .alert(String(localized: "Last run failed"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure) { _ in
            Button(String(localized: "OK"), role: .cancel) {}
        } message: { job in
            Text(job.lastError ?? String(localized: "No error message."))
        }
    }

    private func row(_ job: V3CronJob) -> some View {
        HStack(spacing: LayoutMetrics.stack) {
            // A job delivering into a Yorozu conversation opens it.
            if let convId = job.convId {
                Button { open(convId, nil) } label: { CronRow(job: job).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            } else {
                CronRow(job: job)
            }
            if job.lastStatus == "error" {
                Button { failure = job } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(YorozuPalette.warning)
                        .frame(minWidth: controlTarget, minHeight: controlTarget)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Last run failed. Show the error"))
            }
            Button { editInChat(job) } label: {
                Image(systemName: "square.and.pencil").frame(minWidth: controlTarget, minHeight: controlTarget)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Edit in Chat"))
            .accessibilityLabel(Text("Edit in Chat"))
            .accessibilityIdentifier("crons.edit.\(job.id)")
        }
        .contextMenu {
            Button(String(localized: "Edit in Chat"), systemImage: "square.and.pencil") { editInChat(job) }
            if job.lastStatus == "error" {
                Button(String(localized: "Show Error"), systemImage: "xmark.circle") { failure = job }
            }
        }
    }

    /// A new conversation with the job attached in its composer (owner, 2026-10-17): sent, it becomes part of the message.
    private func editInChat(_ job: V3CronJob) {
        open(V3Event.newId(), job)
    }
}

/// Name and state, the schedule, the next run; greyed while the job is disabled.
private struct CronRow: View {
    let job: V3CronJob

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
            HStack(spacing: LayoutMetrics.inner) {
                Text(job.name).font(.headline).lineLimit(1)
                status.layoutPriority(1)
            }
            Text(job.scheduleText).font(.subheadline)
            Group {
                if !job.enabled {
                    Text("Disabled")
                } else if let next = job.nextRunAt {
                    Text("Next run \(Self.date(next), format: .relative(presentation: .named))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if job.convId != nil {
                Label(String(localized: "Delivers to a conversation"), systemImage: "bubble.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(job.enabled ? .primary : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// ✓ or ✗ for the last run, nothing before the first. The error itself is the row's ✗ button.
    @ViewBuilder private var status: some View {
        switch job.lastStatus {
        case "ok":
            Image(systemName: "checkmark.circle").foregroundStyle(.green).accessibilityLabel(Text("Last run succeeded"))
        case "skipped":
            Image(systemName: "forward.circle").foregroundStyle(.secondary).accessibilityLabel(Text("Last run skipped"))
        default:
            EmptyView()
        }
    }

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}
