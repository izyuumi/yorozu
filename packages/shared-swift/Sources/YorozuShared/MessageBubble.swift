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
/// the right-click. A message too long to read in passing is shown as its opening, with the
/// whole of it a tap away in a reader.
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

    @State private var reading = false
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
        onResend: (() -> Void)? = nil
    ) {
        self.id = id
        self.data = data
        self.streaming = streaming
        self.status = status
        self.onRetry = onRetry
        self.onDelete = onDelete
        self.onReply = onReply
        self.onResend = onResend
    }

    private var isUser: Bool { data.role == .user }

    /// A quoted reply is one message with a blockquote at the top, so the two halves are split
    /// back apart to be drawn. Only for what the user sent: an agent's `>` is its own prose.
    private var parts: (quote: String?, body: String) {
        isUser ? splitQuote(data.text) : (nil, data.text)
    }

    /// Long messages are cut here and read in full in the sheet — but never while they are
    /// still arriving, since truncating a streaming reply hides the part that is moving.
    private var truncated: Bool { !streaming && needsReader(parts.body) }

    private var speaking: Bool { Speaker.shared.speakingId == id && !id.isEmpty }

    /// The one link worth previewing, and only under a reply: what the user typed is their own
    /// text and is not decorated back at them.
    private var link: URL? { isUser ? nil : firstLink(in: data.text) }

    public var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            if let attachment = data.attachment {
                AttachmentView(attachment: attachment)
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
            if let status {
                caption(status)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .animation(.easeOut(duration: 0.18), value: speaking)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(data.text) }
            if let onReply {
                Button("Reply", systemImage: "arrowshape.turn.up.left") { onReply(parts.body) }
            }
            if !isUser, !id.isEmpty {
                // One utterance at a time, so this is a toggle rather than a second voice.
                Button(speaking ? "Stop" : "Listen", systemImage: speaking ? "stop" : "speaker.wave.2") {
                    if speaking {
                        Speaker.shared.stop()
                    } else {
                        Speaker.shared.speak(parts.body, id: id)
                    }
                }
            }
            if truncated {
                Button("Read full message", systemImage: "text.alignleft") { reading = true }
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
        .sheet(isPresented: $reading) {
            MessageReaderView(text: parts.body, title: isUser ? "Message" : "Reply")
        }
    }

    /// What the outbox has to say about this message, under it and in the quiet of a caption:
    /// waiting for the Mac is normal and says so once, and a message that will not go says that
    /// outright and offers the retry rather than hiding it in a long press.
    @ViewBuilder private func caption(_ status: OutboxStatus) -> some View {
        let label = Label {
            Text(status == .failed ? "Not sent — tap to retry" : status.label)
        } icon: {
            Image(systemName: status.symbol)
        }
        .font(.caption)
        .foregroundStyle(status == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 4)

        if status == .failed, let onResend {
            Button(action: onResend) { label.frame(minHeight: 44) }
                .buttonStyle(.plain)
                .accessibilityHint("Sends this message again")
        } else {
            label.accessibilityLabel(status.label)
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let quote = parts.quote {
                QuoteStrip(text: quote)
            }
            text
            if truncated {
                Button("Read more") { reading = true }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .frame(minHeight: 28)
                    .accessibilityHint("Opens the whole message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            isUser ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.quaternary),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        // A bubble stops short of the far edge, so which side it is on stays readable as
        // who said it even when the message is long.
        .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder private var text: some View {
        let body = truncated ? readerExcerpt(parts.body) : parts.body
        if isUser {
            // Users type prose, not Markdown: rendering their own `*` back at them as
            // italics would be the app editing what they said. The one thing applied is
            // the search highlight, which is the app answering a question they asked.
            Text(AttributedString(body).highlighting(highlight)).textSelection(.enabled)
        } else {
            MarkdownText(body, cursor: streaming).textSelection(.enabled)
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

/// What the user attached, above their message: a photo as a photo, anything else as a file.
private struct AttachmentView: View {
    let attachment: MessageAttachment

    var body: some View {
        if attachment.isImage, let bytes = attachment.bytes, let image = Image.from(data: bytes) {
            image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("Attached image, \(attachment.name)")
        } else {
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
        }
    }
}

extension MessageAttachment {
    /// The decoded size, as a file listing would put it. Base64 is 4 characters per 3 bytes,
    /// less whatever padding it ends with, so this needs no decode to work out.
    public var size: String {
        let padding = data.suffix(2).filter { $0 == "=" }.count
        let bytes = max(0, data.count / 4 * 3 - padding)
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
