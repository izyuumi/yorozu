import SwiftUI
import YorozuWire

struct ChatView: View {
    enum Focus { case only, focused, unfocused }

    let model: AppModel
    let convId: String
    var focus = Focus.only

    @State private var draft = ""
    @State private var files: [ChatAttachment] = []
    @State private var automation: CronJob?
    @State private var replyingTo: ChatItem?
    @State private var highlighted: String?
    @State private var dropFailure: String?
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    @State private var timesShown: CGFloat = 0
    @ScaledMetric(relativeTo: .caption2) private var timesWidth: CGFloat = 64
    @Environment(\.textZoom) private var zoom
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let conversation = model.conversations[convId]
        let items = conversation?.items ?? []
        let typing = model.typing.contains(convId)
        let latestReply = typing ? nil : items.last(where: { $0.kind == .agent })?.id
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                if let conversation, conversation.complete != true {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .opacity(model.loadingOlder.contains(convId) ? 1 : 0)
                        .task(id: conversation.oldestSeq) { model.loadOlder(convId) }
                }
                ForEach(items) { item in
                    ItemRow(model: model, item: item, latest: item.id == latestReply, quote: quote(of: item, in: items),
                        onReply: model.repliesAvailable ? { replyingTo = $0 } : nil, onQuote: show)
                        .background(.tint.opacity(highlighted == item.id ? 0.15 : 0),
                            in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
                        .modifier(MessageTimeBelow(item: item))
                        .readableRow()
                        .modifier(MessageTime(item: item, shown: timesShown, width: timesWidth * zoom))
                }
                if typing {
                    TypingIndicator().readableRow().id("typing")
                }
            }
            .padding(.vertical, LayoutMetrics.stack)
        }
        .scrollPosition($position)
        #if os(iOS)
        .gesture(LeftwardPan { dx in timesShown = min(max(-dx, 0), timesWidth * zoom) } ended: {
            withAnimation(.snappy) { timesShown = 0 }
        })
        #endif
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY
        } action: { _, distance in
            atBottom = distance <= LayoutMetrics.section * 2
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onChange(of: items.last?.id) { if atBottom || items.last?.kind == .user { position.scrollTo(edge: .bottom) } }
        .task(id: model.state == .ready) { model.open(convId) }
        .task(id: highlighted) {
            guard highlighted != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { highlighted = nil }
        }
        .onChange(of: typing) { if atBottom { position.scrollTo(edge: .bottom) } }
        .onAppear {
            model.markRead(convId, explicit: true)
            model.setOnScreen(convId, true)
            if focus != .unfocused { model.setVisible(convId) }
            if draft.isEmpty { draft = model.textDrafts.removeValue(forKey: convId) ?? "" }
        }
        .onDisappear {
            model.setOnScreen(convId, false)
            model.setVisible(nil, leaving: convId)
            if !draft.isEmpty { model.textDrafts[convId] = draft }
        }
        .onChange(of: focus) { if focus != .unfocused { model.setVisible(convId) } }
        .onChange(of: model.conversations[convId]?.latestReply?.id) { readIfActive() }
        .onChange(of: scenePhase) { readIfActive() }
        .overlay(alignment: .bottom) {
            ZStack {
                if !atBottom {
                    JumpToLatestButton { withAnimation { position.scrollTo(edge: .bottom) } }
                        .padding(.bottom, LayoutMetrics.inner)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: atBottom)
        }
        .overlay {
            if items.isEmpty && !typing {
                ContentUnavailableView {
                    Label("New conversation", systemImage: "bubble.left.and.bubble.right").zoomedFont(.title3)
                } description: {
                    Text("Your first message starts a new session on the host.").zoomedFont()
                }
            }
        }
        .yorozuBottomBar {
            Composer(text: $draft, files: $files, automation: $automation, replyingTo: $replyingTo,
                attachLimit: model.attachmentsAvailable ? model.mediaMaxBytes : nil,
                focus: focus, onFiles: attach, onImages: attachImages, onPasteData: attachPasteData) {
                model.send(Self.message(draft, automation: automation), attachments: files, in: convId, replyingTo: replyingTo)
                draft = ""
                files = []
                automation = nil
                replyingTo = nil
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.attachmentsAvailable else { return false }
            return attach(urls)
        }
        .alert(String(localized: "Can’t attach"), isPresented: Binding(get: { dropFailure != nil }, set: { if !$0 { dropFailure = nil } })) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(dropFailure ?? "")
        }
        .onChange(of: model.automationDrafts[convId], initial: true) { _, seed in
            guard let seed else { return }
            automation = seed
            model.automationDrafts[convId] = nil
        }
        .navigationTitle(model.conversations[convId]?.displayTitle ?? String(localized: "New Conversation"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarStaysVisible()
        .navigationSubtitleIfAvailable(model.state == .ready ? "" : model.state.label)
    }
}

extension ChatView {
    @discardableResult
    private func attach(_ urls: [URL]) -> Bool {
        guard model.attachmentsAvailable else { return false }
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return false }
        var refused: [String] = []
        for url in fileURLs {
            do { files.append(try AttachmentStaging.stage(file: url, limit: model.mediaMaxBytes)) } catch { refused.append(error.localizedDescription) }
        }
        if !refused.isEmpty { dropFailure = refused.joined(separator: "\n") }
        return true
    }

    @discardableResult
    private func attachImages(_ images: [Data]) -> Bool {
        guard model.attachmentsAvailable, !images.isEmpty else { return false }
        var refused: [String] = []
        for (index, data) in images.enumerated() {
            do { files.append(try AttachmentStaging.stage(image: data, name: "\(String(localized: "Pasted image")) \(index + 1)", limit: model.mediaMaxBytes)) }
            catch { refused.append(error.localizedDescription) }
        }
        if !refused.isEmpty { dropFailure = refused.joined(separator: "\n") }
        return true
    }

    @discardableResult
    private func attachPasteData(_ data: Data, name: String, mime: String) -> Bool {
        guard model.attachmentsAvailable else { return false }
        do { files.append(try AttachmentStaging.stage(data: data, name: name, mime: mime, limit: model.mediaMaxBytes)) }
        catch { dropFailure = error.localizedDescription }
        return true
    }

    static func message(_ text: String, automation: CronJob?) -> String {
        guard let automation else { return text }
        let reference = "Cron job \"\(automation.name)\" (id \(automation.id))"
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? reference : "\(reference): \(typed)"
    }

    private func readIfActive() {
        if scenePhase == .active { model.markRead(convId, explicit: false) }
    }

    private func quote(of item: ChatItem, in items: [ChatItem]) -> Quote? {
        guard let to = item.replyTo else { return nil }
        if let target = items.first(where: { $0.id == to.messageId }) { return Quote(id: target.id, text: target.firstLine, loaded: true) }
        return Quote(id: to.messageId, text: ChatItem.firstLine(to.text ?? ""), loaded: false)
    }

    private func show(_ id: String) {
        withAnimation { position.scrollTo(id: id, anchor: .center) }
        highlighted = id
    }
}

struct Quote {
    let id: String
    let text: String
    let loaded: Bool
}

private struct QuoteHeader: View {
    let text: String

    var body: some View {
        Label {
            Text(text.isEmpty ? String(localized: "Message") : text).lineLimit(1)
        } icon: {
            Image(systemName: "arrowshape.turn.up.left")
        }
        .textStyle(.footnote)
        .foregroundStyle(.secondary)
    }
}

struct ItemRow: View {
    let model: AppModel
    let item: ChatItem
    var latest = false
    var quote: Quote?
    var onReply: ((ChatItem) -> Void)?
    var onQuote: (String) -> Void = { _ in }
    @State private var selecting = false
    @State private var hovering = false
    @Environment(\.accent) private var accent

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

    private var reset: some View {
        HStack(spacing: LayoutMetrics.inner) {
            VStack { Divider() }
            Text("New session").textStyle(.caption).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
            VStack { Divider() }
        }
        .accessibilityElement(children: .combine)
    }

    private var user: some View {
        HStack(spacing: 0) {
            Spacer(minLength: LayoutMetrics.section * 2)
            VStack(alignment: .trailing, spacing: LayoutMetrics.tight) {
                quoteHeader
                if let files = item.attachments, !files.isEmpty {
                    AttachmentList(model: model, attachments: files, alignment: .trailing)
                }
                if !item.text.isEmpty {
                    Text(item.text)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .padding(.horizontal, LayoutMetrics.stack)
                        .padding(.vertical, LayoutMetrics.inner)
                        .background(accent.bubble, in: RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous))
                        #if os(macOS)
                        .textSelection(.enabled)
                        #endif
                        .contextMenu { reply; copy; selectText }
                        .accessibilityLabel(Text("You: \(item.text)"))
                }
                DeliveryMark(delivery: delivery)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(delivery.word))
                if let rejected = item.rejected {
                    Text(rejected)
                        .textStyle(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var delivery: Delivery {
        let status = item.status ?? .queued
        return Delivery(state: item.rejected != nil ? .notDelivered : status == .read ? .read : status >= .sent ? .delivered : .sending,
            inFlight: status == .sending, sent: status >= .sending, sentAt: Int(item.ts), onHost: status >= .delivered)
    }

    private var agent: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
            quoteHeader
            if !item.text.isEmpty {
                MarkdownBlocks(item.text)
                    .padding(LayoutMetrics.stack)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
                    .contextMenu { reply; copy; selectText }
            }
            if let files = item.attachments, !files.isEmpty {
                AttachmentList(model: model, attachments: files, alignment: .leading)
            }
            // Pointer platforms keep the row's space and reveal it on hover; iPhone shows it on the latest reply only.
            #if os(macOS)
            if !item.text.isEmpty { ReplyActions(text: item.text, onReply: onReply.map { f in { f(item) } }).opacity(latest || hovering ? 1 : 0) }
            #else
            if latest, !item.text.isEmpty { ReplyActions(text: item.text, onReply: onReply.map { f in { f(item) } }) }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }

    private var error: some View {
        Label { Text(item.text) } icon: {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(YorozuPalette.warning)
        }
        .textStyle(.footnote)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    @ViewBuilder private var quoteHeader: some View {
        if let quote {
            Button { onQuote(quote.id) } label: { QuoteHeader(text: quote.text) }
                .buttonStyle(.plain)
                .disabled(!quote.loaded)
        }
    }

    @ViewBuilder private var reply: some View {
        if let onReply {
            Button(String(localized: "Reply"), systemImage: "arrowshape.turn.up.left") { onReply(item) }
        }
    }

    private var copy: some View {
        Button(String(localized: "Copy"), systemImage: "doc.on.doc") { UIPasteboard.general.string = item.text }
    }

    private var selectText: some View {
        Button(String(localized: "Select Text"), systemImage: "selection.pin.in.out") { selecting = true }
    }
}

private struct ReplyActions: View {
    let text: String
    let onReply: (() -> Void)?
    @State private var copied = false

    var body: some View {
        HStack(spacing: LayoutMetrics.tight) {
            if let onReply {
                Button(action: onReply) {
                    Image(systemName: "arrowshape.turn.up.left").frame(minWidth: controlTarget, minHeight: controlTarget)
                }
                .help(String(localized: "Reply"))
                .accessibilityLabel(Text("Reply"))
            }
            Button {
                UIPasteboard.general.string = text
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(minWidth: controlTarget, minHeight: controlTarget)
            }
            .help(String(localized: "Copy as Markdown"))
            .accessibilityLabel(Text(copied ? "Copied" : "Copy as Markdown"))
        }
        .buttonStyle(.borderless)
        .textStyle(.footnote)
        .foregroundStyle(.secondary)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private struct ToolsRow: View {
    let calls: [ToolCall]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                ForEach(calls) { call in
                    Label {
                        Text(call.name).textStyle(.footnote, monospaced: true)
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
            .textStyle(.footnote)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func icon(_ status: Tool.Status) -> some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle")
        case .failed: Image(systemName: "xmark.circle").foregroundStyle(YorozuPalette.warning)
        }
    }

    private func word(_ status: Tool.Status) -> String {
        switch status {
        case .running: String(localized: "Running")
        case .done: String(localized: "Done")
        case .failed: String(localized: "Failed")
        }
    }
}

private struct MessageTime: ViewModifier {
    let item: ChatItem
    let shown: CGFloat
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: -shown)
            .overlay(alignment: .trailing) {
                if shown > 0, Self.isTimed(item) {
                    Self.time(item)
                        .frame(width: width, alignment: .leading)
                        .offset(x: width - shown)
                        .opacity(shown / width)
                        .accessibilityHidden(true)
                }
            }
    }

    static func isTimed(_ item: ChatItem) -> Bool { item.kind == .user || item.kind == .agent || item.kind == .error }

    static func time(_ item: ChatItem) -> some View {
        Text(Date(timeIntervalSince1970: TimeInterval(item.ts) / 1000), format: .dateTime.hour().minute())
            .textStyle(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct MessageTimeBelow: ViewModifier {
    let item: ChatItem

    func body(content: Content) -> some View {
        #if os(macOS)
        if MessageTime.isTimed(item) {
            let alignment: HorizontalAlignment = item.kind == .user ? .trailing : .leading
            VStack(alignment: alignment, spacing: LayoutMetrics.hair) {
                content
                MessageTime.time(item)
                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct JumpToLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .textStyle(.body, weight: .semibold)
                .frame(width: controlTarget, height: controlTarget)
                .yorozuGlass(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Jump to Latest"))
        .accessibilityLabel(Text("Jump to Latest"))
    }
}

private struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "ellipsis")
            .textStyle(.title3, weight: .bold)
            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            .foregroundStyle(.secondary)
            .padding(.horizontal, LayoutMetrics.stack)
            .padding(.vertical, LayoutMetrics.inner)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .accessibilityLabel(Text("The agent is typing"))
    }
}

private struct Composer: View {
    @Binding var text: String
    @Binding var files: [ChatAttachment]
    @Binding var automation: CronJob?
    @Binding var replyingTo: ChatItem?
    let attachLimit: Int?
    let focus: ChatView.Focus
    let onFiles: ([URL]) -> Bool
    let onImages: ([Data]) -> Bool
    let onPasteData: (Data, String, String) -> Bool
    let onSend: () -> Void
    @Environment(\.accent) private var accent

    private let sendCircle: CGFloat = 32
    private let radius: CGFloat = 22

    var body: some View {
        VStack(spacing: LayoutMetrics.tight) {
            if let replyingTo {
                HStack(spacing: LayoutMetrics.inner) {
                    QuoteHeader(text: replyingTo.firstLine).frame(maxWidth: .infinity, alignment: .leading)
                    Button { self.replyingTo = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Cancel Reply"))
                    .accessibilityLabel(Text("Cancel Reply"))
                }
                .padding(.horizontal, LayoutMetrics.stack)
            }
            if !files.isEmpty || automation != nil {
                StagedFiles(files: files, automation: automation, onRemoveAutomation: { automation = nil }) { file in
                    files.removeAll { $0.id == file.id }
                    AttachmentFiles.remove(file)
                }
            }
            if files.count > Attachment.maxPerMessage {
                Text("A message can carry up to \(Attachment.maxPerMessage) attachments.")
                    .textStyle(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, LayoutMetrics.stack)
            }
            row
        }
        .padding(.top, files.isEmpty && automation == nil && replyingTo == nil ? 0 : LayoutMetrics.inner)
        .yorozuGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.tint, lineWidth: 1.5)
                .opacity(focus == .focused ? 1 : 0)
                .animation(.snappy, value: focus)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, LayoutMetrics.stack)
        .padding(.vertical, LayoutMetrics.inner)
        .frame(maxWidth: LayoutMetrics.composerWidth)
        .frame(maxWidth: .infinity)
    }

    private var row: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if let attachLimit {
                AttachMenu(limit: attachLimit) { files.append(contentsOf: $0) }
            }
            ComposerTextView(text: $text, placeholder: focus == .unfocused ? String(localized: "Tap to reply here") : String(localized: "Message"), onSubmit: send, onFiles: onFiles, onImages: onImages,
                onPasteData: onPasteData)
                .padding(.vertical, LayoutMetrics.inner)
                .padding(.leading, attachLimit == nil ? 0 : -LayoutMetrics.inner)
                .frame(minHeight: controlTarget)
                .accessibilityIdentifier("composer.text")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .textStyle(.body, weight: .bold)
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: sendCircle, height: sendCircle)
                    .background(canSend ? AnyShapeStyle(accent.bubble) : AnyShapeStyle(.fill.tertiary), in: Circle())
            }
            .buttonStyle(.plain)
            .frame(width: controlTarget, height: controlTarget)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
            .help(String(localized: "Send"))
            .accessibilityLabel(Text("Send"))
            .accessibilityIdentifier("composer.send")
        }
        .padding(.leading, attachLimit == nil ? LayoutMetrics.stack : 0)
    }

    private var canSend: Bool {
        files.count <= Attachment.maxPerMessage
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty || automation != nil)
    }

    private func send() {
        guard canSend else { return }
        onSend()
    }
}

#if os(iOS)
private struct LeftwardPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: () -> Void

    init(changed: @escaping (CGFloat) -> Void, ended: @escaping () -> Void) {
        self.changed = changed
        self.ended = ended
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .changed: changed(pan.translation(in: pan.view).x)
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 2
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !(other.view is UIScrollView)
        }
    }
}
#endif
