import SwiftUI

// v1 packages/shared-swift ChatView.swift's iOS composer, send button and composer layout, without
// the stash, model and Stop controls; the attach menu is AttachMenu (#316).

/// One surface, like Messages: the field and the send control share one glass container, so the
/// eye reads one thing to type into. The border turns vermilion while the Mac is working. A draft
/// over the Mac's limit says so above the field rather than leaving Send silently dimmed, and offers
/// to send it as a text file. Staged files sit in a strip above the field.
struct Composer: View {
    @Binding var text: String
    @Binding var files: [DraftFile]
    /// The Mac takes attachments, or has not said it does not.
    let attachments: Bool
    let working: Bool
    let enabled: Bool
    /// False for text-only input (a job's own input, #319): no attach menu and no "Send as Text File".
    var allowsFiles = true
    /// The first line of the message being replied to, with the bar's ✕; nil when not replying.
    var replyQuote: String?
    var onCancelReply: () -> Void = {}
    let onSend: () -> Void
    let onSendAsTextFile: () -> Void

    /// What the host takes in one message (Engine.send).
    static let maxBytes = 6000

    @State private var sends = 0
    /// Picked files are still being copied and reduced: Send waits for them.
    @State private var loading = false

    /// The send circle, inside the ``controlTarget``-tall row. Smaller than the row, so the accent
    /// fill reads as a button rather than as a block.
    private let sendCircle: CGFloat = 32
    private let radius: CGFloat = 22

    var body: some View {
        let bytes = text.utf8.count
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if bytes > Self.maxBytes {
                overLimit(bytes)
                    .padding(.top, LayoutMetrics.stack)
                    .padding(.horizontal, LayoutMetrics.stack)
            }
            if let replyQuote {
                replyBar(replyQuote)
                    .padding(.top, LayoutMetrics.inner)
                    .padding(.horizontal, LayoutMetrics.stack)
            }
            if !files.isEmpty {
                StagedStrip(files: $files)
                    .padding(.top, LayoutMetrics.inner)
                    .padding(.horizontal, LayoutMetrics.stack)
            }
            HStack(alignment: .bottom, spacing: LayoutMetrics.tight) {
                if allowsFiles {
                    AttachMenu(remaining: AttachmentLimits.maxCount - files.count, available: attachments, loading: $loading) {
                        files += $0
                    }
                }
                ComposerTextView(text: $text, placeholder: String(localized: "Message"), onSubmit: send)
                    // Centred on the send button while single-line; grows past it.
                    .frame(minHeight: controlTarget)
                    .padding(.leading, allowsFiles ? 0 : LayoutMetrics.inner)
                sendButton
            }
        }
        .padding(.leading, LayoutMetrics.tight)
        .yorozuGlass(in: shape)
        .overlay {
            if working {
                shape.strokeBorder(YorozuPalette.vermilion.opacity(0.72), lineWidth: 1.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, LayoutMetrics.stack)
        .padding(.vertical, LayoutMetrics.inner)
        // The composer keeps to a column; a no-op on a phone.
        .frame(maxWidth: LayoutMetrics.composerWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        // Sending: the moment the thread changes hands.
        .sensoryFeedback(.impact(weight: .light), trigger: sends)
    }

    /// "Replying to" the target's first line, in the reply header's quote style, and ✕ to stop replying.
    private func replyBar(_ quote: String) -> some View {
        HStack(spacing: LayoutMetrics.inner) {
            Label {
                Text(verbatim: "“\(quote)”").lineLimit(1)
            } icon: {
                Image(systemName: "arrowshape.turn.up.left")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Replying to \(quote)"))
            Button("Cancel Reply", systemImage: "xmark", action: onCancelReply)
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: controlTarget, height: controlTarget)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
        }
        .padding(.leading, LayoutMetrics.inner)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: LayoutMetrics.controlRadius, style: .continuous))
    }

    private func overLimit(_ bytes: Int) -> some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
            Label {
                VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                    Text("\(bytes.formatted()) bytes. The limit is \(Self.maxBytes.formatted()).").fontWeight(.semibold)
                    (allowsFiles ? Text("Shorten it, or send it as a text file.") : Text("Shorten it.")).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(YorozuPalette.warning)
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
            if allowsFiles {
                Button {
                    onSendAsTextFile()
                    sends += 1
                } label: {
                    Label("Send as Text File", systemImage: "doc.text")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, LayoutMetrics.stack)
                        .frame(minHeight: controlTarget)
                        .background(.fill.tertiary, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(!enabled || !attachments || loading || files.count >= AttachmentLimits.maxCount)
            }
        }
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.body.weight(.bold))
                .foregroundStyle(canSend ? Color.white : Color.secondary)
                .frame(width: sendCircle, height: sendCircle)
                .background(canSend ? AnyShapeStyle(YorozuPalette.vermilion) : AnyShapeStyle(.fill.tertiary), in: Circle())
        }
        .buttonStyle(.plain)
        .frame(width: controlTarget, height: controlTarget)
        // A pointer hovering over a plain-styled button gets the system highlight on iPad.
        .hoverEffect(.highlight)
        .disabled(!canSend)
        .accessibilityLabel("Send")
    }

    private var canSend: Bool {
        enabled && !loading && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty)
            && text.utf8.count <= Self.maxBytes
    }

    private func send() {
        guard canSend else { return }
        onSend()
        sends += 1
    }
}
