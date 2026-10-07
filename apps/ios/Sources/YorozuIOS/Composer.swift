import SwiftUI

// v1 packages/shared-swift ChatView.swift's iOS composer, send button and composer layout, without
// the attach, stash, model and Stop controls.

/// One surface, like Messages: the field and the send control live inside the same rounded
/// container, so the eye reads one thing to type into. The border turns vermilion while the
/// Mac is working.
struct Composer: View {
    @Binding var text: String
    let working: Bool
    let enabled: Bool
    let onSend: () -> Void

    /// What the host takes in one message (Engine.send).
    static let maxBytes = 6000

    @State private var sends = 0

    /// The send and stop circle, inside the ``controlTarget``-tall row. Smaller than the row, so
    /// the accent fill reads as a button rather than as a block.
    private let sendCircle: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ComposerTextView(text: $text, placeholder: String(localized: "Message Yorozu…"), onSubmit: send)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            HStack(alignment: .center, spacing: 4) {
                Spacer(minLength: 4)
                sendButton
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .background(YorozuPalette.paper, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous)
                .strokeBorder(
                    working ? YorozuPalette.vermilion.opacity(0.72) : YorozuPalette.rule.opacity(0.82),
                    lineWidth: working ? 1.5 : 0.8
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // The composer keeps to a column; a no-op on a phone.
        .frame(maxWidth: LayoutMetrics.composerWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        // Sending: the moment the thread changes hands.
        .sensoryFeedback(.impact(weight: .light), trigger: sends)
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.body.weight(.bold))
                .foregroundStyle(canSend ? Color.white : Color.secondary)
                .frame(width: sendCircle, height: sendCircle)
                .background(canSend ? YorozuPalette.vermilion : Color.clear, in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: canSend ? 0 : 1.5))
        }
        .buttonStyle(.plain)
        .frame(width: controlTarget, height: controlTarget)
        // A pointer hovering over a plain-styled button gets the system highlight on iPad.
        .hoverEffect(.highlight)
        .disabled(!canSend)
        .accessibilityLabel("Send")
    }

    private var canSend: Bool {
        enabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= Self.maxBytes
    }

    private func send() {
        guard canSend else { return }
        onSend()
        sends += 1
    }
}
