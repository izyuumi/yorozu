import SwiftUI
import YorozuWire

// Sub-chats on the phone (#313 PR C): the topic list with the Mac's status rule, and each topic's
// inspect-only timeline with per-task Stop and Retry.

/// A topic's status, by the Mac's rule (docs/architecture.md, "Topic status symbols").
enum TopicStatus {
    case running, attention, done, idle
}

extension TaskData {
    /// The Mac's active states (`Work.active`).
    var isActive: Bool { ["queued", "working", "amendment_pending", "cancellation_requested"].contains(state) }
    var canStop: Bool { isActive && !suppressed }
    var canRetry: Bool { (state == "failed" || state == "uncertain") && !suppressed }

    var executorName: String {
        switch executor {
        case nil: String(localized: "Thinking")
        case "claude": String(localized: "Coding · Claude Code")
        case "codex": String(localized: "Coding · Codex")
        case "hermes": String(localized: "Coding · Hermes")
        case "script": String(localized: "Script")
        case let other?: other
        }
    }

    var stateLabel: String {
        switch state {
        case "queued": String(localized: "task.state.queued", defaultValue: "Queued")
        case "working": String(localized: "Running")
        case "amendment_pending": String(localized: "Applying a change")
        case "cancellation_requested": String(localized: "Stopping")
        case "uncertain": String(localized: "Uncertain")
        case "failed": String(localized: "Failed")
        case "done": String(localized: "Done")
        case "cancelled": String(localized: "Stopped")
        case "superseded": String(localized: "Replaced")
        default: state
        }
    }
}

extension [TaskData] {
    /// A topic's task that sets its status: active or blocking work first (coding and thinking tasks
    /// can run side by side in one topic), else the newest.
    var current: TaskData? { last { $0.isActive || $0.state == "uncertain" } ?? last }
}

extension PhoneModel {
    /// The label of the topic a sub-chat was attached to (#348), when it is on this iPhone.
    func attachedTarget(of topicId: String) -> String? { topics[topicId]?.attachedTo.flatMap { topics[$0]?.label } }
}

/// A topic's attach links (#348): "Attached to “T”" on an attached sub-chat, one line per sub-chat attached to this topic.
private struct AttachLinks: View {
    let model: PhoneModel
    let topicId: String

    var body: some View {
        let attached = model.topics.values.filter { $0.attachedTo == topicId }.sorted { $0.created < $1.created }
        if let target = model.topics[topicId]?.attachedTo, let label = model.topics[target]?.label {
            NavigationLink("Attached to “\(label)”", value: ChatRoute.topic(target, focus: nil)).font(.footnote)
        }
        ForEach(attached, id: \.id) { sub in
            NavigationLink("“\(sub.label)” was attached here", value: ChatRoute.topic(sub.id, focus: nil)).font(.footnote)
        }
    }
}

extension PhoneModel {
    private static func byAge(_ a: TaskData, _ b: TaskData) -> Bool { (a.created, a.seq) < (b.created, b.seq) }

    /// A topic's tasks, oldest first.
    func tasks(in topicId: String) -> [TaskData] {
        tasks.values.filter { $0.topicId == topicId }.sorted(by: Self.byAge)
    }

    /// Every topic's tasks, oldest first, in one pass.
    var tasksByTopic: [String: [TaskData]] {
        Dictionary(grouping: tasks.values, by: \.topicId).mapValues { $0.sorted(by: Self.byAge) }
    }

    /// A result message repeats its task's result, which the task card already shows: the topic hides it,
    /// unless it carries files the card does not.
    func hidesInTopic(_ bubble: Bubble) -> Bool {
        ["result", "job_result"].contains(bubble.kind ?? "") && bubble.files.isEmpty && bubble.taskId.flatMap { tasks[$0]?.result } != nil
    }

    /// nil while off the link or catching up: the Mac's state is unknown, never idle. `list`: the
    /// topic's tasks, oldest first, when the caller has them.
    func status(of topicId: String, tasks list: [TaskData]? = nil) -> TopicStatus? {
        guard statusKnown else { return nil }
        guard let current = (list ?? tasks(in: topicId)).current else { return .idle }
        if current.state == "amendment_pending", current.result != nil { return .attention }
        switch current.state {
        case "working", "queued", "amendment_pending": return .running
        case "done": return .done
        case "failed", "uncertain", "cancellation_requested": return .attention
        default: return .idle
        }
    }

