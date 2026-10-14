import AppKit
import ProjectXCore
import SwiftUI

/// Scheduled (#319; a section of the chat window, owner 2026-10-14): the jobs of `jobs.toml` with their controls, read
/// while the window is open so the section's dot and the list stay current.
@MainActor final class JobList: ObservableObject {
    @Published private(set) var jobs: [JobStatus] = []
    /// The latest refusal or skipped Run Now, shown in the job's pane.
    @Published var problem: String?
    private var refreshing: Task<Void,Never>?

    /// A job waits on the user: the section's dot.
    var needsAttention: Bool { jobs.contains { [.needsAttention,.needsApproval].contains($0.state) } }

    /// One read at a time: a newer one cancels the older, so a stale list never lands last.
    func refresh(_ model: AppModel) {
        refreshing?.cancel()
        refreshing = Task {
            guard let engine = model.engine else { return }
            let rows = await engine.jobStatus(nextRuns: await model.jobScheduler?.nextRuns ?? [:])
            guard !Task.isCancelled else { return }
            if rows != jobs { jobs = rows }
        }
    }

    func act(_ model: AppModel,_ control: @escaping (Engine) async throws -> Void) {
        guard let engine = model.engine else { return }
        Task {
            do { try await control(engine); problem = nil } catch { problem = error.localizedDescription }
            refresh(model)
        }
    }
}

/// The job list column: rows with their actions in a context menu, or an empty state.
struct JobsColumn: View {
    @ObservedObject var model: AppModel
    @ObservedObject var list: JobList
    @Binding var selection: String?
    @Binding var deleting: JobStatus?

    var body: some View {
        List(list.jobs,id: \.id,selection: $selection) { job in
            JobRow(job: job).contextMenu { JobActions(model: model,list: list,job: job,deleting: $deleting) }
        }
        .overlay { if list.jobs.isEmpty { empty } }
        .navigationTitle("Scheduled")
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("No jobs yet").font(.headline)
            Text("Ask for one in the chat, such as “every morning at 8, check …”, or edit jobs.toml.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let file = model.jobsFile {
                Button("Show jobs.toml") {
                    NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: file.path) ? file : file.deletingLastPathComponent()])
                }
            }
        }.padding().frame(maxWidth: .infinity,maxHeight: .infinity)
    }
}

/// Pause or Resume, Run Now, and Delete… (confirmed by the window) for one job.
struct JobActions: View {
    @ObservedObject var model: AppModel
    @ObservedObject var list: JobList
    let job: JobStatus
    @Binding var deleting: JobStatus?

    var body: some View {
        if job.state == .paused { Button("Resume") { list.act(model) { try await $0.resumeJob(job.id) } } }
        else { Button("Pause") { list.act(model) { try await $0.pauseJob(job.id) } } }
        Button("Run Now") {
            list.act(model) { engine in
                if case .skipped(let reason) = try await engine.runJobNow(job.id) {
                    throw ProjectError.blocked(String(localized: "Didn’t run.") + " " + (NoticeText.skipReason(reason.rawValue) ?? reason.rawValue))
                }
            }
        }
        Button("Delete…",role: .destructive) { deleting = job }
    }
}

extension AppModel {
    /// `jobs.toml`, next to `config.toml`.
    var jobsFile: URL? { configFile.map { JobsFile.url(in: $0.deletingLastPathComponent()) } }
}

private extension JobStatus {
    var stateLabel: (text: String,icon: String)? {
        switch state {
        case .running: (String(localized: "Running"),"play.circle")
        case .paused: (String(localized: "Paused"),"pause.circle")
        case .needsApproval: (String(localized: "Needs approval"),"hand.raised")
        case .needsAttention: (String(localized: "Needs attention"),"exclamationmark.triangle")
        case .finished: (String(localized: "Finished"),"checkmark.circle")
        case .idle: nil
        }
    }
    var nextLine: String { nextRun.map { String(localized: "Next: \(stamp($0))") } ?? String(localized: "No next run") }
    var lastLine: String? {
        guard let lastRun else { return nil }
        let result = switch lastResult {
        case "done": String(localized: "Done")
        case "failed": String(localized: "Failed")
        case "stopped": String(localized: "Stopped")
        case "uncertain": String(localized: "Interrupted")
        default: String(localized: "Running")
        }
        return String(localized: "Last: \(result) · \(stamp(lastRun))")
    }
}

