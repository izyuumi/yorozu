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
/// A separate menu offers message actions on both platforms, without taking over native text
/// selection. Every message is always shown in full.
public struct MessageBubble: View {
    /// The event id, which is what says whether this is the bubble being read aloud.
    private let id: String
    private let data: MessageData
    private let agent: ThreadAgent
    /// Whether this is the reply still being written, which is what earns the caret.
    private let streaming: Bool
    /// Set while the message is waiting in the outbox, which is what puts a caption under it.
    private let status: OutboxStatus?
    private let onRetry: (() -> Void)?
    private let onDelete: (() -> Void)?
    /// Sends the queued message again, for a message the outbox has given up on.
    private let onResend: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set by the thread's search field; every hit inside this bubble is drawn highlighted.
    @Environment(\.searchHighlight) private var highlight

    public init(
        id: String = "",
        data: MessageData,
        streaming: Bool = false,
        status: OutboxStatus? = nil,
        onRetry: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onResend: (() -> Void)? = nil,
        agent: ThreadAgent = .yorozu
    ) {
        self.id = id
        self.data = data
        self.agent = agent
        self.streaming = streaming
        self.status = status
        self.onRetry = onRetry
        self.onDelete = onDelete
        self.onResend = onResend
    }

    private var isUser: Bool { data.role == .user }

    private var speaking: Bool { Speaker.shared.speakingId == id && !id.isEmpty }

    /// The one link worth previewing, and only under a reply: what the user typed is their own
    /// text and is not decorated back at them.
    private var link: URL? { isUser ? nil : firstLink(in: data.text) }

    public var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: LayoutMetrics.tight) {
            if !data.attachments.isEmpty {
                AttachmentsView(attachments: data.attachments)
            }
            if (!data.text.isEmpty || streaming), !isUser {
                HStack(spacing: 6) {
                    AgentMarkView(agent, size: 13)
                    Text(agent.label)
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                }
                .foregroundStyle(YorozuPalette.ink.opacity(0.62))
                // Left audible: alignment is the only other thing saying who spoke, and
                // VoiceOver cannot hear alignment.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(agent.label)
            }
            if !data.text.isEmpty || streaming {
                bubble
            }
            // Only once the reply has finished arriving: previewing a URL that is still being
            // typed would fetch whatever prefix of it happened to be on screen.
            if let link, !streaming {
                LinkPreviewRow(url: link)
            }
            if speaking {
                SpeakingChip().transition(reduceMotion ? .identity : .scale(scale: 0.9).combined(with: .opacity))
            }
            if let status {
                caption(status)
            }
            if !data.text.isEmpty || onRetry != nil || onDelete != nil {
                messageActions
                    .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: speaking)
        #if os(macOS)
            // Mac only: on the phone the long press belongs to text selection.
            .contextMenu { actions }
        #endif
    }

    /// The explicit menu and the Mac's contextual menu share the same available actions.
    @ViewBuilder private var actions: some View {
        if !data.text.isEmpty {
            Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(data.text) }
        }
        if !isUser, !id.isEmpty, !data.text.isEmpty {
            // One utterance at a time, so this is a toggle rather than a second voice.
            Button(speaking ? String(localized: "Stop") : String(localized: "Listen"), systemImage: speaking ? "stop" : "speaker.wave.2") {
                if speaking {
                    Speaker.shared.stop()
                } else {
                    Speaker.shared.speak(data.text, id: id)
                }
            }
        }
        if let onRetry {
            Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
        }
        if let onDelete {
            // Local only, which the menu says outright: the word "Delete" on its own
            // would promise something this button cannot do.
            Button("Remove from this device", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private var messageActions: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
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
    /// waiting for the Mac is normal and says so once, and a message that will not go says that
    /// outright and offers the retry rather than hiding it in a long press.
    @ViewBuilder private func caption(_ status: OutboxStatus) -> some View {
        let label = Label {
            // "tap" on a Mac is a phone app talking to the wrong person.
            #if os(macOS)
                Text(status == .failed ? "Not sent — click to retry" : status.label)
            #else
                Text(status == .failed ? "Not sent — tap to retry" : status.label)
            #endif
        } icon: {
            // The icon carries the red; caption-sized red text is under 4.5:1.
            Image(systemName: status.symbol)
                .foregroundStyle(status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .font(.caption)
        .foregroundStyle(status == .failed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 4)

        if status == .failed, let onResend {
            Button(action: onResend) { label.frame(minHeight: controlTarget) }
                .buttonStyle(.plain)
                .accessibilityHint("Sends this message again")
        } else {
            label.accessibilityLabel(status.label)
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
            // Never shorter than the text: a hosted cell on the phone can propose less height
            // than a long reply needs, and `Text` answers that by cutting lines with "…".
            text.fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, isUser ? LayoutMetrics.stack : 0)
        .padding(.vertical, isUser ? LayoutMetrics.inner : 0)
        .fontDesign(isUser ? .default : .serif)
        .foregroundStyle(isUser ? AnyShapeStyle(Color.white) : AnyShapeStyle(YorozuPalette.ink))
        // Links draw in the tint, and the user capsule is filled with it: accent on accent.
        .tint(isUser ? Color.white : YorozuPalette.vermilion)
        .background(isUser ? bubbleBackground : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous))
        // A bubble stops short of the far edge, so which side it is on stays readable as
        // who said it even when the message is long.
        .frame(maxWidth: bubbleMaxWidth, alignment: isUser ? .trailing : .leading)
        #if os(iOS)
            // Prose as UITextViews, so a long press selects by word and letter in place; the
            // same design and colours the modifiers above give the SwiftUI path.
            .environment(\.proseStyle, ProseStyle(
                serif: !isUser,
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
        let body = data.text
        if streaming {
            // Reparsing and laying out the whole accumulated Markdown on every delta exceeds a
            // frame budget on long answers. The finished event renders the same text below.
            Text(AttributedString(body).highlighting(highlight))
                .textSelection(.enabled)
        } else {
            MarkdownText(body).textSelection(.enabled)
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
                            Text("+\(hidden)").font(.title2.bold()).foregroundStyle(.white)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hidden > 0
            ? "Attached image, \(item.attachment.name), and \(hidden) more"
            : "Attached image, \(item.attachment.name)")
        .accessibilityHint("Opens the picture full screen")
    }

    private func fileRow(_ attachment: MessageAttachment) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).lineLimit(1).truncationMode(.middle)
                Text(attachment.size).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "doc").foregroundStyle(.secondary)
        }
        .font(.subheadline)
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
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
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