    /// The newest thing that happened in each topic, epoch ms, in one pass: orders the list.
    func lastActivities() -> [String: Int] {
        var latest = topics.mapValues(\.created)
        for task in tasks.values { latest[task.topicId] = Swift.max(latest[task.topicId] ?? 0, task.created) }
        for bubble in bubbles {
            if let id = bubble.topicId { latest[id] = Swift.max(latest[id] ?? 0, bubble.ts) }
        }
        return latest
    }

    /// Job runs do not count, as the Mac's working flag ignores them.
    var runningTopics: Int {
        let byTopic = tasksByTopic, jobs = jobTopicIds
        return topics.keys.filter { !jobs.contains($0) && status(of: $0, tasks: byTopic[$0] ?? []) == .running }.count
    }
}

/// The sub-chat list: Running, Needs attention and Recent, or one list while the status is unknown.
struct TopicsScreen: View {
    let model: PhoneModel

    /// Per topic, computed once a render: its tasks, oldest first, and its last activity.
    private struct Facts {
        var tasks: [String: [TaskData]]
        var activity: [String: Int]
    }

    var body: some View {
        let facts = Facts(tasks: model.tasksByTopic, activity: model.lastActivities())
        let jobTopics = model.jobTopicIds
        let ids = model.topics.keys.filter { !jobTopics.contains($0) }.sorted { facts.activity[$0, default: 0] > facts.activity[$1, default: 0] }
        let showsJobs = model.jobsSupported == true
        List {
            if showsJobs { JobsRow(jobs: model.jobs) }
            if !model.statusKnown {
                Section {
                    ForEach(ids, id: \.self) { row($0, nil, facts) }
                } footer: {
                    if model.working == nil {
                        Text("Status unknown until the host is connected.")
                    } else {
                        Text("Status unknown until this device has caught up with the host.")
                    }
                }
            } else {
                let statuses = Dictionary(uniqueKeysWithValues: ids.map { ($0, model.status(of: $0, tasks: facts.tasks[$0] ?? []) ?? .idle) })
                section(String(localized: "Running"), ids.filter { statuses[$0] == .running }, statuses, facts)
                section(String(localized: "Needs attention"), ids.filter { statuses[$0] == .attention }, statuses, facts)
                section(String(localized: "topics.section.recent", defaultValue: "Recent"),
                        ids.filter { statuses[$0] == .done || statuses[$0] == .idle }, statuses, facts)
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if ids.isEmpty && !showsJobs {
                ContentUnavailableView("No activities yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Bigger work runs in the background on the host. It shows up here."))
            }
        }
        .navigationTitle("Activities")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func section(_ title: String, _ ids: [String], _ statuses: [String: TopicStatus], _ facts: Facts) -> some View {
        if !ids.isEmpty {
            Section(title) {
                ForEach(ids, id: \.self) { row($0, statuses[$0], facts) }
            }
        }
    }

    private func row(_ id: String, _ status: TopicStatus?, _ facts: Facts) -> some View {
        NavigationLink(value: ChatRoute.topic(id, focus: nil)) {
            HStack(spacing: LayoutMetrics.stack) {
                TopicSymbol(status: status)
                VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                    Text(model.topics[id]?.label ?? "").lineLimit(1)
                    Group {
                        if let target = model.attachedTarget(of: id) {
                            Text("Attached to “\(target)”").foregroundStyle(.secondary)
                        } else {
                            subtitle(status, current: (facts.tasks[id] ?? []).current, when: facts.activity[id] ?? 0)
                        }
                    }
                    .font(.footnote)
                    .lineLimit(1)
                }
            }
        }
    }

