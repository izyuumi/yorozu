import SwiftUI
import YorozuWire

/// The one conversation: the Mac's main chat with day separators, a working indicator while it has
/// a turn running, and the composer. The view stays where the user is reading; new messages below
/// raise a "↓ N new" pill, and sending jumps to the bottom.
struct ChatScreen: View {
    @Bindable var model: PhoneModel
    let onRepair: () -> Void

    @State private var settings = false
    @State private var details: PhoneModel.Bubble?
    @State private var position = ScrollPosition(edge: .bottom)
    /// The view shows the newest message, so new ones are followed rather than counted.
    @State private var atBottom = true
    /// The newest message on screen the last time the view was at the bottom: the pill counts past it.
    @State private var seenId: String?

    /// How far above the end the view still counts as at the bottom.
    private static let bottomSlack: CGFloat = 24

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                    let byId = Dictionary(model.bubbles.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                    ForEach(rows) { row in
                        VStack(spacing: LayoutMetrics.stack) {
                            if let day = row.day {
                                Text(day)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                            MessageRow(
                                bubble: row.bubble, header: header(for: row.bubble, in: byId),
                                onShowRequest: { show(row.bubble.replyTo) },
                                onShowDetails: { details = row.bubble })
                        }
                        .id(row.id)
                    }
                    if model.working == true {
                        ProgressView().accessibilityLabel("Working…")
                    }
                }
                .padding(LayoutMetrics.gutter)
                // Prose stops at a reading width; a no-op on a phone.
                .frame(maxWidth: LayoutMetrics.readingWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition($position)
            // Only the first layout starts at the bottom; later growth leaves the reading position alone.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: ScrollEdge.self) { geometry in
                ScrollEdge(offset: geometry.contentOffset.y,
                           maxOffset: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
            } action: { old, new in
                if new.offset == old.offset, new.maxOffset > old.maxOffset {
                    // Content grew (a message, a longer answer, the keyboard): follow it only from the bottom.
                    if atBottom { position.scrollTo(edge: .bottom) }
                } else {
                    atBottom = new.offset >= new.maxOffset - Self.bottomSlack
                }
                if atBottom { seenId = model.bubbles.last?.id }
            }
            .onChange(of: model.bubbles.last?.id) { _, _ in
                guard let last = model.bubbles.last else { return }
                if atBottom {
                    position.scrollTo(edge: .bottom)
                    seenId = last.id
                }
            }
            .overlay {
                if model.bubbles.isEmpty && model.working != true {
                    EmptyChat { model.draft = $0 }
                }
            }
            .overlay(alignment: .bottom) {
                if !atBottom && newCount > 0 {
                    NewMessagesPill(count: newCount) {
                        withAnimation { position.scrollTo(edge: .bottom) }
                    }
                    .padding(.bottom, LayoutMetrics.inner)
                }
            }
            .yorozuBottomBar {
                VStack(spacing: 0) {
                    // Words as well as the dot, so the state is never told by colour alone.
                    if model.shownStatus != .connected {
                        // Off the link the Mac's work state is unknown, never idle.
                        Text(model.updateRequired ?? String(localized: "\(model.shownStatus.label) · Status unknown"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let sendError = model.sendError {
                        Label { Text(sendError) } icon: {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        }
                        .font(.footnote)
                        .padding(.horizontal, LayoutMetrics.gutter)
                    }
                    Composer(text: $model.draft, working: model.working == true, enabled: model.canSend) {
                        // Sending jumps to the bottom, so the sent message and its answer are followed.
                        atBottom = true
                        position.scrollTo(edge: .bottom)
                        Task { await model.send() }
                    }
                }
            }
            .navigationTitle("Yorozu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: Self.dot, height: Self.dot)
                        .accessibilityElement()
                        .accessibilityLabel(model.shownStatus.label)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { settings = true }
                }
            }
            .sheet(isPresented: $settings) {
                SettingsSheet(model: model) {
                    settings = false
                    onRepair()
                }
            }
            .sheet(item: $details) { MessageDetails(bubble: $0) }
        }
        .yorozuTint()
    }

    private static let dot: CGFloat = 8

    private var dotColor: Color {
        switch model.shownStatus {
        case .connected: YorozuPalette.sage
        case .hostOffline: YorozuPalette.warning
        case .failed: YorozuPalette.vermilion
        case .connecting, .offline: Color.secondary
        }
    }

    /// Messages below the last one seen at the bottom.
    private var newCount: Int {
        guard let seenId, let index = model.bubbles.lastIndex(where: { $0.id == seenId }) else { return 0 }
        return model.bubbles.count - 1 - index
    }

    /// Each message, with a day separator before the first message of each day.
    private var rows: [TimelineRow] {
        var previous: Date?
        return model.bubbles.map { bubble in
            let date = MessageTime.date(bubble.ts)
            defer { previous = date }
            let newDay = previous.map { !Calendar.current.isDate($0, inSameDayAs: date) } ?? true
            return TimelineRow(bubble: bubble, day: newDay ? MessageTime.day.string(from: date) : nil)
        }
    }

    /// The reply header of an answer: the request when the phone holds it, else the topic's label (a job result
    /// replies to its run trigger, which the Mac never sends). Old results that still carry the stored
    /// `Regarding “…”:` prefix are shown as stored, without a header.
    private func header(for bubble: PhoneModel.Bubble, in byId: [String: PhoneModel.Bubble]) -> ReplyHeader? {
        let stored = bubble.text.hasPrefix("Regarding “") && bubble.text.contains("”:\n\n")
        guard RowStyle(bubble) == .answer, !stored, let id = bubble.replyTo else { return nil }
        if let request = byId[id] { return ReplyHeader(text: request.shownText, revealable: true) }
        return bubble.topicId.flatMap { model.topics[$0]?.label }.map { ReplyHeader(text: $0, revealable: false) }
    }

    private func show(_ id: String?) {
        guard let id else { return }
        withAnimation { position.scrollTo(id: id, anchor: .top) }
    }
}

private struct TimelineRow: Identifiable {
    let bubble: PhoneModel.Bubble
    /// The day separator drawn above this message, if it starts a day.
    let day: String?
    var id: String { bubble.id }
}

private struct ScrollEdge: Equatable {
    var offset: CGFloat
    var maxOffset: CGFloat
}

/// "↓ N new": back to the bottom.
private struct NewMessagesPill: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("\(count) new", systemImage: "arrow.down")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, LayoutMetrics.gutter)
                .padding(.vertical, LayoutMetrics.inner)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .yorozuGlass(in: Capsule())
    }
}

