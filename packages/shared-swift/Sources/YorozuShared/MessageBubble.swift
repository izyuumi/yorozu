import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// The two platforms spell the pasteboard differently and nothing else about a bubble does,
/// so this is the whole of the shim.
func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
        UIPasteboard.general.string = text
    #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    #endif
}

extension Image {
    /// An image decoded from attachment bytes, or nil when they are not an image this platform
    /// can read — a file named `.png` that is not one is a thing a phone can send.
    static func from(data: Data) -> Image? {
        #if canImport(UIKit)
            UIImage(data: data).map(Image.init(uiImage:))
        #elseif canImport(AppKit)
            NSImage(data: data).map(Image.init(nsImage:))
        #else
            nil
        #endif
    }
}

/// One message in a thread. The user's is drawn as they typed it — plain text, right-aligned,
/// tinted — and the agent's is rendered Markdown, because that is what models reply in.
///
/// User bubbles copy as a whole through their context menu. Replies keep native text selection
/// and offer actions separately. Every message is always shown in full.
public struct MessageBubble: View {
    /// The event id, which is what says whether this is the bubble being read aloud.
    private let id: String
    private let data: MessageData
    private let agent: ThreadAgent
    private let agentLabel: String
    /// Whether this is the reply still being written, which is what earns the caret.
    private let streaming: Bool
    private let copyAvailable: Bool
    private let timestamp: Int?
    /// Set while the message is waiting in the outbox, which is what puts a caption under it.
    private let status: OutboxStatus?
    private let queuedStatus: String?
    private let rejectionReason: String?
    private let attachmentTransferLabels: [String]?
    private let onEditFromHere: (() -> Void)?
    private let editFromHereEnabled: Bool
    private let onRetry: (() -> Void)?
    private let onSendNow: (() -> Void)?
    private let onWithdraw: (() -> Void)?
    private let onDelete: (() -> Void)?
    /// Sends the queued message again, for a message the outbox has given up on.
    private let onResend: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ReplyFont.key) private var replyFont = ReplyFont.sans
    @State private var hovering = false
    @State private var copied = false
    @State private var confirmingEdit = false

    public init(
        id: String = "",
        data: MessageData,
        streaming: Bool = false,
        copyAvailable: Bool = true,
        timestamp: Int? = nil,
        status: OutboxStatus? = nil,
        queuedStatus: String? = nil,
        rejectionReason: String? = nil,
        attachmentTransferLabels: [String]? = nil,
        onEditFromHere: (() -> Void)? = nil,
        editFromHereEnabled: Bool = false,
        onRetry: (() -> Void)? = nil,
        onSendNow: (() -> Void)? = nil,
        onWithdraw: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onResend: (() -> Void)? = nil,
        agent: ThreadAgent = .yorozu,
        agentLabel: String? = nil
    ) {
        self.id = id
        self.data = data
        self.agent = agent
        self.agentLabel = agentLabel ?? agent.label
        self.streaming = streaming
        self.copyAvailable = copyAvailable
        self.timestamp = timestamp
        self.status = status
        self.queuedStatus = queuedStatus
        self.rejectionReason = rejectionReason
        self.attachmentTransferLabels = attachmentTransferLabels
        self.onEditFromHere = onEditFromHere
        self.editFromHereEnabled = editFromHereEnabled
        self.onRetry = onRetry
        self.onSendNow = onSendNow
        self.onWithdraw = onWithdraw
        self.onDelete = onDelete
        self.onResend = onResend
    }

    private var isUser: Bool { data.role == .user }

    private var speaking: Bool { Speaker.shared.speakingId == id && !id.isEmpty }

    private var copyLabel: String {
        copied ? String(localized: "Copied message") : String(localized: "Copy message")
    }

    private var speechLabel: String {
        speaking ? String(localized: "Stop reading aloud") : String(localized: "Listen to reply")
    }

    /// The one link worth previewing, and only under a reply: what the user typed is their own
    /// text and is not decorated back at them.
    private var link: URL? { isUser ? nil : firstLink(in: data.text) }

    public var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: LayoutMetrics.tight) {
            if !data.attachments.isEmpty {
                AttachmentsView(attachments: data.attachments)
            }
            if let attachmentTransferLabels {
                ForEach(Array(attachmentTransferLabels.enumerated()), id: \.offset) { _, label in
                    Text(label).font(.scaled(.caption2)).foregroundStyle(.secondary)
                        .accessibilityLabel(label)
                }
            }
            if (!data.text.isEmpty || streaming), !isUser {
                HStack(spacing: 6) {
                    AgentMarkView(agent, size: 13)
                    Text(agentLabel)
                        .font(.scaled(.caption2).weight(.semibold))
                        .tracking(0.8)
                }
                .foregroundStyle(YorozuPalette.ink.opacity(0.62))
                // Left audible: alignment is the only other thing saying who spoke, and
                // VoiceOver cannot hear alignment.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(agentLabel)
            }
            if !data.text.isEmpty || streaming {
                bubble
            }
            if data.interrupted == true {
                Text("Stopped")
                    .font(.scaled(.caption2))
                    .foregroundStyle(YorozuPalette.ink.opacity(0.62))
            }
            // Only once the reply has finished arriving: previewing a URL that is still being
            // typed would fetch whatever prefix of it happened to be on screen.
            if let link, !streaming {
                LinkPreviewRow(url: link)
            }
            if speaking {
                SpeakingChip().transition(reduceMotion ? .identity : .scale(scale: 0.9).combined(with: .opacity))
            }
            if let queuedStatus {
                HStack(spacing: LayoutMetrics.inner) {
                    Text(queuedStatus)
                    if let onSendNow { Button("Send now", action: onSendNow) }
                    if let onWithdraw {
                        Button("Remove", action: onWithdraw)
                            .accessibilityHint("Returns text and attachments to the composer")
                    }
                }
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
            }
            if let status, queuedStatus == nil || ![.queued, .confirming, .withdrawalPending].contains(status) {
                caption(status)
            }
            if !data.text.isEmpty || onEditFromHere != nil || onRetry != nil || onDelete != nil || timestamp != nil {
                HStack(spacing: LayoutMetrics.inner) {
                    if isUser { Spacer(minLength: 0) }
                    #if os(macOS)
                        if hovering { inlineActions }
                    #else
                        inlineActions
                    #endif
                    messageActions
                    if !isUser { Spacer(minLength: 0) }
                }
                .frame(maxWidth: bubbleMaxWidth, alignment: isUser ? .trailing : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: speaking)
        .confirmationDialog("Edit from here?", isPresented: $confirmingEdit, titleVisibility: .visible) {
            Button("Edit from here", role: .destructive) { onEditFromHere?() }
                .disabled(!editFromHereEnabled)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This message and everything after it will be hidden on all devices. Your prompt and attachments will return to the composer. Files will not be reverted.")
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
        #if os(macOS)
            .onHover { hovering = $0 }
        #endif
    }

    /// The explicit menu keeps secondary actions available without taking over selection.
    @ViewBuilder private var actions: some View {
        if copyAvailable, !data.text.isEmpty, !streaming {
            Button("Copy", systemImage: "doc.on.doc") { copy() }
        }
        if !isUser, !id.isEmpty, !data.text.isEmpty {
            // One utterance at a time, so this is a toggle rather than a second voice.
            Button(speaking ? String(localized: "Stop") : String(localized: "Listen"), systemImage: speaking ? "stop" : "speaker.wave.2") {
                toggleSpeaking()
            }
        }
        if onEditFromHere != nil {
            Button("Edit from here", systemImage: "pencil") { confirmingEdit = true }
                .disabled(!editFromHereEnabled)
        }
        if let onRetry {
            Button(rejectionReason?.hasPrefix("thread-create-rejected:") == true || rejectionReason == "thread-not-created"
                ? String(localized: "Use in new chat") : String(localized: "Retry"),
                systemImage: "arrow.clockwise", action: onRetry)
        }
        if let onWithdraw {
            Button(queuedStatus == nil ? "Cancel send" : "Remove", systemImage: "xmark.circle", action: onWithdraw)
        }
        if let onDelete {
            // Local only, which the menu says outright: the word "Delete" on its own
            // would promise something this button cannot do.
            Button("Remove from this device", systemImage: "trash", role: .destructive, action: onDelete)
        }
        if let timestamp, timestamp > 0 {
            Text(Date(timeIntervalSince1970: Double(timestamp) / 1000)
                .formatted(date: .omitted, time: .shortened))
        }
    }

    @ViewBuilder private var inlineActions: some View {
        Group {
            if copyAvailable, !data.text.isEmpty, !streaming {
                Button { copy() } label: {
                    Label(copied ? String(localized: "Copied") : String(localized: "Copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(minWidth: controlTarget, minHeight: controlTarget)
                        .contentShape(.rect)
                }
                .accessibilityLabel(copyLabel)
                .help(copyLabel)
            }
            if isUser, onEditFromHere != nil {
                Button { confirmingEdit = true } label: {
                    Label("Edit from here", systemImage: "pencil")
                        .frame(minWidth: controlTarget, minHeight: controlTarget)
                        .contentShape(.rect)
                }
                .disabled(!editFromHereEnabled)
                .help("Edit from here")
            }
            if !isUser, !streaming, let onRetry {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(minWidth: controlTarget, minHeight: controlTarget)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Retry reply")
                .help("Retry reply")
            }
            if !isUser, !id.isEmpty, !data.text.isEmpty {
                Button(action: toggleSpeaking) {
                    Label(speaking ? String(localized: "Stop") : String(localized: "Listen"),
                          systemImage: speaking ? "stop" : "speaker.wave.2")
                        .frame(minWidth: controlTarget, minHeight: controlTarget)
                        .contentShape(.rect)
                }
                .accessibilityLabel(speechLabel)
                .help(speechLabel)
            }
        }
        .font(.scaled(.caption))
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func copy() {
        copyToPasteboard(data.text)
        copied = true
    }

    private func toggleSpeaking() {
        if speaking { Speaker.shared.stop() }
        else { Speaker.shared.speak(data.text, id: id) }
    }

    private var messageActions: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis")
                .font(.scaled(.body))
                .frame(minWidth: controlTarget, minHeight: controlTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Message actions")
        .accessibilityIdentifier("messageActions-\(id)")
        #if os(macOS)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .help("Message actions")
        #endif
    }

    /// What the outbox has to say about this message, under it and in the quiet of a caption:
    /// waiting for the Mac is normal and says so once; uncertain delivery stays explicit.
    @ViewBuilder private func caption(_ status: OutboxStatus) -> some View {
        let needsRetry = status == .failed || status == .unconfirmed || status == .expired
        let description = status == .rejected ? rejectionDescription : status.label
        let label = Label {
            // "tap" on a Mac is a phone app talking to the wrong person.
            #if os(macOS)
                Text(status == .failed ? "Not sent — click to retry" :
                    status == .unconfirmed ? "Delivery unconfirmed — click to retry" : description)
            #else
                Text(status == .failed ? "Not sent — tap to retry" :
                    status == .unconfirmed ? "Delivery unconfirmed — tap to retry" : description)
            #endif
        } icon: {
            // The icon carries the red; caption-sized red text is under 4.5:1.
            Image(systemName: status.symbol)
                .foregroundStyle(status == .failed || status == .rejected ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .font(.scaled(.caption))
        .foregroundStyle(status == .failed || status == .rejected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 4)

        if needsRetry, let onResend {
            Button(action: onResend) { label.frame(minHeight: controlTarget) }
                .buttonStyle(.plain)
                .accessibilityHint(status == .expired ? "Sends a new message with the same content" : "Sends this message again")
        } else {
            label.accessibilityLabel(description)
        }
    }

    private var rejectionDescription: String {
        if rejectionReason?.hasPrefix("thread-create-rejected:") == true {
            return String(localized: "Not sent · chat could not be created. Use in new chat to keep attachments.")
        }
        return switch rejectionReason {
        case "oversized-attachments": String(localized: "Not sent · attachments too large")
        case "invalid-attachment-upload", "invalid-attachment-chunk", "invalid-attachment-commit":
            String(localized: "Not sent · attachment could not be read")
        case "conflicting-attachment-upload", "corrupt-attachment-upload":
            String(localized: "Not sent · attachment changed during transfer")
        case "attachment-storage-failed": String(localized: "Not sent · host could not save attachment")
        case "client-clock-ahead": String(localized: "Not sent · device clock is ahead")
        case "conflicting-message-id": String(localized: "Not sent · message changed after sending")
        case "invalid-admission-deadline": String(localized: "Not sent · invalid message deadline")
        case "thread-not-created": String(localized: "Not sent · chat does not exist. Use in new chat to keep attachments.")
        case "attachments-unsupported":
            String(localized: "Not sent · OpenClaw can't receive attachments. Update the Yorozu plugin.")
        case "conflicting-thread-create": String(localized: "Not sent · chat creation changed")
        default: String(localized: "Not sent · rejected by host")
        }
    }

    @ViewBuilder private var bubble: some View {
        if isUser {
            bubbleContent.contextMenu {
                if copyAvailable, !data.text.isEmpty, !streaming {
                    Button("Copy", systemImage: "doc.on.doc") { copy() }
                }
            }
        } else {
            bubbleContent
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
            // Never shorter than the text: a hosted cell on the phone can propose less height
            // than a long reply needs, and `Text` answers that by cutting lines with "…".
            text.fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, isUser ? LayoutMetrics.stack : 0)
        .padding(.vertical, isUser ? LayoutMetrics.inner : 0)
        .fontDesign(isUser ? .default : replyFont.design)
        .foregroundStyle(isUser ? AnyShapeStyle(Color.white) : AnyShapeStyle(YorozuPalette.ink))
        // Links draw in the tint, and the user capsule is filled with it: accent on accent.
        .tint(isUser ? Color.white : YorozuPalette.vermilion)
        .background(isUser ? bubbleBackground : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous))
        // A bubble stops short of the far edge, so which side it is on stays readable as
        // who said it even when the message is long.
        .frame(maxWidth: bubbleMaxWidth, alignment: isUser ? .trailing : .leading)
        #if os(iOS)
            // The reply as one UITextView, so a long press selects by word and letter in place
            // and across blocks; the same design and colours the modifiers above give `Text`.
            .environment(\.proseStyle, ProseStyle(
                font: isUser ? .sans : replyFont,
                ink: isUser ? .white : UIColor(YorozuPalette.ink),
                tint: isUser ? .white : UIColor(YorozuPalette.vermilion)
            ))
        #endif
    }

    private var bubbleBackground: AnyShapeStyle {
        AnyShapeStyle(isUser ? YorozuPalette.vermilion : YorozuPalette.paper)
    }

    private var bubbleMaxWidth: CGFloat {
        #if os(iOS)
            isUser ? 300 : .infinity
        #else
            isUser ? 520 : LayoutMetrics.readingWidth
        #endif
    }

    @ViewBuilder private var text: some View {
        if isUser {
            Text(verbatim: data.text).font(.scaled(.body))
        } else {
            MarkdownText(data.text, cursor: streaming).textSelection(.enabled)
        }
    }
}

private struct GridImage: Identifiable {
    let id: Int
    let attachment: MessageAttachment
    let image: Image
}

private struct ViewedImage: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Images form a compact grid; files remain named rows. Any image opens the paged viewer.
private struct AttachmentsView: View {
    let attachments: [MessageAttachment]
    @State private var viewing: ViewedImage?
    @Namespace private var zoom

    private var split: (images: [GridImage], files: [MessageAttachment]) {
        var images: [GridImage] = []
        var files: [MessageAttachment] = []
        for attachment in attachments {
            if attachment.isImage, let bytes = attachment.bytes, let image = Image.from(data: bytes) {
                images.append(GridImage(id: images.count, attachment: attachment, image: image))
            } else {
                files.append(attachment)
            }
        }
        return (images, files)
    }

    var body: some View {
        let (images, files) = split
        VStack(alignment: .leading, spacing: 6) {
            if images.count == 1, let image = images.first {
                imageButton(image, hidden: 0)
                    .frame(maxWidth: 260, maxHeight: 320)
            } else if !images.isEmpty {
                let shown = Array(images.prefix(4))
                LazyVGrid(columns: [GridItem(.fixed(128)), GridItem(.fixed(128))], spacing: 3) {
                    ForEach(shown) { image in
                        imageButton(image, hidden: image.id == shown.last?.id ? images.count - shown.count : 0)
                            .frame(width: 128, height: 128)
                    }
                }
            }
            ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                fileRow(file)
            }
        }
        .onAppear {
            if ChatShowcase.imageViewer, viewing == nil, !images.isEmpty {
                viewing = ViewedImage(index: 0)
            }
        }
        .imageViewer(item: $viewing) { selected in
            ImageViewer(images: images, page: selected.index)
                .zoomed(from: selected.index, in: zoom)
        }
    }

    private func imageButton(_ item: GridImage, hidden: Int) -> some View {
        Button { viewing = ViewedImage(index: item.id) } label: {
            item.image
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay {
                    if hidden > 0 {
                        ZStack {
                            Color.black.opacity(0.45)
                            Text("+\(hidden)").font(.scaled(.title2).bold()).foregroundStyle(.white)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .zoomSource(item.id, in: zoom)
        .accessibilityLabel(hidden > 0
            ? "Attached image, \(item.attachment.name), and \(hidden) more"
            : "Attached image, \(item.attachment.name)")
        .accessibilityHint("Opens the picture full screen")
    }

    private func fileRow(_ attachment: MessageAttachment) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).lineLimit(1).truncationMode(.middle)
                Text(attachment.size).font(.scaled(.caption)).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "doc").foregroundStyle(.secondary)
        }
        .font(.scaled(.subheadline))
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Attached file, \(attachment.name), \(attachment.size)")
    }
}

private struct ImageViewer: View {
    let images: [GridImage]
    @State private var page: Int
    @Environment(\.dismiss) private var dismiss

    init(images: [GridImage], page: Int) {
        self.images = images
        _page = State(initialValue: page)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                ForEach(images) { item in
                    item.image.resizable().scaledToFit().tag(item.id)
                        .accessibilityLabel(item.attachment.name)
                }
            }
            #if os(iOS)
                .tabViewStyle(.page)
            #endif
            .background(.black)
            .navigationTitle(images.first { $0.id == page }?.attachment.name ?? "")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .primaryAction) {
                    if let current = images.first(where: { $0.id == page }) {
                        ShareLink(item: current.image, preview: SharePreview(current.attachment.name, image: current.image))
                    }
                }
            }
        }
        .accessibilityAction(.escape) { dismiss() }
    }
}

extension View {
    /// The system zoom: the picture grows out of its thumbnail, and dragging it down or
    /// pinching it shut sends it back. iOS only; a Mac sheet closes on Escape.
    @ViewBuilder fileprivate func zoomSource(_ id: Int, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
            matchedTransitionSource(id: id, in: namespace)
        #else
            self
        #endif
    }

    @ViewBuilder fileprivate func zoomed(from id: Int, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
            navigationTransition(.zoom(sourceID: id, in: namespace))
        #else
            self
        #endif
    }

    @ViewBuilder fileprivate func imageViewer<Item: Identifiable>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> some View
    ) -> some View {
        #if os(iOS)
            fullScreenCover(item: item, content: content)
        #else
            sheet(item: item) { content($0).frame(minWidth: 640, minHeight: 520) }
        #endif
    }
}

extension MessageAttachment {
    /// The decoded size, as a file listing would put it.
    public var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}
