import SwiftUI
import YorozuWire

/// The paired app's sections: Chats and Crons (#432), a tab bar on iPhone and a sidebar on iPad and Mac.
struct V3HomeView: View {
    enum Section: Hashable { case chats, crons }

    let model: V3Model

    @State private var section = Section.chats
    @State private var selection: String?

    var body: some View {
        TabView(selection: $section) {
            Tab(String(localized: "Chats"), systemImage: "bubble.left.and.bubble.right", value: Section.chats) {
                ConversationsView(model: model, selection: $selection)
            }
            Tab(String(localized: "Crons"), systemImage: "clock", value: Section.crons) {
                NavigationStack { V3CronsView(model: model, open: open) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .defaultAdaptableTabBarPlacement(.sidebar)
        #endif
    }

    /// Shows a conversation in Chats, with `draft` waiting in its composer.
    private func open(_ convId: String, draft: String?) {
        if let draft { model.drafts[convId] = draft }
        selection = convId
        section = .chats
    }
}

/// Every cron job of the plugin's agent (#415, "Crons"): name, schedule, next run and last status, disabled ones greyed.
/// Read-only: changes go through the agent, from "Edit in Chat".
struct V3CronsView: View {
    let model: V3Model
    let open: (_ convId: String, _ draft: String?) -> Void

    @State private var failure: V3CronJob?

    var body: some View {
        let jobs = model.crons ?? []
        List {
            if let error = model.cronsError {
                Section {
                    Label { Text("Couldn’t read the cron jobs: \(error)") } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(YorozuPalette.warning)
                    }
                }
            }
            Section {
                ForEach(jobs) { row($0) }
            } footer: {
                if !jobs.isEmpty {
                    Text("To add or change a job, use Edit in Chat: the agent makes the change.")
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
                ContentUnavailableView("No cron jobs", systemImage: "clock",
                    description: Text(model.state == .ready ? "Ask the agent in a chat to schedule something." : model.state.label))
            }
        }
        .refreshable { await model.refreshCrons() }
        // On appear, and again whenever the link comes back.
        .task(id: model.state == .ready) {
            if model.state == .ready { await model.refreshCrons() }
        }
        .navigationTitle("Crons")
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
                Button { open(convId, nil) } label: { V3CronRow(job: job).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            } else {
                V3CronRow(job: job)
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

    /// The job's delivery conversation, or a new one, with the change request started and left unsent (#415).
    private func editInChat(_ job: V3CronJob) {
        open(job.convId ?? V3Event.newId(), "Change cron job \"\(job.name)\" (id \(job.id)): ")
    }
}

/// Name and state, the schedule, the next run; greyed while the job is disabled.
private struct V3CronRow: View {
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
