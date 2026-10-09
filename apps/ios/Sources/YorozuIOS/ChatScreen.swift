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
    @State private var path: [ChatRoute] = []
    /// The read cursor the unread divider is drawn from. It follows the Mac's cursor when another
    /// device moves it, and stays put while this one reads, so the divider does not vanish under the reader.
    @State private var unreadAfter: String?
    /// The last message this phone sent as read.
    @State private var sentRead: String?
    @Environment(\.scenePhase) private var scenePhase

    /// How far above the end the view still counts as at the bottom.
    private static let bottomSlack: CGFloat = 24

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                    let byId = Dictionary(model.bubbles.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
                    let firstUnread = firstUnread
                    ForEach(rows) { row in
                        VStack(spacing: LayoutMetrics.stack) {
                            if let day = row.day {
                                Text(day)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                            if row.id == firstUnread { UnreadDivider() }
                            MessageRow(
                                bubble: row.bubble, header: header(for: row.bubble, in: byId),
                                onShowRequest: { show(row.bubble.replyTo) },
                                onShowDetails: { details = row.bubble })
                        }
                        .id(row.id)
                    }
                    if model.routing == true {
                        ThinkingRow()
                    }
                    if model.working == true {
                        ProgressView().accessibilityLabel("Working…")
                    }
                }
                .scrollTargetLayout()
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
            .navigationSubtitleIfAvailable(model.shownStatus.label)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SubChatsButton(running: model.runningTopics) { path = [.topics] }
                }
                if !Self.hasSubtitle {
                    ToolbarItem(placement: .topBarLeading) {
                        Circle()
                            .fill(dotColor)
                            .frame(width: Self.dot, height: Self.dot)
                            .accessibilityElement()
                            .accessibilityLabel(model.shownStatus.label)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Search", systemImage: "magnifyingglass") { path = [.search] }
                    Button("Settings", systemImage: "gearshape") { settings = true }
                }
            }
            .navigationDestination(for: ChatRoute.self) { route in
                switch route {
                case .topics:
                    TopicsScreen(model: model)
                case .topic(let id, let focus):
                    TopicScreen(model: model, topicId: id, focus: focus) { path = [] }
                case .search:
                    SearchScreen(model: model, onOpen: open) { path.removeLast() }
                case .page(let id):
                    PageScreen(model: model, messageId: id)
                }
            }
            // The Mac's cursor moved by another device (or first loaded) moves the divider; this phone's own
            // does not, nor does any cursor at or before it, so the divider never lands on messages just read.
            .onChange(of: model.readCursor?.messageId, initial: true) { _, id in
                if !atOrBeforeSentRead(id) { unreadAfter = id }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { unreadAfter = model.readCursor?.messageId }
            }
            .onChange(of: readTarget, initial: true) { _, id in markRead(id) }
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

    private static let hasSubtitle: Bool = {
        if #available(iOS 26, *) { return true } else { return false }
    }()

    /// The first message from Yorozu after the read cursor: the user's own messages are never unread.
    private var firstUnread: String? {
        guard let after = unreadAfter, let index = model.bubbles.firstIndex(where: { $0.id == after }) else { return nil }
        return model.bubbles[(index + 1)...].first { !$0.user }?.id
    }

    /// The newest stored message, while it is on screen: the app active, the chat shown, the view at the bottom.
    private var readTarget: String? {
        guard scenePhase == .active, path.isEmpty, !settings, details == nil, atBottom, model.state == .paired else { return nil }
        return model.bubbles.last { $0.seq != nil }?.id
    }

    /// `id` is this phone's last sent read or a message before it, in timeline order.
    private func atOrBeforeSentRead(_ id: String?) -> Bool {
        guard let id, let sentRead else { return false }
        if id == sentRead { return true }
        guard let index = model.bubbles.firstIndex(where: { $0.id == id }),
              let sent = model.bubbles.firstIndex(where: { $0.id == sentRead }) else { return false }
        return index <= sent
    }

    /// Forward only: never a message at or before the Mac's cursor.
    private func markRead(_ id: String?) {
        guard let id, id != sentRead, id != model.readCursor?.messageId else { return }
        if let cursor = model.readCursor?.messageId,
           let held = model.bubbles.firstIndex(where: { $0.id == cursor }),
           let new = model.bubbles.firstIndex(where: { $0.id == id }), new <= held { return }
        sentRead = id
        Task { await model.markRead(id) }
    }

    /// A search hit: the main timeline scrolls to it; a sub-chat opens over the search; a message
    /// outside the cache opens `PageScreen`, which loads its page from the Mac.
    private func open(_ hit: SearchHitData) {
        switch model.target(of: hit) {
        case .main(let id):
            path = []
            atBottom = false
            withAnimation { position.scrollTo(id: id, anchor: .center) }
        case .topic(let topicId, let focus):
            path.append(.topic(topicId, focus: focus))
        case .page(let id):
            path.append(.page(id))
        case .none:
            break
        }
    }
}