/// What Yorozu does, and an example that fills the composer when tapped.
private struct EmptyChat: View {
    let onExample: (String) -> Void

    private var example: String {
        String(localized: "Find three quiet mechanical keyboards under ¥25,000 and pick one.")
    }

    var body: some View {
        ContentUnavailableView {
            Label("Ask Yorozu anything", systemImage: "text.bubble")
        } description: {
            Text("Quick questions are answered right here. Bigger work (research, writing, code) runs on your Mac in the background, and the result comes back to this chat.")
        } actions: {
            VStack(spacing: LayoutMetrics.stack) {
                Text("For example")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button { onExample(example) } label: {
                    Text(example).multilineTextAlignment(.leading)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .foregroundStyle(.primary)
                Text("Yorozu remembers what matters on its own.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Status, Repair, Remove and the version.
private struct SettingsSheet: View {
    let model: PhoneModel
    let onRepair: () -> Void

    @State private var removing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Status", value: model.status.label)
                    if let hostName = model.hostName { LabeledContent("Mac", value: hostName) }
                    if let failure = model.failure {
                        Text(failure).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Repair connection", action: onRepair)
                    Button("Remove host", role: .destructive) { removing = true }
                }
                Section {
                    LabeledContent("Version", value: Self.version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Remove host?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove host", role: .destructive) {
                    Task { await model.remove() }
                    dismiss()
                }
            }
        }
        .yorozuTint()
    }

    private static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()
}