    private func subtitle(_ status: TopicStatus?, current: TaskData?, when: Int) -> some View {
        let when = MessageTime.day.string(from: MessageTime.date(when))
        return Group {
            switch status {
            case nil:
                Text("Status unknown").foregroundStyle(.secondary)
            case .running:
                if let current {
                    Text("\(current.executorName) · \(Text(MessageTime.date(current.created), style: .relative))")
                        .foregroundStyle(.secondary)
                }
            case .attention:
                if let current, current.state == "failed", let error = current.error {
                    Text("Failed: \(error)").foregroundStyle(YorozuPalette.warning)
                } else {
                    Text(verbatim: current?.stateLabel ?? "").foregroundStyle(YorozuPalette.warning)
                }
            case .done:
                Text("Done · \(when)").foregroundStyle(.secondary)
            case .idle:
                Text("Idle · \(when)").foregroundStyle(.secondary)
            }
        }
    }
}

/// The status symbol of a topic row, with its name for VoiceOver.
private struct TopicSymbol: View {
    let status: TopicStatus?

    var body: some View {
        Group {
            switch status {
            case nil:
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    .accessibilityLabel("Status unknown")
            case .running:
                ProgressView().controlSize(.small).tint(YorozuPalette.vermilion)
                    .accessibilityLabel("Running")
            case .attention:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(YorozuPalette.warning)
                    .accessibilityLabel("Needs attention")
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(YorozuPalette.sage)
                    .accessibilityLabel("Done")
            case .idle:
                Image(systemName: "circle").foregroundStyle(.secondary)
                    .accessibilityLabel("Idle")
            }
        }
        .font(.title3)
    }
}

/// One topic, inspect only: its conversation messages and its tasks in time order. Records update in place.
struct TopicScreen: View {
    let model: PhoneModel
    let topicId: String
    /// A message or task to scroll to (a search hit); a task's activity opens.
    let focus: String?
    let onMainChat: () -> Void

    @State private var position = ScrollPosition(edge: .bottom)
    /// Tasks whose activity is toggled from its default (open while active).
    @State private var toggled: Set<String> = []
    /// A job's own input (#319); other sub-chats are inspect only.
    @State private var draft = ""
    @State private var noFiles: [DraftFile] = []
    @State private var details: PhoneModel.Bubble?

    private enum Item: Identifiable {
        case message(PhoneModel.Bubble)
        case task(TaskData)

        var id: String {
            switch self {
            case .message(let bubble): bubble.id
            case .task(let task): task.id
            }
        }

        var ts: Int {
            switch self {
            case .message(let bubble): bubble.ts
            case .task(let task): task.created
            }
        }
    }

