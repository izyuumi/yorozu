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
    /// Every sub-chat but the jobs' (Scheduled has those) and the archived ones, newest activity first.
    func activities(excluding jobs: Set<String>) -> [Activity] {
        let tasks = Dictionary(grouping: work,by: \.topicID)
        var last = Dictionary(topics.map { ($0.id,$0.created) }) { a,_ in a }
        for m in messages { if let t = m.topicID { last[t] = max(last[t] ?? 0,m.created) } }
        for w in work { last[w.topicID] = max(last[w.topicID] ?? 0,w.created) }
        return topics.filter { !jobs.contains($0.id) && $0.deletedAt == nil && $0.archivedAt == nil }
            .map { Activity(topic: $0,state: ActivityState(tasks[$0.id] ?? []),last: last[$0.id] ?? $0.created) }
            .sorted { $0.last > $1.last }
    }
}

/// The chat window (owner, 2026-10-13; sections 2026-10-14): three columns, like Mail. The sidebar has the sections, Chats
/// and Scheduled (the host only: a client Mac runs no jobs), each with a dot while something needs attention, and the
/// search field. Chats lists Main pinned on top and New chat, the threads in Needs attention, Running and Recent, each by
/// latest activity, a page at a time behind Show more, and the archived ones behind Archived; beside it Main or the
/// selected thread with a composer. Scheduled lists the jobs; beside it the selected job's pane. A search shows its hits
/// in the detail column, and a hit opens in Chats, or, for a job run's output, its job in Scheduled.
struct ChatWindow: View {
    static let id = "activities"
    static let main = "main"
    enum Pane: Hashable { case chats, scheduled }
    @ObservedObject var model: AppModel
    @StateObject private var search = ChatSearch()
    @StateObject private var jobs = JobList()
    @State private var pane: Pane? = .chats
    @State private var selection: String?
    @State private var job: String?
    /// A step of the selected job's chat a search hit asked for.
    @State private var jobFocus: String?
    @State private var deletingJob: JobStatus?
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// A New chat not sent yet: shown as an empty thread until its first message creates it.
    @State private var draftThread: String?
    @State private var archivedShown = false
    @State private var renaming: ChatRow?
    @State private var name = ""
    @State private var deleting: ChatRow?
    private enum Metrics { static let minWidth: CGFloat = 860, minHeight: CGFloat = 480, sections: CGFloat = 160, sidebar: CGFloat = 250 }

    var body: some View { chatDialogs(window) }

