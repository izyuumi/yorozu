import SwiftUI
import YorozuWire

// Scheduled (#319; a section of its own, owner 2026-10-14): the job list and each job's page with Pause or Resume,
// Run now and Delete. A job's page is its sub-chat (`TopicScreen`, with the job's own input) under its status.

extension JobListData.Job {
    /// Waiting on the user: an uncertain run to retry or stop, or a script to approve.
    var needsAttention: Bool { state == "needsAttention" || state == "needsApproval" }
}

/// Every job with its schedule, next run and last result. A tap opens its page; the … menu and swipe actions
/// run it now, pause or resume it, or delete it after a confirmation.
struct JobsScreen: View {
    let model: PhoneModel
    let onOpen: (String) -> Void

    @State private var deleting: JobListData.Job?

    var body: some View {
        List {
            Section {
                ForEach(model.jobs) { row($0) }
            } footer: {
                VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                    if !model.jobs.isEmpty {
                        Text("To schedule or change something, ask Yorozu in the main chat. Tap one to open its activity.")
                    }
                    // The cached list until the host sends a fresh one (owner, 2026-10-14).
                    if model.state != .paired, let updated = model.jobsUpdated {
                        Text("Updated \(MessageTime.day.string(from: updated))")
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .overlay {
            if model.jobs.isEmpty {
                ContentUnavailableView("Nothing scheduled yet", systemImage: "clock",
                                       description: Text("To schedule something, ask Yorozu in the main chat."))
            }
        }
        .navigationTitle("Scheduled")
        .navigationBarTitleDisplayMode(.inline)
        .jobDeleteDialog(model: model, deleting: $deleting)
    }

    private func row(_ job: JobListData.Job) -> some View {
        let enabled = model.canControlJob(job.id)
        return HStack(alignment: .top, spacing: LayoutMetrics.stack) {
            Button { onOpen(job.id) } label: {
                VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                    HStack(spacing: LayoutMetrics.inner) {
                        Text(job.name).font(.headline).lineLimit(1)
                        JobBadge(state: job.state).layoutPriority(1)
                    }
                    if let schedule = job.schedule, !schedule.isEmpty { Text(schedule).font(.subheadline) }
                    JobStatusLines(model: model, job: job, onPage: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                JobActions(model: model, job: job, deleting: $deleting)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: controlTarget, height: controlTarget)
                    .background(.fill.tertiary, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .accessibilityLabel("Actions")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Group {
                Button("Delete", systemImage: "trash") { deleting = job }.tint(.red)
                JobActions.pause(model: model, job: job).tint(.gray)
                Button("Run Now", systemImage: "play.fill") { JobActions.act(model, job, .runNow) }.tint(YorozuPalette.vermilion)
            }
            .disabled(!enabled)
        }
    }
}

/// One job's page: its status and actions over its sub-chat, or "No runs yet" until the host has bound one.
struct JobScreen: View {
    let model: PhoneModel
    let jobId: String
    let onMainChat: () -> Void
    let onOpenMessage: (String) -> Void

    @State private var deleting: JobListData.Job?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let job = model.jobs.first { $0.id == jobId }
        Group {
            if let topic = job?.topicId {
                TopicScreen(model: model, topicId: topic, focus: nil, onMainChat: onMainChat, onOpenMessage: onOpenMessage)
            } else {
                ContentUnavailableView("No runs yet", systemImage: "clock",
                                       description: Text("Its activity shows here once it has run."))
                    .navigationTitle(job?.name ?? "")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationSubtitleIfAvailable(job?.schedule ?? "")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let job {
                // The state's tag is the banner when the job waits on the user, who answers in the sub-chat below
                // (owner, 2026-10-14).
                VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                    JobBadge(state: job.state)
                    JobStatusLines(model: model, job: job, onPage: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LayoutMetrics.gutter)
                .padding(.vertical, LayoutMetrics.inner)
                .background(.bar)
            }
        }
        .toolbar {
            if let job {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        JobActions(model: model, job: job, deleting: $deleting)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .disabled(!model.canControlJob(job.id))
                    .accessibilityLabel("Actions")
                }
            }
        }
        .jobDeleteDialog(model: model, deleting: $deleting) { dismiss() }
    }
}

/// Run now, Pause or Resume, and Delete (after a confirmation) for one job.
struct JobActions: View {
    let model: PhoneModel
    let job: JobListData.Job
    @Binding var deleting: JobListData.Job?

    var body: some View {
        Button("Run Now", systemImage: "play.fill") { Self.act(model, job, .runNow) }
        Self.pause(model: model, job: job)
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = job }
    }

    static func pause(model: PhoneModel, job: JobListData.Job) -> some View {
        job.state == "paused"
            ? Button("Resume", systemImage: "play.circle") { act(model, job, .resume) }
            : Button("Pause", systemImage: "pause.fill") { act(model, job, .pause) }
    }

    static func act(_ model: PhoneModel, _ job: JobListData.Job, _ action: JobControlData.Action) {
        Task { await model.control(job: job.id, action) }
    }
}

extension View {
    /// The Delete confirmation for `deleting`; `onDelete` runs once the request is sent.
    func jobDeleteDialog(model: PhoneModel, deleting: Binding<JobListData.Job?>, onDelete: @escaping () -> Void = {}) -> some View {
        confirmationDialog(Text("Delete “\(deleting.wrappedValue?.name ?? "")”?"),
                           isPresented: Binding(get: { deleting.wrappedValue != nil }, set: { if !$0 { deleting.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: deleting.wrappedValue) { job in
            Button("Delete", role: .destructive) {
                JobActions.act(model, job, .delete)
                onDelete()
            }
        } message: { _ in
            Text("It stops running. Its activity and its folder stay on the host.")
        }
    }
}

/// The job's state as a tag; nothing while idle.
struct JobBadge: View {
    let state: String

    var body: some View {
        switch state {
        case "paused": tag(String(localized: "job.badge.paused", defaultValue: "Paused"), .secondary)
        case "needsApproval": tag(String(localized: "Needs approval"), YorozuPalette.warning)
        case "needsAttention": tag(String(localized: "Needs attention"), YorozuPalette.warning)
        case "running": tag(String(localized: "Running"), YorozuPalette.vermilion)
        case "finished": tag(String(localized: "Finished"), YorozuPalette.sage)
        default: EmptyView()
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(verbatim: text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, LayoutMetrics.inner)
            .padding(.vertical, LayoutMetrics.hair)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// The next run, the last result, and the host's latest refusal of an action. On the job's page the hints point at
/// its sub-chat below rather than at opening it.
struct JobStatusLines: View {
    let model: PhoneModel
    let job: JobListData.Job
    let onPage: Bool

    var body: some View {
        next.font(.footnote).foregroundStyle(.secondary)
        last.font(.footnote)
        if let refusal = model.jobRefusals[job.id] {
            Text(refusal).font(.footnote).foregroundStyle(YorozuPalette.warning)
        }
    }

    private var next: Text {
        if job.state == "paused" { return Text("Paused") }
        guard let next = job.nextRun else { return Text("Not scheduled") }
        return Text("Next: \(MessageTime.day.string(from: MessageTime.date(next)))")
    }

    private var last: some View {
        let when = job.lastRun.map { MessageTime.day.string(from: MessageTime.date($0)) } ?? ""
        return Group {
            switch (job.state, job.lastResult) {
            case ("needsAttention", _):
                Text(onPage ? "Retry or stop it below" : "Open to retry or stop").foregroundStyle(YorozuPalette.warning)
            case ("needsApproval", _):
                Text(onPage ? "Its script waits for your yes. Answer below." : "Its script waits for your yes. Open to answer.")
                    .foregroundStyle(YorozuPalette.warning)
            case ("running", _): Text("Running since \(when)").foregroundStyle(YorozuPalette.vermilion)
            case (_, "done"?) where job.lastNotable == false: Text("No change · \(when)").foregroundStyle(.secondary)
            case (_, "done"?): Text("Done · \(when)").foregroundStyle(YorozuPalette.sage)
            case (_, "failed"?): Text("Failed · \(when)").foregroundStyle(YorozuPalette.warning)
            case (_, "stopped"?): Text("Stopped · \(when)").foregroundStyle(.secondary)
            case (_, "uncertain"?): Text("Interrupted · \(when)").foregroundStyle(YorozuPalette.warning)
            case (_, nil) where job.lastRun == nil: Text("Not run yet").foregroundStyle(.secondary)
            default: Text("Last: \(when)").foregroundStyle(.secondary)
            }
        }
    }
}