/// The time, with the date when it is not today.
private func stamp(_ d: Date) -> String {
    d.formatted(Calendar.current.isDateInToday(d) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute())
}

/// A list row: name and state, schedule, next run, last result.
private struct JobRow: View {
    let job: JobStatus
    var body: some View {
        VStack(alignment: .leading,spacing: 2) {
            Text(job.name).fontWeight(.semibold).lineLimit(1)
            Text(job.schedule).foregroundStyle(.secondary).lineLimit(2)
            JobStatusLines(job: job)
        }.padding(.vertical,2)
    }
}

/// State, next run and last result, under a list row and on the job's page, where the state in the warning colour is the
/// banner while the job waits on the user, who answers in its chat below (owner, 2026-10-14).
private struct JobStatusLines: View {
    let job: JobStatus
    var body: some View {
        Group {
            if let state = job.stateLabel { Label(state.text,systemImage: state.icon).foregroundStyle([.needsAttention,.needsApproval].contains(job.state) ? ChatPalette.warning : .secondary) }
            Text(job.nextLine)
            if let last = job.lastLine { Text(last).foregroundStyle(job.lastResult == "failed" ? ChatPalette.warning : .secondary) }
        }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// The selected job: its controls, its sub-chat (messages, job-only kinds included, and its work's events) and its input.
struct JobDetail: View {
    @ObservedObject var model: AppModel
    let job: JobStatus
    @Binding var problem: String?
    /// An item to bring into view and ring (a search hit's step).
    var focus: String? = nil
    let actions: AnyView
    @State private var draft = ""
    @State private var sending = false
    @State private var height: CGFloat = 0
    @State private var position = ScrollPosition(idType: String.self)
    private enum Metrics {
        static let rowSpacing: CGFloat = 10
        /// The input grows to at most this share of the pane's height.
        static let inputShare: CGFloat = 1.0 / 3
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading,spacing: 6) {
                Text(job.name).font(.headline).lineLimit(1)
                Text(job.schedule).foregroundStyle(.secondary).lineLimit(3)
                JobStatusLines(job: job)
                HStack { actions }.controlSize(.small)
                if let problem {
                    Label { Text(problem).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(ChatPalette.warning) }.font(.callout)
                }
            }.frame(maxWidth: .infinity,alignment: .leading).padding(10)
            Divider()
            chat.frame(maxHeight: .infinity)
            Divider()
            input
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }

    private enum Item: Identifiable {
        case day(Date), message(Message), event(WorkerEvent)
        var id: String { switch self { case .day(let d): "day-\(d.timeIntervalSince1970)"; case .message(let m): m.id; case .event(let e): "event-" + e.id } }
    }

    @ViewBuilder private var chat: some View {
        let s = model.snapshot, topic = job.topicID
        let messages = s.messages.filter { $0.topicID != nil && $0.topicID == topic }
        let work = Set(s.work.filter { $0.topicID == topic }.map(\.id))
        let timed = messages.map { ($0.created,Item.message($0)) } + s.events.filter { work.contains($0.taskID) }.map { ($0.created,Item.event($0)) }
        let items = timed.sorted { $0.0 < $1.0 }.reduce(into: (items: [Item](),day: Date?.none)) { acc,next in
            let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: next.0))
            if day != acc.day { acc.items.append(.day(day)); acc.day = day }
            acc.items.append(next.1)
        }.items
        let byID = Dictionary(messages.map { ($0.id,$0) }) { a,_ in a }, shown = Set(byID.keys)
        let labels = Dictionary(s.topics.map { ($0.id,$0.label) }) { a,_ in a }
        let files = Dictionary(grouping: s.attachments.filter { $0.messageID != nil }) { $0.messageID! }
        if items.isEmpty {
            Text("No runs yet. What this job does and says shows here.").foregroundStyle(.secondary).padding().frame(maxWidth: .infinity,maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading,spacing: Metrics.rowSpacing) {
                    ForEach(items) { item in
                        switch item {
                        case .day(let day): DaySeparator(day: day)
                        case .message(let m):
                            MessageRow(message: m,header: m.replyTo.flatMap { byID[$0] }.map { ReplyHeader($0,shown: shown,labels: labels) },highlighted: false,
                                       reveal: { id in withAnimation(.snappy) { position.scrollTo(id: id,anchor: .center) } },files: files[m.id] ?? [],locate: { [model] in await model.attachmentURL($0) })
                        case .event(let e): EventRow(event: e)
                        }
                    }
                }.scrollTargetLayout().padding(.horizontal,14).padding(.vertical,12)
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
            .task(id: focus) {
                guard let focus, items.contains(where: { $0.id == focus }) else { return }
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation(.snappy) { position.scrollTo(id: focus,anchor: .center) }
            }
        }
    }

    private var input: some View {
        let bytes = draft.utf8.count, enabled = model.ready && model.engine != nil && model.runtimeMode.permitsInput(fixtureAcknowledged: model.fixtureAcknowledged)
        let canSend = enabled && !sending && bytes <= Composer.byteLimit && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading,spacing: 6) {
            if bytes > Composer.byteLimit {
                Label { Text("\(bytes.formatted()) bytes. The limit is \(Composer.byteLimit.formatted()).") } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(ChatPalette.warning)
                }.font(.callout)
            }
            HStack(alignment: .bottom,spacing: 6) {
                ComposerField(text: $draft,placeholder: String(localized: "Message this job"),enabled: enabled,maxHeight: height * Metrics.inputShare,
                              sendKey: { [model] in model.sendKey },submit: { if canSend { send() }; return canSend },take: { _ in false })
                    .padding(.horizontal,12).padding(.vertical,6)
                    .background(.background,in: RoundedRectangle(cornerRadius: Composer.Metrics.fieldRadius,style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Composer.Metrics.fieldRadius,style: .continuous).strokeBorder(.separator,lineWidth: 0.5) }
                Button(action: send) {
                    Image(systemName: "arrow.up").fontWeight(.bold).frame(width: Composer.Metrics.sendSide,height: Composer.Metrics.sendSide)
                        .background(canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),in: Circle())
                        .foregroundStyle(canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }.buttonStyle(.plain).disabled(!canSend).help("Send to this job").accessibilityLabel("Send to this job")
            }
        }.padding(.horizontal,10).padding(.vertical,8)
    }

    /// Straight to the job's agent, never the secretary; during a run it waits and runs next (open question 12).
    private func send() {
        guard let engine = model.engine else { return }
        let text = draft, id = job.id
        sending = true
        Task {
            do { try await engine.sendToJob(jobID: id,body: text); if draft == text { draft = "" }; problem = nil; position.scrollTo(edge: .bottom) }
            catch { problem = error.localizedDescription }
            sending = false
        }
    }
}

/// A worker event in the sub-chat: a script's output, a run's log line, a worker's progress.
struct EventRow: View {
    let event: WorkerEvent
    private enum Metrics { static let radius: CGFloat = 7 }
    var body: some View {
        Text(event.body.trimmingCharacters(in: .newlines)).font(.caption.monospaced())
            .foregroundStyle(event.kind == "error" ? ChatPalette.warning : .secondary).textSelection(.enabled)
            .frame(maxWidth: .infinity,alignment: .leading).padding(.horizontal,8).padding(.vertical,6)
            .background(.quaternary.opacity(0.5),in: RoundedRectangle(cornerRadius: Metrics.radius,style: .continuous))
    }
}
