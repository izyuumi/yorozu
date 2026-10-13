import SwiftUI
import AppKit
import ProjectXCore
import YorozuWire

/// A sub-chat's state, from its current task: the newest active or uncertain one, else the newest (the phone's rule).
enum ActivityState: Int, Comparable {
    case attention, running, done, idle
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    init(_ tasks: [Work]) {
        guard let current = tasks.last(where: { $0.active || $0.state == "uncertain" }) ?? tasks.last else { self = .idle; return }
        if current.state == "amendment_pending", current.result != nil { self = .attention; return }
        switch current.state {
        case "working","queued","amendment_pending": self = .running
        case "failed","uncertain","cancellation_requested": self = .attention
        case "done": self = .done
        default: self = .idle
        }
    }
}

/// One sub-chat in the list: its topic, state and newest activity (epoch seconds).
struct Activity: Identifiable {
    let topic: Topic, state: ActivityState, last: Double
    var id: String { topic.id }
}

extension Snapshot {
    /// Every sub-chat but the jobs' (Settings › Jobs has those), newest activity first.
    func activities(excluding jobs: Set<String>) -> [Activity] {
        let tasks = Dictionary(grouping: work,by: \.topicID)
        var last = Dictionary(topics.map { ($0.id,$0.created) }) { a,_ in a }
        for m in messages { if let t = m.topicID { last[t] = max(last[t] ?? 0,m.created) } }
        for w in work { last[w.topicID] = max(last[w.topicID] ?? 0,w.created) }
        return topics.filter { !jobs.contains($0.id) && $0.deletedAt == nil }
            .map { Activity(topic: $0,state: ActivityState(tasks[$0.id] ?? []),last: last[$0.id] ?? $0.created) }
            .sorted { $0.last > $1.last }
    }
}

/// The chat window (owner, 2026-10-13; it was the inspect-only Activities window): the thread list as its sidebar with
/// Main pinned on top and New chat, the threads in Needs attention, Running and Recent, each by latest activity, a page at
/// a time behind Show more, and the archived ones behind Archived; beside it Main or the selected thread with a composer.
struct ChatWindow: View {
    static let id = "activities"
    static let main = "main"
    @ObservedObject var model: AppModel
    @StateObject private var search = ChatSearch()
    @State private var selection: String? = ChatWindow.main
    /// A New chat not sent yet: shown as an empty thread until its first message creates it.
    @State private var draftThread: String?
    @State private var archivedShown = false
    @State private var renaming: ThreadRow?
    @State private var name = ""
    @State private var deleting: ThreadRow?
    private enum Metrics { static let minWidth: CGFloat = 720, minHeight: CGFloat = 480, sidebar: CGFloat = 250 }

