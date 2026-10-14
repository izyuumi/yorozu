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

    /// The Chats dot: a topic needs attention. Running work is no reason to look.
    var attentionTopics: Int {
        let byTopic = tasksByTopic, jobs = jobTopicIds
        return topics.keys.filter { !jobs.contains($0) && status(of: $0, tasks: byTopic[$0] ?? []) == .attention }.count
    }
}

/// One topic, inspect only: its conversation messages and its tasks in time order. Records update in place.
struct TopicScreen: View {
    let model: PhoneModel
    let topicId: String
    /// A message or task to scroll to (a search hit); a task's activity opens.
    let focus: String?
    let onMainChat: () -> Void
    /// `threads-v1`: New chat's empty thread, whose first message creates it on the host.
    var isNew = false
    /// A message to show: the main timeline's (a secretary-started thread's source) or a cited one.
    var onOpenMessage: (String) -> Void = { _ in }

    @State private var position = ScrollPosition(edge: .bottom)
    /// Tasks whose activity is toggled from its default (open while active).
    @State private var toggled: Set<String> = []
    /// A job's own input (#319), or a thread's composer (`threads-v1`); without threads other sub-chats are inspect only.
    @State private var draft = ""
    @State private var noFiles: [StagedFile] = []
    @State private var files: [StagedFile] = []
    @State private var details: PhoneModel.Bubble?
    @State private var renaming: ThreadRef?
    @State private var deleting: ThreadRef?
    @State private var sentRead: String?
    /// The reader is at the newest message, so new ones are followed; otherwise the view stays put and the pill counts.
    @State private var atBottom = true
    @State private var unseen = 0
    @State private var restored = false
    @State private var phase = ScrollPhase.idle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

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
        let job = model.jobs.first { $0.topicId == topicId }
        // A thread: its own messages too, typed or answered in it, with a composer. A job's sub-chat has the job's input instead.
        let threads = job == nil
        let row = model.thread(topicId)
        let held = (threads ? model.bubbles(inThread: topicId) : model.bubbles.filter { $0.topicId == topicId }).filter { !model.hidesInTopic($0) }
        // Nothing of an older thread held here: the host's page around its newest message.
        let pageAround = threads && held.isEmpty ? row?.lastMessageId : nil
        let messages = pageAround != nil && model.page?.messageId == pageAround ? model.page?.bubbles ?? [] : held
        let source = threads && (row?.bySecretary ?? (model.topics[topicId]?.origin.map { $0 != "user" } ?? false))
            ? row?.sourceMessageId ?? model.topics[topicId]?.sourceMessageId : nil
        let ref = ThreadRef(id: topicId, name: model.threadName(topicId) ?? "", archived: row?.archivedAt != nil || model.topics[topicId]?.archivedAt != nil,
                            running: row?.openWork == true || row?.running == true || tasks.contains { $0.isActive || $0.state == "uncertain" })
        // Grouped once for every card, not filtered per card.
        let taskIds = Set(tasks.map(\.id))
        let events = Dictionary(grouping: model.workerEvents.values.filter { taskIds.contains($0.taskId) }, by: \.taskId)
        let amendments = Dictionary(grouping: model.amendments.values.filter { taskIds.contains($0.taskId) }, by: \.taskId)
        let items = (messages.map(Item.message) + tasks.map(Item.task)).sorted { $0.ts < $1.ts }
        let readTarget = threads && scenePhase == .active && model.state == .paired ? messages.last { $0.seq != nil }?.id : nil
        let missing = model.topics[topicId] == nil && job == nil && !(threads && (isNew || row != nil || !messages.isEmpty))
        let controls = threads && (model.topics[topicId] != nil || row != nil)
        list(items, source: source, threads: threads, events: events, amendments: amendments)
        .overlay(alignment: .bottom) {
            if !atBottom {
                Button {
                    unseen = 0
                    withAnimation(.snappy) { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down").font(.body.weight(.semibold)).frame(width: controlTarget, height: controlTarget).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .yorozuGlass(in: Circle())
                .padding(.bottom, LayoutMetrics.inner)
                .accessibilityLabel(unseen > 0 ? String(localized: "\(unseen) new") : String(localized: "Scroll to bottom"))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: atBottom)
        .onChange(of: items.last?.id) { old, new in
            guard restored, old != nil, new != old else { return }
            // Follow only a reader already at the bottom (#405); anyone reading older messages stays where they are.
            if atBottom { position.scrollTo(edge: .bottom) } else { unseen += 1 }
        }
        // A deleted chat (its tombstone) leaves; a refused delete keeps it open with the reason below.
        .onChange(of: model.deletedThreads.contains(topicId)) { _, gone in if gone { dismiss() } }
        .overlay {
            if missing {
                ContentUnavailableView(model.historySynced ? "This chat isn't here" : "Not downloaded yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text(model.historySynced ? "It may have been deleted on another device." : "It appears once this device has the whole chat history from the host."))
            } else if isNew && items.isEmpty {
                ContentUnavailableView("New chat", systemImage: "square.and.pencil",
                                       description: Text("Yorozu answers here and names the chat from your first message."))
            }
        }
        .task {
            // The draft this chat had, files included (#405).
            let saved = model.drafts.draft(draftKey)
            draft = saved.text
            files = saved.files
            if let focus {
                if let task = model.tasks[focus], !task.isActive { toggled.insert(focus) }
                atBottom = false
                position.scrollTo(id: focus, anchor: .center)
            } else if let mark = ReadingPositions.get(topicId) {
                // Where the reader left it, once that message is loaded (a cold launch loads the history in batches).
                while model.historyLoading, !model.bubbles.contains(where: { $0.id == mark }), !model.tasks.keys.contains(mark) {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                if model.bubbles.contains(where: { $0.id == mark }) || model.tasks[mark] != nil {
                    atBottom = false
                    position.scrollTo(id: mark, anchor: .top)
                }
            }
            try? await Task.sleep(for: .milliseconds(300))
            restored = true
        }
        .onChange(of: draft) { _, text in model.drafts.update(draftKey, text: text, files: files) }
        .onChange(of: files) { _, files in model.drafts.update(draftKey, text: draft, files: files) }
        .task(id: model.state == .paired) {
            if let pageAround, model.state == .paired, model.page?.messageId != pageAround { await model.loadPage(around: pageAround, thread: topicId) }
        }
        // A thread's own read cursor: its newest stored message while it is on screen and the app is active.
        .onChange(of: readTarget, initial: true) { _, id in
            guard let id, id != sentRead, id != model.threadReads[topicId]?.messageId else { return }
            sentRead = id
            Task { await model.markRead(id, thread: topicId) }
        }
        .yorozuBottomBar { bottomBar(job: job, threads: threads, working: tasks.contains(where: \.isActive)) }
        .navigationTitle(job?.name ?? model.threadName(topicId) ?? (isNew ? String(localized: "New chat") : ""))
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitleIfAvailable(job?.schedule ?? "")
        .toolbar {
            if controls {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ThreadMenu(model: model, ref: ref, renaming: $renaming, deleting: $deleting)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Chat actions")
                }
            }
        }
        .threadDialogs(model: model, renaming: $renaming, deleting: $deleting)
        .sheet(item: $details) { bubble in
            MessageDetails(bubble: bubble, delivery: model.delivery(of: bubble),
                           onResend: { model.resend(bubble.id) }, onDelete: { model.delete(bubble.id) })
        }
    }

    private func list(_ items: [Item], source: String?, threads: Bool, events: [String: [WorkerEventData]], amendments: [String: [AmendmentData]]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                if let source {
                    Button { onOpenMessage(source) } label: {
                        Label("Started by Secretary from the main chat", systemImage: "arrow.turn.down.right")
                            .font(.footnote)
                    }
                    .readableRow(gutter: LayoutMetrics.stack)
                }
                AttachLinks(model: model, topicId: topicId).readableRow(gutter: LayoutMetrics.stack)
                ForEach(items) { item in
                    switch item {
                    case .message(let bubble):
                        VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                            // Who speaks, in a thread: the secretary, or a worker's result.
                            if threads, !bubble.user {
                                Text(bubble.kind == "result" ? String(localized: "Worker") : String(localized: "Secretary"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            MessageRow(bubble: bubble, header: nil, delivery: model.delivery(of: bubble),
                                       onShowRequest: {}, onShowDetails: { details = bubble },
                                       onResend: { model.resend(bubble.id) }, onDelete: { model.delete(bubble.id) })
                        }
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
        // Following is the reader's intent: only their own scroll away clears it, and reaching the end restores it. Content
        // growing under a follower (a task card's new steps, a longer answer) keeps the newest in view (#405).
        .onScrollGeometryChange(for: [CGFloat].self) { g in
            [g.contentOffset.y + g.containerSize.height - g.contentInsets.top, g.contentSize.height]
        } action: { old, new in
            let atEnd = new[0] >= new[1] - 24
            if [.tracking, .interacting, .decelerating].contains(phase) {
                if restored { atBottom = atEnd }
            } else if atEnd {
                atBottom = true
            } else if atBottom, restored, old.count == 2, new[1] != old[1] {
                position.scrollTo(edge: .bottom)
            }
            if atBottom, restored { unseen = 0; ReadingPositions.set(nil, chat: topicId) }
        }
        .onScrollPhaseChange { _, new in phase = new }
        .onScrollTargetVisibilityChange(idType: String.self) { ids in
            if restored, !atBottom, let first = ids.first { ReadingPositions.set(first, chat: topicId) }
        }
        .background(Color(.systemGroupedBackground))
    }

    /// A job's input, a thread's composer (`threads-v1`), or the inspect-only note.
    @ViewBuilder private func bottomBar(job: JobListData.Job?, threads: Bool, working: Bool) -> some View {
        VStack(spacing: LayoutMetrics.tight) {
            if !model.statusKnown {
                Text("\(model.shownStatus.label) · Status unknown")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let job {
                Composer(text: $draft, files: $noFiles, attachments: false, working: false, enabled: model.canSend, allowsFiles: false) {
                    model.drafts.update(draftKey, text: draft, files: [])
                    model.drafts.saveNow()
                    guard model.send(draft, toJob: job.id, topic: topicId, draftKey: draftKey) else { return }
                    draft = ""
                    model.drafts.clear(draftKey)
                    position.scrollTo(edge: .bottom)
                } onSendAsTextFile: {}
            } else if threads {
                if let refusal = model.threadRefusals[topicId] {
                    Text(refusal).font(.footnote).foregroundStyle(YorozuPalette.warning)
                }
                Composer(text: $draft, files: $files, attachments: model.attachmentsSupported != false, working: working, enabled: model.canSend) {
                    // New chat's first message creates the thread; until its record arrives every send says so, which
                    // the host ignores once the thread exists.
                    let key = draftKey
                    model.drafts.update(key, text: draft, files: files)
                    model.drafts.saveNow()
                    if model.send(text: draft, files: files, thread: topicId, newThread: isNew && model.topics[topicId] == nil, draftKey: key) {
                        // A draft becomes a chat only now, with its first message (#405); its files went to the outbox.
                        model.drafts.clear(key)
                        model.drafts.clear(Drafts.new(topicId))
                        draft = ""
                        files = []
                        atBottom = true
                        position.scrollTo(edge: .bottom)
                    }
                } onSendAsTextFile: {
                    if let file = try? StagedFile.textFile(draft) { files.append(file); draft = "" }
                }
            } else {
                inspectOnly
            }
        }
    }

    /// A New chat not sent yet keeps its draft as one; once its chat exists, as that chat's.
    private var draftKey: String {
        isNew && model.topics[topicId] == nil && model.thread(topicId) == nil && !model.bubbles.contains(where: { $0.threadId == topicId })
            ? Drafts.new(topicId) : Drafts.chat(topicId)
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
