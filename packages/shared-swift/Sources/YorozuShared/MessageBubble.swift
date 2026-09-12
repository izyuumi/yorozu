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
/// Long-pressing one offers Copy, Retry and Delete; on the Mac the same menu is the right-click.
public struct MessageBubble: View {
    private let data: MessageData
    /// Whether this is the reply still being written, which is what earns the caret.
    private let streaming: Bool
    /// Set while the message is waiting in the outbox, which is what puts a caption under it.
    private let status: OutboxStatus?
    private let onRetry: (() -> Void)?
    private let onDelete: (() -> Void)?
    /// Sends the queued message again, for a message the outbox has given up on.
    private let onResend: (() -> Void)?

    public init(
        data: MessageData,
        streaming: Bool = false,
        status: OutboxStatus? = nil,
        onRetry: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onResend: (() -> Void)? = nil
    ) {
        self.data = data
        self.streaming = streaming
        self.status = status
        self.onRetry = onRetry
        self.onDelete = onDelete
        self.onResend = onResend
    }

    private var isUser: Bool { data.role == .user }

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
            if let status {
                caption(status)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(data.text) }
            if let onRetry {
                Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
            }
            if let onDelete {
                // Local only, which the menu says outright: the word "Delete" on its own
                // would promise something this button cannot do.
                Button("Remove from this device", systemImage: "trash", role: .destructive, action: onDelete)
            }
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
        Group {
            if isUser {
                // Users type prose, not Markdown: rendering their own `*` back at them as
                // italics would be the app editing what they said.
                Text(data.text).textSelection(.enabled)
            } else {
                MarkdownText(data.text, cursor: streaming).textSelection(.enabled)
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
