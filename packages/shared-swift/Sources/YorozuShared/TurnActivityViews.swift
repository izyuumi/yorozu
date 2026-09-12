#if os(iOS)
    import ActivityKit
    import SwiftUI

    /// The status colour. Kept out of ``TurnStatus`` so the shared enum owes nothing to SwiftUI,
    /// and out of the widget so the app draws the same one.
    public func turnStatusTint(_ status: TurnStatus) -> Color {
        switch status {
        case .working: .accentColor
        case .needsApproval: .orange
        case .done: .green
        case .failed: .secondary
        }
    }

    /// The one glyph everything else is arranged around. Working turns, because a still dotted
    /// circle and a finished one look alike at eleven points across a locked screen.
    public struct TurnStatusGlyph: View {
        let status: TurnStatus
        var compact = false
        @State private var turning = false

        public init(status: TurnStatus, compact: Bool = false) {
            self.status = status
            self.compact = compact
        }

        public var body: some View {
            Image(systemName: status.symbol)
                .font(compact ? .body : .title2)
                .foregroundStyle(turnStatusTint(status))
                .rotationEffect(.degrees(turning && status == .working ? 360 : 0))
                .animation(
                    status == .working
                        ? .linear(duration: 2.4).repeatForever(autoreverses: false) : .default,
                    value: turning
                )
                .onAppear { turning = true }
                .accessibilityLabel(status.label)
        }
    }

    /// Counts up from when the turn started while it is running, and stops at the total once it
    /// is not. `Text(_:style:)` is what keeps the clock moving without the app being awake to
    /// move it.
    public struct TurnElapsed: View {
        let state: TurnAttributes.ContentState

        public init(state: TurnAttributes.ContentState) {
            self.state = state
        }

        public var body: some View {
            if state.status.isLive {
                Text(state.startedAt, style: .timer)
            } else {
                // A finished turn's length, rounded to the second: "1:04", the same shape the
                // timer had a moment ago, so the number does not change format as it settles.
                Text(
                    Duration.seconds(Date().timeIntervalSince(state.startedAt))
                        .formatted(.time(pattern: .minuteSecond))
                )
            }
        }
    }

    /// The lock screen and the Notification Centre banner. Three lines on a common left edge —
    /// the thread, what it is doing, and the invitation to open it — with the clock opposite the
    /// title, so the eye reads name-then-duration across and status underneath.
    ///
    /// In the shared package rather than the widget so the app can render the very same view for
    /// a screenshot: a simulator cannot be made to lock its screen with an activity on it.
    public struct TurnLockScreenView: View {
        let attributes: TurnAttributes
        let state: TurnAttributes.ContentState

        public init(attributes: TurnAttributes, state: TurnAttributes.ContentState) {
            self.attributes = attributes
            self.state = state
        }

        public var body: some View {
            HStack(alignment: .center, spacing: 14) {
                TurnStatusGlyph(status: state.status)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(state.status.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(turnStatusTint(state.status))
                    Text("Tap to open")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                TurnElapsed(state: state)
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens this chat in Yorozu")
        }
    }
#endif