/// Sub-chats, with the number of running topics.
private struct SubChatsButton: View {
    let running: Int
    let action: () -> Void

    private let badgeOffset: CGFloat = 8

    var body: some View {
        Button(action: action) {
            Image(systemName: "bubble.left.and.bubble.right")
                .overlay(alignment: .topTrailing) {
                    if running > 0 {
                        Text(verbatim: "\(running)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, LayoutMetrics.tight)
                            .background(YorozuPalette.bubble, in: Capsule())
                            .offset(x: badgeOffset, y: -badgeOffset)
                    }
                }
        }
        .accessibilityLabel("Sub-chats")
        .accessibilityValue(running > 0 ? String(localized: "\(running) running") : "")
    }
}

/// "Unread": above the first message from Yorozu after the read cursor.
private struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: LayoutMetrics.inner) {
            line
            Text("Unread").font(.caption.weight(.semibold))
            line
        }
        .foregroundStyle(.tint)
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle().fill(.tint).frame(height: 1).frame(maxWidth: .infinity).accessibilityHidden(true)
    }
}

/// The secretary is reading a message: a typing-style bubble until it answers or hands the work on.
private struct ThinkingRow: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.title3.weight(.bold))
            .foregroundStyle(.secondary)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers)
            .padding(.horizontal, LayoutMetrics.stack)
            .padding(.vertical, LayoutMetrics.stack)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .accessibilityLabel("Thinking…")
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

/// Connection details, Copy diagnostics, Repair, Remove and both versions.
private struct SettingsSheet: View {
    let model: PhoneModel
    let onRepair: () -> Void

    @State private var removing = false
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Status", value: model.status.label)
                    if let hostName = model.hostName { LabeledContent("Mac", value: hostName) }
                    if let relayHost = model.relayHost { LabeledContent("Relay", value: relayHost) }
                    if let fingerprint = model.fingerprint {
                        LabeledContent("Mac key") {
                            Text(fingerprint).monospaced().textSelection(.enabled)
                        }
                    }
                    if let pairedAt = model.pairedAt {
                        LabeledContent("Paired since") { Text(pairedAt, format: .dateTime.year().month().day()) }
                    }
                    if let lastError = model.lastError {
                        VStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                            LabeledContent("Last error") { Text(lastError.at, format: .relative(presentation: .named)) }
                            Text(lastError.message).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    LabeledContent("Mac version", value: model.macVersion ?? String(localized: "Unknown"))
                    LabeledContent("iPhone version", value: Self.version)
                }
                Section {
                    Button(copied ? String(localized: "Copied") : String(localized: "Copy diagnostics"),
                           systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = diagnostics
                        copied = true
                    }
                    .task(id: copied) {
                        guard copied, (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                        copied = false
                    }
                } footer: {
                    Text("Versions and connection details only: never messages, keys or tokens.")
                }
                Section {
                    Button("Repair connection", action: onRepair)
                    Button("Remove host", role: .destructive) { removing = true }
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

    /// Plain English text for a bug report, whatever the interface language. Only what Settings
    /// shows: no message content, keys (the fingerprint is a prefix of the public key) or tokens.
    private var diagnostics: String {
        let date = { (d: Date) in d.ISO8601Format() }
        return [
            "Yorozu diagnostics \(date(Date()))",
            "iPhone app: \(Self.version)",
            "iOS: \(UIDevice.current.systemVersion)",
            "Mac app: \(model.macVersion ?? "unknown")",
            "Status: \(model.status)",
            "Relay host: \(model.relayHost ?? "none")",
            "Mac key fingerprint: \(model.fingerprint ?? "none")",
            "Paired since: \(model.pairedAt.map(date) ?? "unknown")",
            "Last error: \(model.lastError.map { "\(date($0.at)) \($0.message)" } ?? "none")",
        ].joined(separator: "\n")
    }

    private static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()
}