    var body: some View {
        let rows = archivedShown ? model.archivedThreads : model.threads
        NavigationSplitView {
            List(selection: $selection) {
                if !archivedShown {
                    Label("Main",systemImage: "bubble.left").tag(Self.main)
                    if let draftThread { Label("New chat",systemImage: "square.and.pencil").tag(draftThread) }
                    section("Needs attention",rows.filter { ActivityState(current: $0.state) == .attention })
                    section("Running",rows.filter { ActivityState(current: $0.state) == .running })
                    section("Recent",rows.filter { ActivityState(current: $0.state) > .running })
                } else {
                    section("Archived",rows)
                }
                if (archivedShown ? model.archivedNext : model.threadsNext) != nil {
                    Button("Show more") { Task { await model.loadThreads(archived: archivedShown,more: true) } }.buttonStyle(.link)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Toggle(isOn: $archivedShown) { Label("Archived",systemImage: "archivebox") }
                    .toggleStyle(.button).buttonStyle(.accessoryBar).frame(maxWidth: .infinity,alignment: .leading).padding(8)
            }
            .toolbar {
                Button { newChat() } label: { Image(systemName: "square.and.pencil") }.help("New chat").accessibilityLabel("New chat")
            }
            .navigationSplitViewColumnWidth(min: Metrics.sidebar * 0.8,ideal: Metrics.sidebar)
        } detail: {
            if selection == Self.main || selection == nil {
                VStack(spacing: 0) {
                    if search.shown { SearchBar(search: search).padding(10) }
                    MainChat(model: model,search: search)
                }
                .background { Button("Search") { search.shown = true }.keyboardShortcut("f").hidden() }
            } else if let id = selection {
                let row = (model.threads + model.archivedThreads).first { $0.topic.id == id }
                ThreadDetail(model: model,id: id,row: row,rename: { start(renaming: $0) },delete: { deleting = $0 },
                             showMain: { message in selection = Self.main; model.focusMessageID = message },
                             sent: { if draftThread == id { draftThread = nil } }).id(id)
            }
        }
        .frame(minWidth: Metrics.minWidth,minHeight: Metrics.minHeight)
        .navigationTitle("Chats")
        .environment(\.openURL,OpenURLAction { url in model.openLink(url) ? .handled : .systemAction })
        .task(id: search.shown ? search.query : nil) {
            guard search.shown else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await search.run(model,timeline: Set(model.timeline.map(\.id)))
        }
        // The list follows the store: re-read the loaded rows when anything changed (a cheap, paged query).
        .task(id: model.snapshot) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.loadThreads()
        }
        .task(id: archivedShown) { if archivedShown { await model.loadThreads(archived: true) } }
        .onChange(of: model.chatFocus,initial: true) { _,focus in
            guard let focus else { return }
            archivedShown = false
            selection = focus.thread ?? Self.main
            if focus.thread == nil { if let m = focus.message { model.focusMessageID = m }; model.chatFocus = nil }
        }
        .onChange(of: selection) { _,_ in model.threadNotice = nil }
        .alert("Rename Chat",isPresented: Binding(get: { renaming != nil },set: { if !$0 { renaming = nil } }),presenting: renaming) { row in
            TextField("Name",text: $name)
            Button("Rename") { Task { await model.control(thread: row.topic.id,.rename,name: name) } }
            Button("Cancel",role: .cancel) {}
        }
        .confirmationDialog("Delete this chat?",isPresented: Binding(get: { deleting != nil },set: { if !$0 { deleting = nil } }),presenting: deleting) { row in
            Button("Delete",role: .destructive) {
                if selection == row.topic.id { selection = Self.main }
                Task { await model.control(thread: row.topic.id,.delete) }
            }
        } message: { _ in
            Text("Its messages are removed for good, from search and from Yorozu's recall. Memory already taken from them stays.")
        }
    }

    @ViewBuilder private func section(_ title: LocalizedStringKey,_ items: [ThreadRow]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items,id: \.topic.id) { row in
                    ThreadListRow(row: row).tag(row.topic.id).contextMenu { ThreadActions(model: model,row: row,rename: start(renaming:),delete: { deleting = $0 }) }
                }
            }
        }
    }

    private func newChat() {
        let id = draftThread ?? UUID().uuidString.lowercased()
        draftThread = id; archivedShown = false; selection = id
    }

    private func start(renaming row: ThreadRow) { name = row.topic.label; renaming = row }
}

/// Rename, Archive or Unarchive, and Delete, for a row's context menu and a thread's ⋯ menu.
private struct ThreadActions: View {
    @ObservedObject var model: AppModel
    let row: ThreadRow
    let rename: (ThreadRow) -> Void
    let delete: (ThreadRow) -> Void
    var body: some View {
        Button("Rename…") { rename(row) }
        if row.topic.archivedAt == nil { Button("Archive") { Task { await model.control(thread: row.topic.id,.archive) } } }
        else { Button("Unarchive") { Task { await model.control(thread: row.topic.id,.unarchive) } } }
        Divider()
        Button("Delete…",role: .destructive) { delete(row) }
    }
}

