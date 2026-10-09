import SwiftUI
import ProjectXCore

/// Whether layout changes keep the viewport on the newest message. `atBottom` is an observation, not intent: lazy rows
/// sizing themselves can make it false without the reader doing anything. Only a scroll by the reader or a jump to a
/// chosen message opts out; reaching or jumping to the bottom opts back in. (Ported from v1's chat.)
struct NewestScrollIntent {
    private(set) var followsLatest = true
    mutating func observe(atBottom: Bool,phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting: followsLatest = false
        case .idle, .animating, .decelerating: if atBottom { followsLatest = true }
        }
    }
    mutating func followLatest() { followsLatest = true }
    mutating func targetMessage() { followsLatest = false }
    func shouldPinLatest(during phase: ScrollPhase) -> Bool {
        guard followsLatest else { return false }
        return switch phase { case .tracking, .interacting, .decelerating: false; case .idle, .animating: true }
    }
}

/// A timeline row: a day separator before each day's first message, or the message.
enum TimelineItem: Identifiable {
    case day(Date), message(Message)
    var id: String {
        switch self { case .day(let d): "day-\(d.timeIntervalSince1970)"; case .message(let m): m.id }
    }
    static func items(_ messages: [Message]) -> [TimelineItem] {
        var out: [TimelineItem] = []; var last: Date?
        for m in messages {
            let day = Calendar.current.startOfDay(for: m.date)
            if day != last { out.append(.day(day)); last = day }
            out.append(.message(m))
        }
        return out
    }
}

/// The main chat: the timeline over the composer. Stays put while the reader is scrolled up, offers "↓ N new", jumps to
/// the bottom on send, and scrolls to a message the host or a search asks for.
struct MainChat: View {
    @ObservedObject var model: AppModel
    @ObservedObject var search: ChatSearch
    @State private var position = ScrollPosition(idType: String.self)
    @State private var intent = NewestScrollIntent()
    @State private var phase = ScrollPhase.idle
    @State private var atBottom = true
    /// The newest message seen at the bottom of the open popover; later ones count as new.
    @State private var seenID: String?
    /// A message briefly ringed after a jump to it.
    @State private var flashed: String?
    @State private var height: CGFloat = 0
    private enum Metrics {
        /// How near the end still counts as the bottom.
        static let bottomSlack: CGFloat = 24
        static let rowSpacing: CGFloat = 10
        /// The composer grows to at most this share of the popover's height.
        static let composerShare: CGFloat = 1.0 / 3
    }
    var body: some View {
        let timeline = model.timeline
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if timeline.isEmpty { EmptyChat(model: model) } else { scroll(timeline) }
                if !timeline.isEmpty && !atBottom { pill(unseen(timeline)).padding(.bottom,10) }
            }.frame(maxHeight: .infinity)
            Divider()
            Composer(model: model,maxHeight: height * Metrics.composerShare,send: send)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onChange(of: model.popoverShown) { _,shown in if shown { model.onBottomChanged?(atBottom); markSeen() } }
    }

    private func scroll(_ timeline: [Message]) -> some View {
        // All messages, not just the timeline: a job result replies to its run trigger, which stays in the sub-chat.
        let requests = Dictionary(model.snapshot.messages.map { ($0.id,$0) }) { a,_ in a }
        return ScrollView {
            LazyVStack(alignment: .leading,spacing: Metrics.rowSpacing) {
                ForEach(TimelineItem.items(timeline)) { item in
                    switch item {
                    case .day(let day): DaySeparator(day: day)
                    case .message(let m):
                        MessageRow(message: m,request: m.replyTo.flatMap { requests[$0] },highlighted: flashed == m.id || search.shown && search.current == m.id,reveal: reveal)
                    }
                }
            }.scrollTargetLayout().padding(.horizontal,14).padding(.vertical,12)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom,for: .initialOffset)
        .onScrollGeometryChange(for: Bool.self) { $0.visibleRect.maxY >= $0.contentSize.height - Metrics.bottomSlack } action: { _,bottom in setBottom(bottom) }
        // Rows sizing themselves or a new message: keep the newest in view while following it.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _,_ in if intent.shouldPinLatest(during: phase) { position.scrollTo(edge: .bottom) } }
        .onScrollPhaseChange { _,next in phase = next; intent.observe(atBottom: atBottom,phase: next) }
        .onChange(of: timeline.last?.id) { _,_ in
            if intent.followsLatest { position.scrollTo(edge: .bottom) }
            markSeen(); focusRequested(timeline)
        }
        .onChange(of: model.focusMessageID,initial: true) { _,_ in focusRequested(timeline) }
        .onChange(of: search.current) { _,id in if let id, search.shown { target(id) } }
    }

    private func pill(_ unseen: Int) -> some View {
        Button {
            intent.followLatest(); withAnimation(.snappy) { position.scrollTo(edge: .bottom) }
        } label: {
            Label { if unseen > 0 { Text("\(unseen) new") } } icon: { Image(systemName: "arrow.down") }
                .font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                .padding(.horizontal,12).padding(.vertical,5)
                .background(.thickMaterial,in: Capsule()).overlay { Capsule().strokeBorder(.separator,lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.16),radius: 7,y: 4)
        }.buttonStyle(.plain).accessibilityLabel(unseen > 0 ? Text("\(unseen) new messages, scroll to bottom") : Text("Scroll to bottom"))
    }

    private func unseen(_ timeline: [Message]) -> Int {
        guard let seenID, let i = timeline.lastIndex(where: { $0.id == seenID }) else { return 0 }
        return timeline.count - 1 - i
    }

    private func setBottom(_ bottom: Bool) {
        atBottom = bottom; intent.observe(atBottom: bottom,phase: phase)
        model.popoverAtBottom = bottom
        if model.popoverShown { model.onBottomChanged?(bottom) }
        markSeen()
    }

    /// At the bottom, the newest message counts as seen for the pill and, while the popover shows, for attention.
    private func markSeen() {
        guard atBottom, let last = model.timeline.last?.id else { return }
        seenID = last
        if model.popoverShown { model.onSeen?(last) } // may repeat an id; AttentionCenter treats it as idempotent
    }

    private func send() {
        intent.followLatest(); position.scrollTo(edge: .bottom)
        Task { await model.send() }
    }

    private func target(_ id: String) {
        intent.targetMessage(); withAnimation(.snappy) { position.scrollTo(id: id,anchor: .center) }
    }

    /// Scrolls to a message and rings it for two seconds.
    private func reveal(_ id: String) {
        target(id); flashed = id
        Task { try? await Task.sleep(for: .seconds(2)); if flashed == id { flashed = nil } }
    }

    /// The host's `focusMessageID`, once that message is on the timeline.
    private func focusRequested(_ timeline: [Message]) {
        guard let id = model.focusMessageID, timeline.contains(where: { $0.id == id }) else { return }
        model.focusMessageID = nil; reveal(id)
    }
}
