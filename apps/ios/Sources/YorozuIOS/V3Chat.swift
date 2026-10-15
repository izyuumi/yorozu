import SwiftUI
import YorozuWire

/// One conversation: the user's bubbles with their marks, each reply chunk as its own card (replies arrive whole,
/// chunked by length), tool calls collapsed under the message whose run made them, the typing indicator, the composer.
struct V3ChatView: View {
    let model: V3Model
    let convId: String

    @State private var draft = ""
    /// Files in the composer, already copied into `AttachmentFiles` (#430).
    @State private var files: [ChatAttachment] = []
    @State private var dropFailure: String?
    @State private var position = ScrollPosition(edge: .bottom)
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let items = model.conversations[convId]?.items ?? []
        let typing = model.typing.contains(convId)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutMetrics.stack) {
                ForEach(items) { item in
                    V3ItemRow(model: model, item: item).readableRow()
                }
                if typing {
                    TypingIndicator().readableRow().id("typing")
                }
            }
            .padding(.vertical, LayoutMetrics.stack)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onChange(of: items.count) { position.scrollTo(edge: .bottom) }
        .onChange(of: typing) { position.scrollTo(edge: .bottom) }
        // Opening reads it on every device (#429), Mark as Unread included; a reply that arrives while it is on screen
        // only moves the cursor, and so does coming back to the foreground with it open.
        .onAppear { model.markRead(convId, explicit: true) }
        .onChange(of: model.conversations[convId]?.latestReply?.id) { readIfActive() }
        .onChange(of: scenePhase) { readIfActive() }
        .overlay {
            if items.isEmpty && !typing {
                ContentUnavailableView("New conversation", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Your first message starts a new session on the host."))
            }
        }
        .yorozuBottomBar {
            V3Composer(text: $draft, files: $files, attachLimit: model.attachmentsAvailable ? model.mediaMaxBytes : nil,
                onFiles: attach) {
                model.send(draft, attachments: files, in: convId)
                draft = ""
                files = []
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
        // "Edit in chat" (#432) leaves its text here, unsent.
        .onChange(of: model.drafts[convId], initial: true) { _, seed in
            guard let seed else { return }
            draft = seed
            model.drafts[convId] = nil
        }
        .navigationTitle(model.conversations[convId]?.preview.firstLine ?? String(localized: "New Conversation"))
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

    private func readIfActive() {
        if scenePhase == .active { model.markRead(convId, explicit: false) }
    }
}

private extension String {
    var firstLine: String { split(separator: "\n", maxSplits: 1).first.map(String.init) ?? self }
}

struct V3ItemRow: View {
    let model: V3Model
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user: user
        case .agent: agent
        case .error: error
        case .tools: ToolsRow(calls: item.tools ?? [])
        }
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
                        .contextMenu { copy }
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
                    .contextMenu { copy }
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
            if !files.isEmpty {
                V3StagedFiles(files: files) { file in
                    files.removeAll { $0.id == file.id }
                    AttachmentFiles.remove(file)
                }
            }
            row
        }
        .padding(.top, files.isEmpty ? 0 : LayoutMetrics.inner)
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
                .frame(minHeight: controlTarget)
                .padding(.leading, LayoutMetrics.inner)
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

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty }

    private func send() {
        guard canSend else { return }
        onSend()
    }
}
