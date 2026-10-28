import SwiftUI

enum MarkState: String, Codable, Sendable {
    case sending, delivered, read, notDelivered
}

struct Delivery: Equatable {
    var state: MarkState
    var inFlight: Bool
    var sent: Bool
    var sentAt: Int
    var onHost = false

    enum Step { case sending, sent, delivered, read, notDelivered }

    var step: Step {
        switch state {
        case .sending: .sending
        case .delivered: onHost ? .delivered : .sent
        case .read: .read
        case .notDelivered: .notDelivered
        }
    }

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

struct DeliveryMark: View {
    let delivery: Delivery

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var overlap: CGFloat = 7

    var body: some View {
        Group {
            switch delivery.step {
            case .sending where !delivery.sent:
                Image(systemName: "clock")
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