private struct ThreadListRow: View {
    let row: ThreadRow
    var body: some View {
        let state = ActivityState(current: row.state)
        VStack(alignment: .leading,spacing: 2) {
            HStack(spacing: 6) {
                // Started by the secretary from the main chat (owner, 2026-10-13).
                if row.topic.origin != Topic.user {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary).help("Started by Secretary").accessibilityLabel("Started by Secretary")
                }
                Text(row.topic.label).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                if row.unread > 0 {
                    Text(row.unread,format: .number).font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal,5).background(Color.accentColor,in: Capsule())
                        .accessibilityLabel(Text("\(row.unread) unread"))
                }
                Text(Date(timeIntervalSince1970: row.topic.activity ?? row.topic.created),format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let summary = row.topic.summary, !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ActivityStateLabel(state: state).font(.caption)
        }.padding(.vertical,2)
    }
}

/// Words and a symbol, so a state is never told by colour alone.
private struct ActivityStateLabel: View {
    let state: ActivityState
    var body: some View {
        switch state {
        // Only the symbol in amber: amber words were unreadable on a selected row's accent fill.
        case .attention: Label { Text("Needs attention") } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(ChatPalette.warning) }.foregroundStyle(.secondary)
        case .running: Label { Text("Running") } icon: { ProgressView().controlSize(.mini) }.foregroundStyle(.secondary)
        case .done: Label("Done",systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .idle: EmptyView()
        }
    }
}

/// One thread: its name, summary, origin header and attach links, its messages (the user's on the right, Yorozu's on the
/// left labelled Secretary or Worker) and task cards in time order, then a composer. `row` is nil for a New chat not sent
/// yet, or a thread past the loaded pages (its topic then comes from the snapshot).
private struct ThreadDetail: View {
    @ObservedObject var model: AppModel
    let id: String
    let row: ThreadRow?
    let rename: (ThreadRow) -> Void
    let delete: (ThreadRow) -> Void
    let showMain: (String?) -> Void
    let sent: () -> Void
    @State private var position = ScrollPosition(idType: String.self)
    @State private var draft = ""
    @State private var height: CGFloat = 0
    @State private var flashed: String?
    private enum Metrics { static let rowSpacing: CGFloat = 10, composerShare: CGFloat = 1.0 / 3, sendSide: CGFloat = 28, fieldRadius: CGFloat = 15 }

    private enum Item: Identifiable {
        case day(Date), message(Message), task(Work)
        var id: String { switch self { case .day(let d): "day-\(d.timeIntervalSince1970)"; case .message(let m): m.id; case .task(let w): "task-" + w.id } }
    }

    private var topic: Topic? { row?.topic ?? model.snapshot.topics.first { $0.id == id && $0.deletedAt == nil } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            chat.frame(maxHeight: .infinity)
            if let notice = model.client?.threadRefusals[id] ?? model.threadNotice {
                Label { Text(notice) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(ChatPalette.warning) }
                    .font(.callout).frame(maxWidth: .infinity,alignment: .leading).padding(.horizontal,12).padding(.top,6)
            }
            Divider()
            composer
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onChange(of: model.chatFocus,initial: true) { _,focus in
            guard let focus, focus.thread == id, let m = focus.message else { return }
            model.chatFocus = nil
            Task { try? await Task.sleep(for: .milliseconds(200)); reveal(m) }
        }
    }

