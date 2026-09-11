import SwiftUI

/// One thread's messages, shared by both apps: the phone pushes it from ``ThreadListView``, the
/// Mac shows it as the detail half of its split view. Either way it has to sit inside a
/// navigation stack, which is what the trace drill-down pushes onto.
public struct ChatView: View {
    public let model: ChatModel
    public let thread: ThreadSummary
    /// Shown while the runtime is unreachable. The two apps lose it differently: the phone's
    /// frames are buffered by the relay, the Mac's sidecar is simply not running yet.
    public let offlineNotice: String

    public init(
        model: ChatModel,
        thread: ThreadSummary,
        offlineNotice: String = "Mac offline — messages are held by the relay until it returns."
    ) {
        self.model = model
        self.thread = thread
        self.offlineNotice = offlineNotice
    }

    private var events: [YorozuEvent] { model.events[thread.id] ?? [] }

    private var draft: Binding<String> {
        Binding(get: { model.drafts[thread.id] ?? "" }, set: { model.drafts[thread.id] = $0 })
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !model.ownerOnline {
                Banner(text: offlineNotice, systemImage: "desktopcomputer.trianglebadge.exclamationmark")
            }
            if let failure = model.failure {
                Banner(text: failure, systemImage: "exclamationmark.triangle")
            }
            messages
            composer
        }
        // Inside the stack: a trace pushed from here keeps streaming this thread.
        .agentTraceDestination { events }
        .navigationTitle(thread.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // A delegation collapses to one card where it started; what the specialist
                    // did is behind it, and the main agent's own tool use is behind the row.
                    ForEach(chatRows(from: events)) { row in
                        switch row {
                        case .message(let event):
                            if case .message(let data) = event.payload {
                                Bubble(data: data).id(event.id)
                            }
                        case .delegation(let card):
                            DelegationCardView(card: card).id(card.id)
                        case .approval(let event):
                            if case .approvalCard(let card) = event.payload {
                                ApprovalCardView(
                                    card: card,
                                    answered: model.answered.contains(card.actionId)
                                ) { model.answer(card.actionId, in: thread.id, $0) }
                                .id(event.id)
                            }
                        }
                    }
                    MainActivityRow(events: events)
                }
                .padding()
            }
            .onChange(of: events.last?.id) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message", text: draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit { model.send(in: thread) }
            Button("Send", systemImage: "arrow.up.circle.fill") { model.send(in: thread) }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.plain)
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(.bar)
    }
}

/// Semantic fills rather than UIKit colours: the same bubble has to draw on both platforms.
private struct Bubble: View {
    let data: MessageData

    var body: some View {
        Text(data.text)
            .textSelection(.enabled)
            .padding(10)
            .background(
                data.role == .user ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .frame(maxWidth: .infinity, alignment: data.role == .user ? .trailing : .leading)
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary)
    }
}
