import SwiftUI
import YorozuWire

// Jobs on the phone (#319, `jobs-v1`): the row atop the sub-chat list and the job list with Pause or Resume,
// Run now and Delete. A job's sub-chat is `TopicScreen` with the job's own input.

extension JobListData.Job {
    /// The schedule in words: the first line of the Mac's summary.
    var schedule: String { summary?.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "" }
    /// Waiting on the user: an uncertain run to retry or stop, or a script to approve.
    var needsAttention: Bool { state == "needsAttention" || state == "needsApproval" }
}

/// "Jobs" atop the sub-chat list: how many, and how many need attention.
struct JobsRow: View {
    let jobs: [JobListData.Job]

    var body: some View {
        let attention = jobs.filter(\.needsAttention).count
        Section {
            NavigationLink(value: ChatRoute.jobs) {
                HStack(spacing: LayoutMetrics.stack) {
                    Image(systemName: "clock")
                        .font(.title3)
                        .foregroundStyle(YorozuPalette.vermilion)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                        Text("Jobs").lineLimit(1)
                        Group {
                            if attention > 0 {
                                Text("^[\(jobs.count) job](inflect: true) · \(attention) need attention").foregroundStyle(YorozuPalette.warning)
                            } else {
                                Text("^[\(jobs.count) job](inflect: true)").foregroundStyle(.secondary)
                            }
                        }
                        .font(.footnote)
                        .lineLimit(1)
                    }
                }
            }
        }
    }
}

/// Every job with its schedule, next run and last result. A tap opens its sub-chat; the … menu and swipe actions
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
                if !model.jobs.isEmpty {
                    Text("To create or change a job, ask Yorozu in the main chat. Tap a job to open its sub-chat.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if model.jobs.isEmpty {
                ContentUnavailableView("No jobs yet", systemImage: "clock",
                                       description: Text("To create a job, ask Yorozu in the main chat."))
            }
        }
        .navigationTitle("Jobs")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(Text("Delete “\(deleting?.name ?? "")”?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { job in
            Button("Delete", role: .destructive) { act(job, .delete) }
        } message: { _ in
            Text("It stops running. Its sub-chat and its folder stay on your Mac.")
        }
    }

    private func row(_ job: JobListData.Job) -> some View {
        let enabled = model.canControlJob(job.id)
        return HStack(alignment: .top, spacing: LayoutMetrics.stack) {
            Button {
                if let topic = job.topicId { onOpen(topic) }
            } label: {
                VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                    HStack(spacing: LayoutMetrics.inner) {
                        Text(job.name).font(.headline).lineLimit(1)
                        badge(job.state).layoutPriority(1)
                    }
                    if !job.schedule.isEmpty { Text(job.schedule).font(.subheadline) }
                    next(job).font(.footnote).foregroundStyle(.secondary)
                    last(job).font(.footnote)
                    if let refusal = model.jobRefusals[job.id] {
                        Text(refusal).font(.footnote).foregroundStyle(YorozuPalette.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(job.topicId == nil)
            Menu {
                Button("Run Now", systemImage: "play.fill") { act(job, .runNow) }
                pauseButton(job)
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = job }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: controlTarget, height: controlTarget)
                    .background(.fill.tertiary, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .accessibilityLabel("Job actions")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Group {
                Button("Delete", systemImage: "trash") { deleting = job }.tint(.red)
                pauseButton(job).tint(.gray)
                Button("Run Now", systemImage: "play.fill") { act(job, .runNow) }.tint(YorozuPalette.vermilion)
            }
            .disabled(!enabled)
        }
    }

    private func pauseButton(_ job: JobListData.Job) -> some View {
        job.state == "paused"
            ? Button("Resume", systemImage: "play.circle") { act(job, .resume) }
            : Button("Pause", systemImage: "pause.fill") { act(job, .pause) }
    }

    private func act(_ job: JobListData.Job, _ action: JobControlData.Action) {
        Task { await model.control(job: job.id, action) }
    }

    @ViewBuilder private func badge(_ state: String) -> some View {
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

    private func next(_ job: JobListData.Job) -> Text {
        if job.state == "paused" { return Text("Paused") }
        guard let next = job.nextRun else { return Text("Not scheduled") }
        return Text("Next: \(MessageTime.day.string(from: MessageTime.date(next)))")
    }

    private func last(_ job: JobListData.Job) -> some View {
        let when = job.lastRun.map { MessageTime.day.string(from: MessageTime.date($0)) } ?? ""
        return Group {
            switch (job.state, job.lastResult) {
            case ("needsAttention", _): Text("Open to retry or stop").foregroundStyle(YorozuPalette.warning)
            case ("needsApproval", _): Text("Its script waits for your yes. Open to answer.").foregroundStyle(YorozuPalette.warning)
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
