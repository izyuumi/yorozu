import SwiftUI
import YorozuWire

/// One conversation: the user's bubbles with their marks, each reply chunk as its own card (replies arrive whole,
/// chunked by length), tool calls collapsed under the message whose run made them, `/new` boundaries, the typing
/// indicator, the composer. Opening it fetches what is newer than the cache; reaching the top loads the page before.
struct V3ChatView: View {
    let model: V3Model
    let convId: String

    @State private var draft = ""
    /// Files in the composer, already copied into `AttachmentFiles` (#430).
    @State private var files: [ChatAttachment] = []
    /// An automation attached from "Edit in Chat": a chip in the composer, part of the text once sent.
    @State private var automation: V3CronJob?
    @State private var dropFailure: String?
    @State private var position = ScrollPosition(edge: .bottom)
    /// The newest message is in view: hides the jump-to-latest button.
    @State private var atBottom = true
    /// How far the timeline is dragged left to show the times, as in Messages (owner, 2026-10-18); 0 at rest.
    @State private var timesShown: CGFloat = 0
    @ScaledMetric(relativeTo: .caption2) private var timesWidth: CGFloat = 64
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let conversation = model.conversations[convId]
        let items = conversation?.items ?? []
        let typing = model.typing.contains(convId)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                if let conversation, conversation.complete != true {
                    // In view at the top: the older page. Again whenever one arrived and the top is still in view.
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .opacity(model.loadingOlder.contains(convId) ? 1 : 0)
                        .task(id: conversation.oldestSeq) { model.loadOlder(convId) }
                }
                ForEach(items) { item in
                    V3ItemRow(model: model, item: item)
                        .readableRow()
                        .modifier(MessageTime(item: item, shown: timesShown, width: timesWidth))
                }
                if typing {
                    TypingIndicator().readableRow().id("typing")
                }
            }
            .padding(.vertical, LayoutMetrics.stack)
            #if os(iOS)
            // A sideways drag, alongside the vertical scroll: the timeline follows the finger left, then springs back.
            .simultaneousGesture(
                DragGesture(minimumDistance: LayoutMetrics.gutter)
                    .onChanged { drag in
                        guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                        timesShown = min(max(-drag.translation.width, 0), timesWidth)
                    }
                    .onEnded { _ in withAnimation(.snappy) { timesShown = 0 } }
            )
            #endif
        }
        .scrollPosition($position)
        // Scrolling the conversation puts the keyboard away, following the finger (owner, 2026-10-17).
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - LayoutMetrics.section * 2
        } action: { _, bottom in
            atBottom = bottom
        }
        .defaultScrollAnchor(.bottom)
        // An older page grows the content upward: what is on screen stays put.
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onChange(of: items.last?.id) { position.scrollTo(edge: .bottom) }
        .task(id: model.state == .ready) { model.open(convId) }
        .onChange(of: typing) { position.scrollTo(edge: .bottom) }
        // Opening reads it on every device (#429), Mark as Unread included; a reply that arrives while it is on screen
        // only moves the cursor, and so does coming back to the foreground with it open.
        .onAppear {
            model.markRead(convId, explicit: true)
            model.setVisible(convId)
        }
        .onDisappear { model.setVisible(nil, leaving: convId) }
        .onChange(of: model.conversations[convId]?.latestReply?.id) { readIfActive() }
        .onChange(of: scenePhase) { readIfActive() }
        .overlay(alignment: .bottom) {
            if !atBottom {
                JumpToLatestButton { withAnimation { position.scrollTo(edge: .bottom) } }
                    .padding(.bottom, LayoutMetrics.inner)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: atBottom)
        .overlay {
            if items.isEmpty && !typing {
                ContentUnavailableView("New conversation", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Your first message starts a new session on the host."))
            }
        }
        .yorozuBottomBar {
            V3Composer(text: $draft, files: $files, automation: $automation, attachLimit: model.attachmentsAvailable ? model.mediaMaxBytes : nil,
                onFiles: attach) {
                model.send(Self.message(draft, automation: automation), attachments: files, in: convId)
                draft = ""
                files = []
                automation = nil
            }
        }
        // Files dropped anywhere on the conversation (the Finder on a Mac, another app on an iPad) join the composer.
        .dropDestination(for: URL.self) { urls, _ in
            guard model.attachmentsAvailable else { return false }
            return attach(urls)
        }
        .alert(String(localized: "Can’t attach"), isPresented: Binding(get: { dropFailure != nil }, set: { if !$0 { dropFailure = nil } })) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(dropFailure ?? "")
        }
        // "Edit in Chat" leaves its automation here, unsent.
        .onChange(of: model.automationDrafts[convId], initial: true) { _, seed in
            guard let seed else { return }
            automation = seed
            model.automationDrafts[convId] = nil
        }
        .navigationTitle(model.conversations[convId]?.displayTitle ?? String(localized: "New Conversation"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationSubtitleIfAvailable(model.state == .ready ? "" : model.state.label)
    }
}

extension V3ChatView {
    /// Files from a drop or a paste: staged when under the host's limit, the rest named in one alert.
    @discardableResult
    private func attach(_ urls: [URL]) -> Bool {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return false }
        var refused: [String] = []
        for url in fileURLs {
            do { files.append(try AttachmentStaging.stage(file: url, limit: model.mediaMaxBytes)) } catch { refused.append(error.localizedDescription) }
        }
        if !refused.isEmpty { dropFailure = refused.joined(separator: "\n") }
        return true
    }

    /// The attached automation goes into the text the agent reads: its name and id, then what the user typed.
    static func message(_ text: String, automation: V3CronJob?) -> String {
        guard let automation else { return text }
        let reference = "Cron job \"\(automation.name)\" (id \(automation.id))"
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? reference : "\(reference): \(typed)"
    }

    private func readIfActive() {
        if scenePhase == .active { model.markRead(convId, explicit: false) }
    }
}

