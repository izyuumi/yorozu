import SwiftUI
import AppKit
import ProjectXCore

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
        return topics.filter { !jobs.contains($0.id) }
            .map { Activity(topic: $0,state: ActivityState(tasks[$0.id] ?? []),last: last[$0.id] ?? $0.created) }
            .sorted { $0.last > $1.last }
    }
}

/// The Activities window: the sub-chats where workers do the substantive work, in Needs attention, Running and Recent,
/// and the selected one's messages and tasks with Stop and Retry. The phone's sub-chats, on the Mac.
struct ActivitiesView: View {
    static let id = "activities"
    @ObservedObject var model: AppModel
    @State private var selection: String?
    private enum Metrics { static let minWidth: CGFloat = 680, minHeight: CGFloat = 460, sidebar: CGFloat = 240 }

    var body: some View {
        let all = model.snapshot.activities(excluding: model.jobTopics)
        NavigationSplitView {
            List(selection: $selection) {
                section("Needs attention",all.filter { $0.state == .attention })
                section("Running",all.filter { $0.state == .running })
                section("Recent",all.filter { $0.state > .running })
            }
            .overlay { if all.isEmpty { ContentUnavailableView("No activities yet",systemImage: "bubble.left.and.bubble.right",description: Text("Bigger work runs in its own sub-chat; it shows here.")) } }
            .navigationSplitViewColumnWidth(min: Metrics.sidebar * 0.8,ideal: Metrics.sidebar)
        } detail: {
            if let activity = all.first(where: { $0.id == selection }) {
                ActivityDetail(model: model,activity: activity,select: { selection = $0 }).id(activity.id)
            } else {
                Text("Select an activity to see its sub-chat.").foregroundStyle(.secondary).frame(maxWidth: .infinity,maxHeight: .infinity)
            }
        }
        .frame(minWidth: Metrics.minWidth,minHeight: Metrics.minHeight)
        .navigationTitle("Activities")
        .onAppear { if selection == nil { selection = all.first?.id } }
    }

    @ViewBuilder private func section(_ title: LocalizedStringKey,_ items: [Activity]) -> some View {
        if !items.isEmpty {
            Section(title) { ForEach(items) { ActivityRow(activity: $0).tag($0.id) } }
        }
    }
}

private struct ActivityRow: View {
    let activity: Activity
    var body: some View {
        VStack(alignment: .leading,spacing: 2) {
            HStack(spacing: 6) {
                Text(activity.topic.label).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                Text(Date(timeIntervalSince1970: activity.last),format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let summary = activity.topic.summary, !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ActivityStateLabel(state: activity.state).font(.caption)
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

/// The selected sub-chat: its label, summary and attach links, then its messages and task cards in time order.
private struct ActivityDetail: View {
    @ObservedObject var model: AppModel
    let activity: Activity
    let select: (String) -> Void
    @State private var position = ScrollPosition(idType: String.self)
    private enum Metrics { static let rowSpacing: CGFloat = 10 }

    private enum Item: Identifiable {
        case day(Date), message(Message), task(Work)
        var id: String { switch self { case .day(let d): "day-\(d.timeIntervalSince1970)"; case .message(let m): m.id; case .task(let w): "task-" + w.id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            chat.frame(maxHeight: .infinity)
        }
    }

    private var header: some View {
        let s = model.snapshot, topic = activity.topic
        let labels = Dictionary(s.topics.map { ($0.id,$0.label) }) { a,_ in a }
        return VStack(alignment: .leading,spacing: 4) {
            Text(topic.label).font(.headline).lineLimit(2)
            if let summary = topic.summary, !summary.isEmpty { Text(summary).foregroundStyle(.secondary).lineLimit(3) }
            // #348: an attached sub-chat links to its topic; a topic lists the sub-chats attached to it.
            if let target = topic.attachedTo, let label = labels[target] {
                Button("Attached to “\(label)”") { select(target) }.buttonStyle(.link)
            }
            ForEach(s.topics.filter { $0.attachedTo == topic.id },id: \.id) { sub in
                Button("“\(sub.label)” was attached here") { select(sub.id) }.buttonStyle(.link)
            }
        }.font(.callout).frame(maxWidth: .infinity,alignment: .leading).padding(12)
    }

    @ViewBuilder private var chat: some View {
        let s = model.snapshot, topic = activity.topic.id
        let tasks = s.work.filter { $0.topicID == topic }
        let ids = Set(tasks.map(\.id))
        let events = Dictionary(grouping: s.events.filter { ids.contains($0.taskID) },by: \.taskID)
        let messages = s.messages.filter { $0.topicID == topic }
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
            Text("Nothing here yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity,maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading,spacing: Metrics.rowSpacing) {
                    ForEach(items) { item in
                        switch item {
                        case .day(let day): DaySeparator(day: day)
                        case .message(let m):
                            MessageRow(message: m,header: m.replyTo.flatMap { byID[$0] }.map { ReplyHeader($0,shown: shown,labels: labels) },highlighted: false,
                                       reveal: { id in withAnimation(.snappy) { position.scrollTo(id: id,anchor: .center) } },files: files[m.id] ?? [],locate: { [model] in await model.attachmentURL($0) })
                        case .task(let w): TaskCard(model: model,work: w,events: events[w.id] ?? [])
                        }
                    }
                }.scrollTargetLayout().padding(.horizontal,14).padding(.vertical,12)
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
        }
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
                    Button("Stop") { control { await $0.stopTask(id: work.id) } }.disabled(busy || work.state == "cancellation_requested")
                }
                if ["failed","uncertain"].contains(work.state) {
                    Button("Retry") { control { await $0.retryTask(id: work.id) } }.disabled(busy)
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

    private func control(_ act: @escaping (Engine) async -> TaskOutcome) {
        guard let engine = model.engine else { return }
        busy = true
        Task { _ = await act(engine); busy = false }
    }
}