    /// Rename and Delete for the list's rows, apart from the window so each type-checks in time.
    private func chatDialogs<Content: View>(_ content: Content) -> some View {
        content
        .alert("Rename Chat",isPresented: Binding(get: { renaming != nil },set: { if !$0 { renaming = nil } }),presenting: renaming) { row in
            TextField("Name",text: $name)
            Button("Rename") { Task { await model.control(thread: row.id,.rename,name: name) } }
            Button("Cancel",role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?",isPresented: Binding(get: { deleting != nil },set: { if !$0 { deleting = nil } }),presenting: deleting) { row in
            // Stop and Delete: the chat goes only once its work's stop is confirmed; otherwise it stays with the reason.
            Button(row.openWork ? String(localized: "Stop and Delete") : String(localized: "Delete"),role: .destructive) {
                Task { await model.control(thread: row.id,row.openWork ? .stopAndDelete : .delete) }
            }
        } message: { row in
            Text(row.isMain ? DeleteWording.main(running: row.openWork) : DeleteWording.message(running: row.openWork))
        }
        .onChange(of: allChatIDs) { _,ids in
            // A deleted chat leaves the detail; a refused one stays, showing why.
            if let id = selection, id != Self.main, id != draftThread, !ids.contains(id), !model.drafts.all.keys.contains(Drafts.new(id)),
               !model.snapshot.topics.contains(where: { $0.id == id && $0.deletedAt == nil }) { selection = nil }
        }
    }

    private var allChatIDs: [String] { (model.chatRows() + model.chatRows(archived: true)).map(\.id) }

    private var window: some View {
        NavigationSplitView {
            List(selection: $pane) {
                SectionRow(title: "Chats",symbol: "bubble.left.and.bubble.right",dot: model.chatRows().contains { $0.dot == .attention })
                    .tag(Pane.chats)
                if !model.isClient { SectionRow(title: "Scheduled",symbol: "clock",dot: jobs.needsAttention).tag(Pane.scheduled) }
            }
            .searchable(text: $query,placement: .sidebar)
            .searchFocused($searchFocused)
            .navigationSplitViewColumnWidth(min: Metrics.sections * 0.8,ideal: Metrics.sections)
        } content: {
            Group {
                if pane == .scheduled { JobsColumn(model: model,list: jobs,selection: $job,deleting: $deletingJob) } else { threadList }
            }
            .navigationSplitViewColumnWidth(min: Metrics.sidebar * 0.8,ideal: Metrics.sidebar)
        } detail: {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SearchResults(model: model,query: query) { open($0) }
            } else if pane == .scheduled {
                if let job = jobs.jobs.first(where: { $0.id == self.job }) {
                    JobDetail(model: model,job: job,problem: $jobs.problem,focus: jobFocus,
                              actions: AnyView(JobActions(model: model,list: jobs,job: job,deleting: $deletingJob))).id(job.id)
                } else { Text("Select a job to see its chat.").foregroundStyle(.secondary).frame(maxWidth: .infinity,maxHeight: .infinity) }
            } else if selection == Self.main {
                VStack(spacing: 0) {
                    // Off (#405): its history stays readable here; new messages go in chats.
                    if !model.mainChat {
                        Label("The Main chat is off. Its history stays here; turn it on in Settings › Chats to write in it.",systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity,alignment: .leading).padding(10)
                        Divider()
                    }
                    MainChat(model: model,search: search,inWindow: true)
                }
            } else if let id = selection {
                let row = (model.chatRows() + model.chatRows(archived: true)).first { $0.id == id }
                ThreadDetail(model: model,id: id,row: row,rename: { start(renaming: $0) },delete: { deleting = $0 },
                             showMain: { message in selection = Self.main; model.focusMessageID = message },
                             sent: { if draftThread == id { draftThread = nil } }).id(id)
            } else {
                Text("Select a chat, or start a new one with ⌘N.").foregroundStyle(.secondary).frame(maxWidth: .infinity,maxHeight: .infinity)
            }
        }
        .background { shortcuts }
        .frame(minWidth: Metrics.minWidth,minHeight: Metrics.minHeight)
        .navigationTitle("Chats")
        .environment(\.openURL,OpenURLAction { url in model.openLink(url) ? .handled : .systemAction })
        // The list follows the store: re-read the loaded rows when anything changed (a cheap, paged query).
        .task(id: model.snapshot) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await model.loadThreads()
        }
        .task(id: archivedShown) { if archivedShown { await model.loadThreads(archived: true) } }
        .onChange(of: model.snapshot) { jobs.refresh(model) }
        .onChange(of: model.jobSpecs) { jobs.refresh(model) }
        // Next runs move on with the clock: a modest poll while the window is open.
        .task { while !Task.isCancelled { jobs.refresh(model); try? await Task.sleep(for: .seconds(30)) } }
        .onChange(of: jobs.jobs.map(\.id)) { _,ids in if !ids.contains(where: { $0 == job }) { job = ids.first } }
        .onChange(of: model.chatFocus,initial: true) { _,focus in
            guard let focus else { return }
            pane = .chats; query = ""; archivedShown = false
            selection = focus.thread ?? Self.main
            if focus.thread == nil { if let m = focus.message { model.focusMessageID = m }; model.chatFocus = nil }
        }
        .onChange(of: selection) { _,_ in model.threadNotice = nil }
        // Opening the window starts a new chat (#405), unless a link or notification asked for a place.
        .onAppear { if model.chatFocus == nil, selection == nil { newChat() } }
        .confirmationDialog("Delete this job?",isPresented: Binding(get: { deletingJob != nil },set: { if !$0 { deletingJob = nil } }),presenting: deletingJob) { job in
            Button("Delete",role: .destructive) { jobs.act(model) { try await $0.deleteJob(job.id) } }
        } message: { job in
            Text("“\(job.name)” is removed from jobs.toml and won’t run again. Its chat and its folder stay.")
        }
    }

    /// One list (#405): New chat drafts, then every chat by its last visible message, the Main chat among them while on.
    private var threadList: some View {
        let rows = model.chatRows(archived: archivedShown)
        return List(selection: $selection) {
            if !archivedShown {
                if let draftThread, model.drafts.saved(Drafts.new(draftThread)).isEmpty {
                    Label("New chat",systemImage: "square.and.pencil").tag(draftThread)
                }
                ForEach(model.drafts.newChats,id: \.id) { item in
                    VStack(alignment: .leading,spacing: 2) {
                        HStack { Text("Draft").fontWeight(.semibold).foregroundStyle(Color.accentColor); Spacer()
                            Text(Date(timeIntervalSince1970: item.draft.updated),format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary) }
                        Text(item.draft.text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }.tag(item.id)
                    .contextMenu { Button("Discard Draft",role: .destructive) { model.drafts.clear(Drafts.new(item.id),discardFiles: true) } }
                }
            }
            ForEach(rows) { row in
                MacChatRow(row: row,refusal: model.client?.threadRefusals[row.id]).tag(row.isMain ? Self.main : row.id)
                    .contextMenu {
                        MacReadMark(model: model,row: row).disabled(!model.canMarkRead || row.time == 0)
                        Divider()
                        ThreadActions(model: model,row: row,rename: start(renaming:),delete: { deleting = $0 })
                    }
                    // Left to right (owner, 2026-10-14): Mark as Read or Unread; never clears orange.
                    .swipeActions(edge: .leading,allowsFullSwipe: true) { if model.canMarkRead, row.time > 0 { MacReadMark(model: model,row: row) } }
                    .swipeActions(edge: .trailing,allowsFullSwipe: true) {
                        do {
                            Button(row.archived ? "Unarchive" : "Archive",systemImage: row.archived ? "tray.and.arrow.up" : "archivebox") {
                                Task { await model.control(thread: row.id,row.archived ? .unarchive : .archive) }
                            }.tint(.indigo)
                        }
                    }
            }
        }
        .overlay {
            if rows.isEmpty && (archivedShown || model.drafts.newChats.isEmpty && draftThread == nil) {
                Text(archivedShown ? "No archived chats" : model.isClient && model.client?.historySynced != true ? "Downloading your chats…" : "No chats yet")
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading,spacing: 4) {
                if let client = model.client, !client.historySynced, client.hasPairing {
                    Label(client.state == .paired ? "Downloading chat history…" : "Chat history is incomplete on this Mac until the host is connected.",
                          systemImage: client.state == .paired ? "arrow.down.circle" : "icloud.slash").font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: $archivedShown) { Label("Archived",systemImage: "archivebox") }
                    .toggleStyle(.button).buttonStyle(.accessoryBar)
            }.frame(maxWidth: .infinity,alignment: .leading).padding(8).background(.bar)
        }
        .toolbar {
            Button { newChat() } label: { Image(systemName: "square.and.pencil") }.help("New chat").accessibilityLabel("New chat")
        }
        .navigationTitle("Chats")
    }

    /// ⌘1 Chats, ⌘2 Scheduled, ⌘N New chat and ⌘F the search field (owner, 2026-10-14).
    private var shortcuts: some View {
        Group {
            Button("Chats") { pane = .chats }.keyboardShortcut("1")
            if !model.isClient { Button("Scheduled") { pane = .scheduled }.keyboardShortcut("2") }
            Button("New chat") { newChat() }.keyboardShortcut("n")
            Button("Search") { searchFocused = true }.keyboardShortcut("f")
        }
        .hidden()
    }

    /// A search hit, in Chats: Main scrolled to it, or its thread at it; a job's run output, in Scheduled: the job's page.
    private func open(_ hit: SearchHit) {
        query = ""
        guard let id = hit.messageID else {
            if let job = jobs.jobs.first(where: { $0.topicID != nil && $0.topicID == hit.topicID }) {
                // A job run's step: its job's page, at that step.
                pane = .scheduled; self.job = job.id; jobFocus = hit.eventID.map { "event-" + $0 }
                return
            }
            // A worker step: its chat, with its task card opened and in view (#405).
            pane = .chats; archivedShown = false
            model.chatFocus = ChatFocus(thread: hit.threadID != "main" ? hit.threadID : hit.topicID,message: nil,task: hit.taskID)
            return
        }
        model.open(message: id)
    }

    private func newChat() {
        // An untouched New chat is reused; one with a draft stays in the list and a fresh one starts.
        let id = draftThread.flatMap { model.drafts.saved(Drafts.new($0)).isEmpty ? $0 : nil } ?? UUID().uuidString.lowercased()
        draftThread = id; archivedShown = false; selection = id; pane = .chats; query = ""
    }

    private func start(renaming row: ChatRow) { name = row.shownName; renaming = row }
}