struct V3ItemRow: View {
    let model: V3Model
    let item: ChatItem
    @State private var selecting = false

    var body: some View {
        Group {
            switch item.kind {
            case .user: user
            case .agent: agent
            case .error: error
            case .tools: ToolsRow(calls: item.tools ?? [])
            case .reset: reset
            }
        }
        .sheet(isPresented: $selecting) { SelectTextSheet(text: item.text) }
    }

    /// `/new`: the session started over here; what is above is no longer in the agent's context.
    private var reset: some View {
        HStack(spacing: LayoutMetrics.inner) {
            VStack { Divider() }
            Text("New session").font(.caption).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
            VStack { Divider() }
        }
        .accessibilityElement(children: .combine)
    }

    private var user: some View {
        HStack(spacing: 0) {
            // A bubble stops short of the far edge, so its side says who spoke even when it is long.
            Spacer(minLength: LayoutMetrics.section * 2)
            VStack(alignment: .trailing, spacing: LayoutMetrics.tight) {
                if let files = item.attachments, !files.isEmpty {
                    V3AttachmentList(model: model, attachments: files, alignment: .trailing)
                }
                if !item.text.isEmpty {
                    Text(item.text)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(.horizontal, LayoutMetrics.stack)
                        .padding(.vertical, LayoutMetrics.inner)
                        .background(YorozuPalette.bubble, in: RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous))
                        .contextMenu { copy; selectText }
                        .accessibilityLabel(Text("You: \(item.text)"))
                }
                DeliveryMark(delivery: delivery)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(delivery.word))
            }
        }
    }

    /// The v2 mark's look for v3's steps (#415): queued and sending, ✓ sent, ✓✓ delivered, read.
    private var delivery: Delivery {
        let status = item.status ?? .queued
        return Delivery(state: status == .read ? .read : status >= .sent ? .delivered : .sending,
            inFlight: status == .sending, sent: status >= .sending, sentAt: Int(item.ts), onHost: status >= .delivered)
    }

    private var agent: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
            if !item.text.isEmpty {
                MarkdownBlocks(item.text)
                    .padding(LayoutMetrics.stack)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
                    .contextMenu { copy; selectText }
            }
            if let files = item.attachments, !files.isEmpty {
                V3AttachmentList(model: model, attachments: files, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Amber, not red: red is the mark of a message that did not go out.
    private var error: some View {
        Label { Text(item.text) } icon: {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(YorozuPalette.warning)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private var copy: some View {
        Button(String(localized: "Copy"), systemImage: "doc.on.doc") { UIPasteboard.general.string = item.text }
    }

    private var selectText: some View {
        Button(String(localized: "Select Text"), systemImage: "selection.pin.in.out") { selecting = true }
    }
}

/// A run's tool calls, collapsed to one line; open, each call's name and its last status.
private struct ToolsRow: View {
    let calls: [ToolCall]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                ForEach(calls) { call in
                    Label {
                        Text(call.name).font(.footnote.monospaced())
                    } icon: {
                        icon(call.status)
                    }
                    .accessibilityValue(word(call.status))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label {
                Text("^[\(calls.count) tool call](inflect: true)")
            } icon: {
                if calls.contains(where: { $0.status == .running }) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wrench.and.screwdriver")
                }
            }
            .font(.footnote)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func icon(_ status: V3Tool.Status) -> some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle")
        case .failed: Image(systemName: "xmark.circle").foregroundStyle(YorozuPalette.warning)
        }
    }

    private func word(_ status: V3Tool.Status) -> String {
        switch status {
        case .running: String(localized: "Running")
        case .done: String(localized: "Done")
        case .failed: String(localized: "Failed")
        }
    }
}

/// Each message's time, hidden past the trailing edge until the timeline is dragged left (Messages' gesture): every row
/// slides by the drag and the time slides in after it.
private struct MessageTime: ViewModifier {
    let item: ChatItem
    let shown: CGFloat
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: -shown)
            .overlay(alignment: .trailing) {
                if shown > 0, item.kind == .user || item.kind == .agent || item.kind == .error {
                    Text(Date(timeIntervalSince1970: TimeInterval(item.ts) / 1000), format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: width, alignment: .leading)
                        .offset(x: width - shown)
                        .opacity(shown / width)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// A small glass circle at the bottom centre while the newest message is out of view: back to it.
private struct JumpToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.body.weight(.semibold))
                .frame(width: controlTarget, height: controlTarget)
                .yorozuGlass(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Jump to Latest"))
    }
}

/// The agent is working: from `run_started` until the run ends (#415).
private struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.title3.weight(.bold))
            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            .foregroundStyle(.secondary)
            .padding(.horizontal, LayoutMetrics.stack)
            .padding(.vertical, LayoutMetrics.inner)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .accessibilityLabel(Text("The agent is typing"))
    }
}