    var body: some View {
        let tasks = model.tasks(in: topicId)
        let messages = model.bubbles.filter { $0.topicId == topicId && !model.hidesInTopic($0) }
        // Grouped once for every card, not filtered per card.
        let taskIds = Set(tasks.map(\.id))
        let events = Dictionary(grouping: model.workerEvents.values.filter { taskIds.contains($0.taskId) }, by: \.taskId)
        let amendments = Dictionary(grouping: model.amendments.values.filter { taskIds.contains($0.taskId) }, by: \.taskId)
        let items = (messages.map(Item.message) + tasks.map(Item.task)).sorted { $0.ts < $1.ts }
        let job = model.jobsSupported == true ? model.jobs.first { $0.topicId == topicId } : nil
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                AttachLinks(model: model, topicId: topicId).readableRow(gutter: LayoutMetrics.stack)
                ForEach(items) { item in
                    switch item {
                    case .message(let bubble):
                        MessageRow(bubble: bubble, header: nil, delivery: model.delivery(of: bubble),
                                   onShowRequest: {}, onShowDetails: { details = bubble },
                                   onResend: { model.resend(bubble.id) }, onDelete: { model.delete(bubble.id) })
                            .readableRow(gutter: LayoutMetrics.stack)
                            .id(bubble.id)
                    case .task(let task):
                        TaskCard(model: model, task: task, events: events[task.id] ?? [], amendments: amendments[task.id] ?? [],
                                 open: task.isActive != toggled.contains(task.id)) {
                            if toggled.contains(task.id) { toggled.remove(task.id) } else { toggled.insert(task.id) }
                        }
                        .readableRow(gutter: LayoutMetrics.stack)
                        .id(task.id)
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, LayoutMetrics.stack)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .background(Color(.systemGroupedBackground))
        .overlay {
            if model.topics[topicId] == nil && job == nil {
                ContentUnavailableView("Not on this device", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("This activity is older than what this device keeps. Open it on the host."))
            }
        }
        .task {
            guard let focus else { return }
            if let task = model.tasks[focus], !task.isActive { toggled.insert(focus) }
            position.scrollTo(id: focus, anchor: .center)
        }
        .yorozuBottomBar {
            VStack(spacing: LayoutMetrics.tight) {
                if !model.statusKnown {
                    Text("\(model.shownStatus.label) · Status unknown")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let job {
                    Composer(text: $draft, files: $noFiles, attachments: false, working: false, enabled: model.canSend, allowsFiles: false) {
                        model.send(draft, toJob: job.id, topic: topicId)
                        draft = ""
                        position.scrollTo(edge: .bottom)
                    } onSendAsTextFile: {}
                } else {
                    inspectOnly
                }
            }
        }
        .navigationTitle(job?.name ?? model.topics[topicId]?.label ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitleIfAvailable(job.map(\.schedule) ?? String(localized: "Inspect only"))
        .sheet(item: $details) { bubble in
            MessageDetails(bubble: bubble, delivery: model.delivery(of: bubble),
                           onResend: { model.resend(bubble.id) }, onDelete: { model.delete(bubble.id) })
        }
    }

    private var inspectOnly: some View {
        HStack(spacing: LayoutMetrics.inner) {
            Text("To change this work, write in the main chat.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Main Chat", action: onMainChat)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .padding(.leading, LayoutMetrics.gutter)
        .padding(.trailing, LayoutMetrics.inner)
        .padding(.vertical, LayoutMetrics.inner)
        .yorozuGlass(in: Capsule())
        .padding(.horizontal, LayoutMetrics.stack)
        .padding(.vertical, LayoutMetrics.inner)
        .frame(maxWidth: LayoutMetrics.composerWidth)
        .frame(maxWidth: .infinity)
    }
}

/// One task: executor and state, instruction, amendments, error, collapsible activity, result, and
/// Stop (active) or Retry (failed or uncertain).
private struct TaskCard: View {
    let model: PhoneModel
    let task: TaskData
    /// This task's worker events and amendments, in any order.
    let events: [WorkerEventData]
    let amendments: [AmendmentData]
    let open: Bool
    let onToggle: () -> Void

    /// The whole activity, rather than its newest steps.
    @State private var showAll = false

    private let radius: CGFloat = 22
    /// Steps an open activity shows before "Show all".
    private static let shownSteps = 20

    var body: some View {
        let events = events.sorted { ($0.created, $0.seq) < ($1.created, $1.seq) }
        let amendments = amendments.sorted { $0.revision < $1.revision }
        VStack(alignment: .leading, spacing: LayoutMetrics.stack) {
            HStack(spacing: LayoutMetrics.inner) {
                Text(verbatim: task.executorName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, LayoutMetrics.inner)
                    .padding(.vertical, LayoutMetrics.hair)
                    .background(.fill.tertiary, in: Capsule())
                Spacer(minLength: 0)
                stateLabel
            }
            Text(task.instruction)
                .textSelection(.enabled)
            ForEach(amendments, id: \.id) { amendment in
                Label {
                    Text("Amendment \(amendment.revision) · \(amendmentState(amendment.state)): \(amendment.instruction)")
                } icon: {
                    Image(systemName: "pencil")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            if let error = task.error, !error.isEmpty {
                Label { Text(error).textSelection(.enabled) } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(YorozuPalette.warning)
                }
                .font(.subheadline)
            }
            if !events.isEmpty {
                Button(action: { withAnimation { onToggle() } }) {
                    HStack(spacing: LayoutMetrics.tight) {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0))
                        Text("Activity · \(events.count) steps")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: controlTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? String(localized: "Expanded") : String(localized: "Collapsed"))
                if open {
                    let hidden = showAll ? 0 : Swift.max(0, events.count - Self.shownSteps)
                    if hidden > 0 {
                        Button("Show all \(events.count) steps") { showAll = true }
                            .font(.subheadline)
                            .frame(minHeight: controlTarget)
                    }
                    LazyVStack(alignment: .leading, spacing: LayoutMetrics.inner) {
                        ForEach(events.dropFirst(hidden), id: \.id) { EventRow(event: $0).id($0.id) }
                    }
                }
            }
            if let result = task.result, !result.isEmpty {
                MarkdownBlocks(result)
            }
            control
        }
        .padding(LayoutMetrics.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private func amendmentState(_ state: String) -> String {
        switch state {
        case "queued_input": String(localized: "added before start")
        case "pending": String(localized: "pending")
        case "accepted": String(localized: "accepted")
        case "applied": String(localized: "applied")
        case "pending_reconciliation": String(localized: "waiting for the earlier run")
        default: state
        }
    }

    /// Off the link a task that may still change reads "Status unknown"; finished ones keep their state.
    @ViewBuilder private var stateLabel: some View {
        let unknown = !model.statusKnown && (task.isActive || task.state == "uncertain")
        Group {
            if unknown {
                Label("Status unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            } else if task.isActive {
                Label { Text(verbatim: task.stateLabel) } icon: { ProgressView().controlSize(.mini) }
                    .foregroundStyle(YorozuPalette.vermilion)
            } else if task.state == "failed" || task.state == "uncertain" {
                Label { Text(verbatim: task.stateLabel) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(YorozuPalette.warning)
            } else if task.state == "done" {
                Label { Text(verbatim: task.stateLabel) } icon: { Image(systemName: "checkmark") }
                    .foregroundStyle(YorozuPalette.sage)
            } else {
                Text(verbatim: task.stateLabel).foregroundStyle(.secondary)
            }
        }
        .font(.footnote.weight(.semibold))
    }

    /// One `task_control` per tap; disabled until its result or a change to the task, and unless `.paired`.
    @ViewBuilder private var control: some View {
        let action: TaskControlData.Action? = task.canStop ? .stop : task.canRetry ? .retry : nil
        if let action {
            let stop = action == .stop
            Button {
                Task { await model.control(task.id, action) }
            } label: {
                Label(stop ? String(localized: "Stop") : String(localized: "Retry"),
                      systemImage: stop ? "stop.fill" : "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, LayoutMetrics.gutter)
                    .frame(minHeight: controlTarget)
                    .foregroundStyle(stop ? Color.red : YorozuPalette.vermilion)
                    .background((stop ? Color.red : YorozuPalette.vermilion).opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!model.canControl(task.id))
            .opacity(model.canControl(task.id) ? 1 : 0.5)
        }
        if let result = model.controlResults[task.id] {
            Text(result.notice.map { NoticeText.text(code: $0.code, params: $0.params, fallback: result.text) } ?? result.text)
                .font(.footnote)
                .foregroundStyle(result.accepted ? Color.secondary : YorozuPalette.warning)
        }
    }
}

/// One worker event: tools, commands and output in monospace, messages as text, the rest as notes,
/// and any images the worker shared (#316).
private struct EventRow: View {
    let event: WorkerEventData

    /// Output can run to megabytes; the phone shows the head, the Mac keeps the rest.
    private static let shownCharacters = 2000

    var body: some View {
        let mono = ["tool", "command", "output", "error", "diff"].contains(event.kind)
        let body = event.body.count > Self.shownCharacters ? String(event.body.prefix(Self.shownCharacters)) + "…" : event.body
        HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.inner) {
            Image(systemName: icon)
                .foregroundStyle(event.kind == "error" ? YorozuPalette.warning : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
                Text(body)
                    .font(mono ? .footnote.monospaced() : .subheadline)
                    .foregroundStyle(event.kind == "message" ? Color.primary : Color.secondary)
                    .lineLimit(mono ? 8 : nil)
                    .textSelection(.enabled)
                let files = event.attachmentInfos
                if !files.isEmpty { AttachmentsView(files: files) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(MessageTime.date(event.created), format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch event.kind {
        case "tool", "command": "wrench.and.screwdriver"
        case "message": "text.bubble"
        case "output": "terminal"
        case "error": "exclamationmark.triangle"
        case "diff": "plus.forwardslash.minus"
        default: "info.circle"
        }
    }
}