/// Rename, Archive or Unarchive, and Delete (Stop and Delete while work runs), for a row's context menu and a chat's ⋯ menu.
private struct ThreadActions: View {
    @ObservedObject var model: AppModel
    let row: ChatRow
    let rename: (ChatRow) -> Void
    let delete: (ChatRow) -> Void
    var body: some View {
        Button("Rename…") { rename(row) }
        if !row.archived { Button("Archive") { Task { await model.control(thread: row.id,.archive) } } }
        else { Button("Unarchive") { Task { await model.control(thread: row.id,.unarchive) } } }
        Divider()
        Button(row.openWork ? "Stop and Delete…" : "Delete…",role: .destructive) { delete(row) }
    }
}

/// Mark as Read or Mark as Unread for one row, by its unread state (whatever the dot shows).
private struct MacReadMark: View {
    @ObservedObject var model: AppModel
    let row: ChatRow
    var body: some View {
        Button(row.unread ? "Mark as Read" : "Mark as Unread",systemImage: row.unread ? "envelope.open" : "envelope.badge") {
            Task { await model.setUnread(row,!row.unread) }
        }.tint(.blue)
    }
}

/// One chat (#405): its name, an excerpt of its last message, the time with a small spinner while work runs, one dot.
private struct MacChatRow: View {
    let row: ChatRow
    var refusal: String?
    private enum Metrics { static let dot: CGFloat = 8 }
    var body: some View {
        HStack(alignment: .top,spacing: 6) {
            VStack(alignment: .leading,spacing: 2) {
                Text(row.shownName).fontWeight(.semibold).lineLimit(1)
                Text(row.shownPreview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if let refusal { Text(refusal).font(.caption).foregroundStyle(ChatPalette.warning) }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing,spacing: 4) {
                HStack(spacing: 4) {
                    if row.running { ProgressView().controlSize(.mini) }
                    if row.time > 0 { Text(Self.time(row.time)).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                if let dot = row.dot { Circle().fill(dot == .attention ? Color.orange : Color.blue).frame(width: Metrics.dot,height: Metrics.dot) }
            }
        }
        .padding(.vertical,2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(row))
    }
    static func time(_ ms: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000), calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted,time: .shortened) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let week = calendar.date(byAdding: .day,value: -6,to: .now), date > week { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(date: .numeric,time: .omitted)
    }
    static func label(_ row: ChatRow) -> String {
        var parts = [row.shownName]
        if row.dot == .attention { parts.append(String(localized: "Needs your attention")) }
        if row.unread { parts.append(String(localized: "Unread")) }
        if row.running { parts.append(String(localized: "Working")) }
        if row.archived { parts.append(String(localized: "Archived")) }
        parts += [row.shownPreview,row.time > 0 ? time(row.time) : ""]
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// One thread: its name, summary, origin header and attach links, its messages (the user's on the right, Yorozu's on the
/// left labelled Secretary or Worker) and task cards in time order, then a composer. `row` is nil for a New chat not sent
/// yet, or a thread past the loaded pages (its topic then comes from the snapshot).
private struct ThreadDetail: View {
    @ObservedObject var model: AppModel
    let id: String
    let row: ChatRow?
    let rename: (ChatRow) -> Void
    let delete: (ChatRow) -> Void
    let showMain: (String?) -> Void
    let sent: () -> Void
    @State private var position = ScrollPosition(idType: String.self)
    @State private var draft = ""
    @State private var height: CGFloat = 0
    @State private var flashed: String?
    /// Following the newest message is the reader's intent (#405): only their own scrolling clears it.
    @State private var intent = NewestScrollIntent()
    @State private var phase = ScrollPhase.idle
    @State private var atBottom = true
    @State private var unseen = 0
    @State private var restored = false
    @State private var sending = false
    /// A task a search hit or link asked for: its card opens.
    @State private var openTask: String?
    private enum Metrics { static let rowSpacing: CGFloat = 10, composerShare: CGFloat = 1.0 / 3, sendSide: CGFloat = 28, fieldRadius: CGFloat = 15 }

    private enum Item: Identifiable {
        case day(Date), message(Message), task(Work)
        var id: String { switch self { case .day(let d): "day-\(d.timeIntervalSince1970)"; case .message(let m): m.id; case .task(let w): "task-" + w.id } }
    }

    private var topic: Topic? { model.snapshot.topics.first { $0.id == id && $0.deletedAt == nil } }
    /// A New chat not sent yet keeps its draft as one; once its chat exists, as that chat's.
    private var draftKey: String { topic == nil ? Drafts.new(id) : Drafts.chat(id) }

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
        // The draft this chat had (#405), kept as it is typed.
        .onAppear { draft = model.drafts.saved(draftKey).text }
        .onChange(of: draft) { _,text in model.drafts.update(draftKey,text: text) }
        .onChange(of: model.chatFocus,initial: true) { _,focus in
            guard let focus, focus.thread == id, focus.message != nil || focus.task != nil else { return }
            model.chatFocus = nil
            if let task = focus.task { openTask = task }
            Task { try? await Task.sleep(for: .milliseconds(200)); reveal(focus.message ?? "task-" + (focus.task ?? "")) }
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
                        case .task(let w): TaskCard(model: model,work: w,events: events[w.id] ?? [],forceOpen: openTask == w.id)
                        }
                    }
                    if model.routing, messages.last?.role == "user" { ThinkingBubble() }
                }.scrollTargetLayout().padding(.horizontal,14).padding(.vertical,12)
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom,for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.maxY >= $0.contentSize.height - 24 } action: { _,bottom in
                atBottom = bottom; intent.observe(atBottom: bottom,phase: phase)
                if bottom { unseen = 0; if restored { ReadingPositions.set(nil,chat: id) }; if let last = messages.last?.id { model.markRead(last,thread: id) } }
            }
            // Rows sizing themselves or a growing task card: keep the newest in view while following it.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _,_ in if restored, intent.shouldPinLatest(during: phase) { position.scrollTo(edge: .bottom) } }
            .onScrollPhaseChange { _,next in phase = next; intent.observe(atBottom: atBottom,phase: next) }
            .onScrollTargetVisibilityChange(idType: String.self) { ids in
                if restored, !intent.followsLatest, let first = ids.first(where: { !$0.hasPrefix("day-") }) { ReadingPositions.set(first,chat: id) }
            }
            .onChange(of: messages.last?.id) { _,last in
                // Follow only a reader at the bottom; one reading older messages stays put and the pill counts.
                if intent.followsLatest { position.scrollTo(edge: .bottom); if let last { model.markRead(last,thread: id) } } else { unseen += 1 }
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button { intent.followLatest(); unseen = 0; withAnimation(.snappy) { position.scrollTo(edge: .bottom) } } label: {
                        Image(systemName: "arrow.down").font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor).padding(8)
                            .background(.thickMaterial,in: Circle()).overlay { Circle().strokeBorder(.separator,lineWidth: 0.5) }
                    }.buttonStyle(.plain).padding(.bottom,10)
                        .accessibilityLabel(unseen > 0 ? Text("\(unseen) new messages, scroll to bottom") : Text("Scroll to bottom"))
                }
            }
            .task {
                // Where the reader left this chat, unless a link asked for a message.
                if model.chatFocus?.thread != id, let mark = ReadingPositions.get(id), items.contains(where: { $0.id == mark }) {
                    try? await Task.sleep(for: .milliseconds(100))
                    intent.targetMessage(); position.scrollTo(id: mark,anchor: .top)
                    // Opening still clears Mark as Unread; the cursor stays where it was (an older message never moves it).
                    if let first = messages.first?.id { model.markRead(first,thread: id,explicit: true) }
                } else if let last = messages.last?.id { model.markRead(last,thread: id,explicit: true) } // opening clears Mark as Unread
                try? await Task.sleep(for: .milliseconds(300))
                restored = true
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

    /// The draft stays in the field until the send succeeds; then it clears only if it is still what was sent, so text typed
    /// meanwhile is kept, and a failed send keeps its text.
    private func send() {
        let text = draft, key = draftKey
        guard !sending else { return }
        sending = true
        intent.followLatest()
        Task {
            defer { sending = false }
            guard await model.send(text,thread: id,draftKey: key) else { return }
            if key != Drafts.new(id), model.drafts.saved(Drafts.new(id)).text == text { model.drafts.clear(Drafts.new(id)) }
            if draft == text { draft = "" }
            sent()
        }
    }

    /// Scrolls to a message and rings it for two seconds.
    private func reveal(_ id: String) {
        intent.targetMessage()
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
    var forceOpen = false
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

    private var isExpanded: Bool { expanded ?? (forceOpen || work.active) }

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

/// A section in the window's sidebar, with a small dot (no number) while something in it needs attention.
private struct SectionRow: View {
    let title: LocalizedStringKey, symbol: String, dot: Bool
    private enum Metrics { static let dot: CGFloat = 7 }
    var body: some View {
        HStack {
            Label(title,systemImage: symbol)
            Spacer(minLength: 0)
            if dot { Circle().fill(ChatPalette.warning).frame(width: Metrics.dot,height: Metrics.dot).accessibilityLabel("Needs attention") }
        }
    }
}

/// The window's search: hits across the main chat, threads and their work, newest first. A hit opens in Chats.
private struct SearchResults: View {
    @ObservedObject var model: AppModel
    let query: String
    let open: (SearchHit) -> Void
    @State private var hits: [SearchHit] = []
    @State private var total = 0
    @State private var failure: String?
    @State private var searching = false
    /// Archived chats are searched too (#405), marked; this leaves them out.
    @State private var hideArchived = false
    private static let limit = 300

    var body: some View {
        let labels = Dictionary(model.snapshot.topics.map { ($0.id,$0.label) }) { a,_ in a }
        let archived = Set(model.snapshot.topics.filter { $0.archivedAt != nil }.map(\.id))
        let isArchived = { (hit: SearchHit) in [hit.threadID,hit.topicID ?? ""].contains { archived.contains($0) } }
        let shown = hideArchived ? hits.filter { !isArchived($0) } : hits
        List {
            Section {
                ForEach(shown.indices,id: \.self) { i in
                    let hit = shown[i]
                    Button { open(hit) } label: {
                        VStack(alignment: .leading,spacing: 2) {
                            HStack {
                                Text(hit.threadID != "main" ? labels[hit.threadID] ?? "" : hit.topicID.flatMap { labels[$0] } ?? String(localized: "Main chat"))
                                    .fontWeight(.semibold).lineLimit(1)
                                if isArchived(hit) { Text("Archived").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal,5).background(.quaternary,in: Capsule()) }
                                Spacer(minLength: 4)
                                Text(Date(timeIntervalSince1970: hit.created),format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(hit.snippet).foregroundStyle(.secondary).lineLimit(3)
                        }.frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            } header: {
                HStack {
                    if let failure { Text(failure) }
                    else if !searching { Text(shown.isEmpty ? String(localized: "No matches") : String(localized: "\(shown.count) results")) }
                    Spacer()
                    Toggle("Include archived chats",isOn: Binding(get: { !hideArchived },set: { hideArchived = !$0 })).toggleStyle(.checkbox).controlSize(.small)
                }
            }
        }
        .navigationTitle("Search")
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            searching = true; defer { searching = false }
            do {
                let found = try await model.search(query.trimmingCharacters(in: .whitespacesAndNewlines),limit: Self.limit)
                guard !Task.isCancelled else { return }
                hits = found.hits; total = found.total; failure = nil
            } catch { if !Task.isCancelled { hits = []; failure = error.localizedDescription } }
        }
    }
}