/// The field, the + for attachments (#430) and the send control in one glass container, as v2's composer, with the
/// staged files above it. Messages typed while offline wait in the outbox, so sending is never disabled by the link.
/// On the Mac Return is a new line and ⌘Return sends (owner, 2026-10-09); iPhone and iPad keep smart Enter.
private struct V3Composer: View {
    @Binding var text: String
    @Binding var files: [ChatAttachment]
    @Binding var automation: V3CronJob?
    /// The host's limit; nil when it takes no attachments, which hides the +.
    let attachLimit: Int?
    /// Files pasted or dropped onto the field.
    let onFiles: ([URL]) -> Bool
    let onSend: () -> Void

    /// The send circle inside the ``controlTarget``-tall row; smaller, so the fill reads as a button.
    private let sendCircle: CGFloat = 32
    private let radius: CGFloat = 22

    var body: some View {
        VStack(spacing: LayoutMetrics.tight) {
            if !files.isEmpty || automation != nil {
                V3StagedFiles(files: files, automation: automation, onRemoveAutomation: { automation = nil }) { file in
                    files.removeAll { $0.id == file.id }
                    AttachmentFiles.remove(file)
                }
            }
            row
        }
        .padding(.top, files.isEmpty && automation == nil ? 0 : LayoutMetrics.inner)
        .yorozuGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .padding(.horizontal, LayoutMetrics.stack)
        .padding(.vertical, LayoutMetrics.inner)
        .frame(maxWidth: LayoutMetrics.composerWidth)
        .frame(maxWidth: .infinity)
    }

    private var row: some View {
        HStack(alignment: .bottom, spacing: LayoutMetrics.tight) {
            if let attachLimit {
                V3AttachMenu(limit: attachLimit) { files.append(contentsOf: $0) }
            }
            ComposerTextView(text: $text, placeholder: String(localized: "Message"), onSubmit: send, onFiles: onFiles)
                // Room above and below the text, inside the glass; right up to the + on the left (owner, 2026-10-17).
                .padding(.vertical, LayoutMetrics.inner)
                .frame(minHeight: controlTarget)
                .accessibilityIdentifier("composer.text")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: sendCircle, height: sendCircle)
                    .background(canSend ? AnyShapeStyle(YorozuPalette.vermilion) : AnyShapeStyle(.fill.tertiary), in: Circle())
            }
            .buttonStyle(.plain)
            .frame(width: controlTarget, height: controlTarget)
            // ⌘Enter sends on the Mac (owner, 2026-10-09).
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
            .accessibilityLabel(Text("Send"))
            .accessibilityIdentifier("composer.send")
        }
        .padding(.leading, attachLimit == nil ? LayoutMetrics.tight : 0)
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty || automation != nil }

    private func send() {
        guard canSend else { return }
        onSend()
    }
}
