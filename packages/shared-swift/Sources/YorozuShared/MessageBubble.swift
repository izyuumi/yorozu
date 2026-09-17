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
/// Long-pressing one offers Copy, Reply, Listen, Retry and Delete; on the Mac the same menu is
/// the right-click, and on the phone a bubble swiped towards the middle of the screen is
/// replied to. A message too long to read in passing is shown as its opening, with "Read more"
/// unfolding the rest in place.
public struct MessageBubble: View {
    /// The event id, which is what says whether this is the bubble being read aloud.
    private let id: String
    private let data: MessageData
    /// Whether this is the reply still being written, which is what earns the caret.
    private let streaming: Bool
    /// Set while the message is waiting in the outbox, which is what puts a caption under it.
    private let status: OutboxStatus?
    private let onRetry: (() -> Void)?
    private let onDelete: (() -> Void)?
    /// Called with this message's text when the reader wants to quote it.
    private let onReply: ((String) -> Void)?
    /// Sends the queued message again, for a message the outbox has given up on.
    private let onResend: (() -> Void)?
    private let reactions: [MessageReaction]
    private let onReact: ((String) -> Void)?

    /// Set by "Read more", which unfolds a long message where it stands. One way: Signal has no
    /// collapse either, and a message you asked to see is not something to take away again.
    @State private var expanded = ChatShowcase.expanded
    /// Mac only: whether the pointer is over this message, which is what shows its actions.
    @State private var hovering = false
    /// Set by the thread's search field; every hit inside this bubble is drawn highlighted.
    @Environment(\.searchHighlight) private var highlight

    public init(
        id: String = "",
        data: MessageData,
        streaming: Bool = false,
        status: OutboxStatus? = nil,
        onRetry: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onReply: ((String) -> Void)? = nil,
        onResend: (() -> Void)? = nil,
        reactions: [MessageReaction] = [],
        onReact: ((String) -> Void)? = nil
    ) {
        self.id = id
        self.data = data
        self.streaming = streaming
        self.status = status
        self.onRetry = onRetry
        self.onDelete = onDelete
        self.onReply = onReply
        self.onResend = onResend
        self.reactions = reactions
        self.onReact = onReact
    }

    private var isUser: Bool { data.role == .user }

    /// A quoted reply is one message with a blockquote at the top, so the two halves are split
    /// back apart to be drawn. Only for what the user sent: an agent's `>` is its own prose.
    private var parts: (quote: String?, body: String) {
        isUser ? splitQuote(data.text) : (nil, data.text)
    }

    /// Long messages are cut until "Read more" unfolds them — but never while they are still
    /// arriving, since truncating a streaming reply hides the part that is moving.
    private var truncated: Bool { !streaming && !expanded && needsReader(parts.body) }

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
                Text("YOROZU")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
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
                SpeakingChip().transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if !reactions.isEmpty { reactionChips }
            if let status {
                caption(status)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .animation(.easeOut(duration: 0.18), value: speaking)
        .contextMenu { actions }
        #if os(macOS)
            // An explicit shape, so the whole row tracks the pointer and not only the parts
            // of it something is drawn in.
            .contentShape(.rect)
            .onHover { hovering = $0 }
        #endif
    }

    /// Everything that can be done to one message. Shared by the context menu and, on the Mac,
    /// by the hover control — the two are the same list, not two lists that have to agree.
    @ViewBuilder private var actions: some View {
        if let onReact {
            Menu("React", systemImage: "face.smiling") {
                ForEach(["👍", "❤️", "😂", "😮", "😢", "🙏"], id: \.self) { emoji in
                    Button(emoji) { onReact(emoji) }
                }
            }
        }
        Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(data.text) }
        if let onReply {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { onReply(parts.body) }
        }
        if !isUser, !id.isEmpty {
            // One utterance at a time, so this is a toggle rather than a second voice.
            Button(speaking ? String(localized: "Stop") : String(localized: "Listen"), systemImage: speaking ? "stop" : "speaker.wave.2") {
                if speaking {
                    Speaker.shared.stop()
                } else {
                    Speaker.shared.speak(parts.body, id: id)
                }
            }
        }
        if truncated {
            Button("Read full message", systemImage: "text.alignleft") { expand() }
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

    private var reactionChips: some View {
        HStack(spacing: 4) {
            ForEach(reactions) { reaction in
                Button {
                    onReact?(reaction.emoji)
                } label: {
                    Text(reaction.count > 1 ? "\(reaction.emoji) \(reaction.count)" : reaction.emoji)
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .frame(minHeight: 28)
                        .background(
                            reaction.selected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary),
                            in: .capsule
                        )
                }
                .buttonStyle(.plain)
                .disabled(onReact == nil)
                .accessibilityLabel("\(reaction.emoji), \(reaction.count) reaction\(reaction.count == 1 ? "" : "s")")
                .accessibilityHint(reaction.selected ? String(localized: "Removes your reaction") : String(localized: "Adds this reaction"))
            }
        }
    }

