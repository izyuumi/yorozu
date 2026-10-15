import SwiftUI

/// A user message's mark, forward only: Sending → Delivered → Read; Not delivered for one that did not go out.
enum MarkState: String, Codable, Sendable {
    case sending, delivered, read, notDelivered
}

/// What one user message's mark shows.
struct Delivery: Equatable {
    var state: MarkState
    /// A frame is on its way to the relay: the Sending mark spins.
    var inFlight: Bool
    /// In flight, or sent without `accepted` on the link that is up: the word says Sending.
    var sent: Bool
    /// Epoch ms.
    var sentAt: Int
    /// The host has it, not just the relay.
    var onHost = false

    /// The mark's step: Delivered (`MarkState`) splits into Sent (the relay's `accepted`) and Delivered (on the host).
    enum Step { case sending, sent, delivered, read, notDelivered }

    var step: Step {
        switch state {
        case .sending: .sending
        case .delivered: onHost ? .delivered : .sent
        case .read: .read
        case .notDelivered: .notDelivered
        }
    }

    /// The status word VoiceOver reads after the message.
    var word: String {
        switch step {
        case .sending: sent ? String(localized: "Sending") : String(localized: "Waiting for connection")
        case .sent: String(localized: "Sent")
        case .delivered: String(localized: "Delivered")
        case .read: String(localized: "Read")
        case .notDelivered: String(localized: "Not delivered")
        }
    }
}

/// The mark under a user bubble, Signal-style: one dotted circle while Sending, one check circle once the relay has it
/// (Sent), two overlapping check circles once the host has it (Delivered), two filled ones once read (Read), and the
/// failure symbol in red. A custom component: it owns the overlap; its size follows the caption font.
struct DeliveryMark: View {
    let delivery: Delivery

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    /// A little over half a caption-sized circle: the two circles overlap by about 58%.
    @ScaledMetric(relativeTo: .caption) private var overlap: CGFloat = 7

    var body: some View {
        Group {
            switch delivery.step {
            case .sending:
                Image(systemName: "circle.dotted")
                    .symbolEffect(.rotate, isActive: delivery.inFlight && !reduceMotion)
            case .sent:
                Image(systemName: "checkmark.circle")
            case .delivered:
                pair("checkmark.circle")
            case .read:
                pair("checkmark.circle.fill")
            case .notDelivered:
                Image(systemName: "exclamationmark.circle")
            }
        }
        .font(.caption)
        .foregroundStyle(delivery.state == .notDelivered ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        .accessibilityElement()
        .accessibilityLabel(delivery.word)
    }

    /// Each circle has a 1-pixel outline in one colour against the checkmarks (black in Dark Mode, white in Light
    /// Mode); the front one knocks out the one behind it with a background-coloured disc, so the outlines do not cross.
    private func pair(_ symbol: String) -> some View {
        HStack(spacing: -overlap) {
            outlined(symbol)
            outlined(symbol)
                .background { Circle().fill(Color(.systemBackground)) }
        }
    }

    private func outlined(_ symbol: String) -> some View {
        let outline = colorScheme == .dark ? Color.black : Color.white
        return Image(systemName: symbol).overlay { Circle().strokeBorder(outline, lineWidth: 1 / displayScale) }
    }
}