    private var header: some View {
        let s = model.snapshot
        let labels = Dictionary(s.topics.map { ($0.id,$0.label) }) { a,_ in a }
        return HStack(alignment: .top) {
            VStack(alignment: .leading,spacing: 4) {
                Text(topic?.label ?? String(localized: "New chat")).font(.headline).lineLimit(2)
                if let summary = topic?.summary, !summary.isEmpty { Text(summary).foregroundStyle(.secondary).lineLimit(3) }
                // A thread the secretary started from the main timeline links to the message it came from.
                if let topic, topic.origin != Topic.user {
                    Button { showMain(topic.source) } label: { Label("Started by Secretary from the main chat",systemImage: "arrow.triangle.branch") }
                        .buttonStyle(.link).disabled(topic.source == nil)
                }
                // #348: an attached sub-chat names its topic; a topic lists the sub-chats attached to it.
                if let target = topic?.attachedTo, let label = labels[target] { Text("Attached to “\(label)”").foregroundStyle(.secondary) }
                ForEach(s.topics.filter { $0.attachedTo == id && $0.deletedAt == nil },id: \.id) { sub in
                    Text("“\(sub.label)” was attached here").foregroundStyle(.secondary)
                }
            }.font(.callout).frame(maxWidth: .infinity,alignment: .leading)
            if let row {
                Menu { ThreadActions(model: model,row: row,rename: rename,delete: delete) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More").accessibilityLabel("More")
            }
        }.padding(12)
    }

    @ViewBuilder private var chat: some View {
        let s = model.snapshot
        let tasks = s.work.filter { $0.topicID == id }
        let ids = Set(tasks.map(\.id))
        let events = Dictionary(grouping: s.events.filter { ids.contains($0.taskID) },by: \.taskID)
        let messages = s.messages.filter { $0.threadID == id || $0.topicID == id }
        let timed = messages.map { ($0.created,Item.message($0)) } + tasks.map { ($0.created,Item.task($0)) }
        let items = timed.sorted { $0.0 < $1.0 }.reduce(into: (items: [Item](),day: Date?.none)) { acc,next in
            let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: next.0))
            if day != acc.day { acc.items.append(.day(day)); acc.day = day }
            acc.items.append(next.1)
        }.items
        let byID = Dictionary(s.messages.map { ($0.id,$0) }) { a,_ in a }, shown = Set(messages.map(\.id))
        let labels = Dictionary(s.topics.map { ($0.id,$0.label) }) { a,_ in a }
        let files = Dictionary(grouping: s.attachments.filter { $0.messageID != nil }) { $0.messageID! }
        if items.isEmpty {
            Text(topic == nil ? "Ask anything; this chat keeps its own subject." : "Nothing here yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity,maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading,spacing: Metrics.rowSpacing) {
                    ForEach(items) { item in
                        switch item {
                        case .day(let day): DaySeparator(day: day)
                        case .message(let m):
                            VStack(alignment: .leading,spacing: 3) {
                                // Yorozu's messages are labelled by who wrote them (owner, 2026-10-13).
                                if m.role != "user" { Text(m.kind == "result" ? "Worker" : "Secretary").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                                MessageRow(message: m,header: m.replyTo.flatMap { byID[$0] }.map { ReplyHeader($0,shown: shown,labels: labels) },highlighted: flashed == m.id,
                                           reveal: reveal,files: files[m.id] ?? [],locate: { [model] in await model.attachmentURL($0) })
                            }
                        case .task(let w): TaskCard(model: model,work: w,events: events[w.id] ?? [])
                        }
                    }
                    if model.routing, messages.last?.role == "user" { ThinkingBubble() }
                }.scrollTargetLayout().padding(.horizontal,14).padding(.vertical,12)
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id,initial: true) { _,last in
                position.scrollTo(edge: .bottom)
                if let last { model.markRead(last,thread: id) }
            }
        }
    }

    /// Text only, like a client Mac's composer; files go from the main chat or a client device.
    private var composer: some View {
        let enabled = model.ready && model.runtimeMode.permitsInput(fixtureAcknowledged: model.fixtureAcknowledged) && model.readiness?.state != .blocked
        let canSend = enabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf8.count <= Composer.byteLimit
        return HStack(alignment: .bottom,spacing: 6) {
            ComposerField(text: $draft,placeholder: String(localized: "Message Yorozu"),enabled: enabled,maxHeight: height * Metrics.composerShare,
                          sendKey: { [model] in model.sendKey },submit: { if canSend { send() }; return canSend },take: { _ in false })
                .padding(.horizontal,12).padding(.vertical,6)
                .background(.background,in: RoundedRectangle(cornerRadius: Metrics.fieldRadius,style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Metrics.fieldRadius,style: .continuous).strokeBorder(.separator,lineWidth: 0.5) }
            Button(action: send) {
                Image(systemName: "arrow.up").fontWeight(.bold).frame(width: Metrics.sendSide,height: Metrics.sendSide)
                    .background(canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),in: Circle())
                    .foregroundStyle(canSend ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }.buttonStyle(.plain).disabled(!canSend).help(model.runtimeMode.sendLabel).accessibilityLabel(model.runtimeMode.sendLabel)
        }.padding(.horizontal,10).padding(.vertical,8)
    }

    private func send() {
        let text = draft
        draft = ""
        Task {
            if await model.send(text,thread: id) { sent() } else if draft.isEmpty { draft = text }
        }
    }

    /// Scrolls to a message and rings it for two seconds.
    private func reveal(_ id: String) {
        withAnimation(.snappy) { position.scrollTo(id: id,anchor: .center) }
        flashed = id
        Task { try? await Task.sleep(for: .seconds(2)); if flashed == id { flashed = nil } }
    }
}