    @ViewBuilder private var hoverActions: some View {
        #if os(macOS)
            Menu { actions } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.title3)
            }
            // The same styling as the composer's own menu button.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .accessibilityLabel("Message actions")
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
            Image(systemName: status.symbol)
        }
        .font(.caption)
        .foregroundStyle(status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
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
            if let quote = parts.quote {
                QuoteStrip(text: quote)
            }
            text
            if truncated {
                // A button, not a tap target on the text: "Read more" is the one thing in a
                // bubble VoiceOver has to be able to find and activate.
                Button("Read more") { expand() }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .frame(minHeight: 28)
                    .accessibilityHint("Shows the rest of this message")
            }
        }
        .padding(.horizontal, isUser ? LayoutMetrics.stack : 0)
        .padding(.vertical, isUser ? LayoutMetrics.inner : 0)
        #if os(macOS)
            // Flat assistant prose has no bubble inset to absorb its hover control. Reserve
            // the trailing control lane so the menu never covers selectable text.
            .padding(.trailing, isUser ? 0 : controlTarget + LayoutMetrics.tight)
        #endif
        .foregroundStyle(isUser ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
        .background(isUser ? bubbleBackground : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous))
        // The message's actions as a control of their own, because on the Mac the context
        // menu never opens: the text is selectable, selectable text brings AppKit's own
        // contextual menu — Look Up, Translate, Copy, Font — and that menu wins over this
        // view's. Reply, Listen, Read full message and Remove had no way in at all.
        //
        // Here rather than on the row, and above the frame below rather than under it: this
        // is the bubble's own outline, and the frame below is only as wide as a bubble may
        // get — hanging the button off that put it half a window away from a short message.
        #if os(macOS)
            .overlay(alignment: isUser ? .topLeading : .topTrailing) { hoverActions }
        #endif
        // A bubble stops short of the far edge, so which side it is on stays readable as
        // who said it even when the message is long.
        .frame(maxWidth: bubbleMaxWidth, alignment: isUser ? .trailing : .leading)
    }

    private var bubbleBackground: AnyShapeStyle {
        #if os(iOS)
            isUser
                ? AnyShapeStyle(Color.accentColor)
                : AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
        #else
            isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)
        #endif
    }

    private var bubbleMaxWidth: CGFloat {
        #if os(iOS)
            300
        #else
            isUser ? 520 : LayoutMetrics.readingWidth
        #endif
    }

    /// Unfolds the rest of the message where it stands. The bubble grows downwards from its own
    /// top edge, so what is being read stays where it was and the thread does not jump — which
    /// is the whole reason this is not a sheet any more.
    private func expand() {
        withAnimation(.easeOut(duration: 0.2)) { expanded = true }
    }

    @ViewBuilder private var text: some View {
        let body = truncated ? readerExcerpt(parts.body) : parts.body
        if isUser {
            // Users type prose, not Markdown: rendering their own `*` back at them as
            // italics would be the app editing what they said. The one thing applied is
            // the search highlight, which is the app answering a question they asked.
            Text(AttributedString(body).highlighting(highlight)).textSelection(.enabled)
        } else if streaming {
            // Reparsing and laying out the whole accumulated Markdown on every delta exceeds a
            // frame budget on long answers. The finished event renders the same text below.
            Text(AttributedString(body).highlighting(highlight))
                .textSelection(.enabled)
        } else {
            MarkdownText(body).textSelection(.enabled)
        }
    }
}

/// The message being replied to, above the reply: a rule down the side and the text quieted,
/// which is what a blockquote has looked like since email.
struct QuoteStrip: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule().fill(.tint.opacity(0.5)).frame(width: 3)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("In reply to: \(text)")
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
