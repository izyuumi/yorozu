import SwiftUI
import YorozuShared

/// The one thread. Threads and history arrive in later tickets.
struct ChatView: View {
    @Bindable var model: ChatModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.ownerOnline {
                    Banner(
                        text: "Mac offline — messages are held by the relay until it returns.",
                        systemImage: "desktopcomputer.trianglebadge.exclamationmark"
                    )
                }
                if let failure = model.failure {
                    Banner(text: failure, systemImage: "exclamationmark.triangle")
                }
                messages
                composer
            }
            .agentTraceDestination { model.events }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Unpair", systemImage: "qrcode") { model.unpair() }
            }
        }
        .task { model.start() }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // A delegation collapses to one card where it started; what the specialist
                    // did is behind it, and the main agent's own tool use is behind the row.
                    ForEach(chatRows(from: model.events)) { row in
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
                                ) { model.answer(card.actionId, $0) }
                                .id(event.id)
                            }
                        }
                    }
                    MainActivityRow(events: model.events)
                }
                .padding()
            }
            .onChange(of: model.events.last?.id) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $model.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .onSubmit(model.send)
            Button("Send", systemImage: "arrow.up.circle.fill", action: model.send)
                .labelStyle(.iconOnly)
                .font(.title2)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(.bar)
    }
}

private struct Bubble: View {
    let data: MessageData

    var body: some View {
        Text(data.text)
            .padding(10)
            .background(data.role == .user ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
            .background(Color(.secondarySystemBackground))
    }
}