/// One task: its state, instruction and error, its steps behind a disclosure (open while it runs), and Stop or Retry.
/// Their acknowledgments and refusals are posted in the sub-chat, as a typed stop or retry's are.
private struct TaskCard: View {
    @ObservedObject var model: AppModel
    let work: Work, events: [WorkerEvent]
    @State private var expanded: Bool?
    @State private var busy = false
    private enum Metrics { static let radius: CGFloat = 10, padding: CGFloat = 10 }

    var body: some View {
        VStack(alignment: .leading,spacing: 6) {
            HStack(spacing: 6) {
                state
                Spacer()
                if work.active || work.state == "uncertain" {
                    Button("Stop") { control(.stop) }.disabled(busy || work.state == "cancellation_requested")
                }
                if ["failed","uncertain"].contains(work.state) {
                    Button("Retry") { control(.retry) }.disabled(busy)
                }
            }.controlSize(.small)
            Text(work.instruction).lineLimit(isExpanded ? nil : 3).textSelection(.enabled)
            if let error = work.error, !error.isEmpty {
                Label { Text(error).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(ChatPalette.warning) }.font(.callout)
            }
            if !events.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { isExpanded },set: { expanded = $0 })) {
                    LazyVStack(alignment: .leading,spacing: 4) { ForEach(events) { EventRow(event: $0) } }.padding(.top,4)
                } label: { Text("Activity · ^[\(events.count) step](inflect: true)").font(.callout).foregroundStyle(.secondary) }
            }
        }
        .padding(Metrics.padding).frame(maxWidth: .infinity,alignment: .leading)
        .background(.quaternary.opacity(0.4),in: RoundedRectangle(cornerRadius: Metrics.radius,style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Metrics.radius,style: .continuous).strokeBorder(.separator,lineWidth: 0.5) }
    }

    private var isExpanded: Bool { expanded ?? work.active }

    @ViewBuilder private var state: some View {
        let label = Self.label(work.state)
        if work.active && work.state != "cancellation_requested" {
            Label { Text(label) } icon: { ProgressView().controlSize(.mini) }.font(.callout.weight(.semibold))
        } else {
            let warn = ["failed","uncertain","cancellation_requested"].contains(work.state)
            Label(label,systemImage: warn ? "exclamationmark.triangle" : work.state == "done" ? "checkmark.circle" : "circle")
                .font(.callout.weight(.semibold)).foregroundStyle(warn ? ChatPalette.warning : .secondary)
        }
    }

    static func label(_ state: String) -> String {
        switch state {
        case "queued": String(localized: "Queued")
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

    private func control(_ action: TaskControlData.Action) {
        busy = true
        Task { await model.control(task: work.id,action); busy = false }
    }
}
