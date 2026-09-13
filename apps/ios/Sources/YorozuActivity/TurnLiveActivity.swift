import ActivityKit
import SwiftUI
import WidgetKit
import YorozuShared

@main
struct YorozuActivityBundle: WidgetBundle {
    var body: some Widget { TurnLiveActivity() }
}

/// A turn, seen from outside the app: on the lock screen, and in the Dynamic Island when the
/// phone is awake.
///
/// It has one job and stays close to it. There is exactly one number worth watching — how long
/// this has been going — and one word worth reading — what it is doing. Everything else is the
/// thread's name, so you know which conversation buzzed.
///
/// The views themselves live in `YorozuShared` so the app can render the same lock screen for a
/// screenshot; what is here is the arrangement of them ActivityKit asks for.
struct TurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TurnAttributes.self) { context in
            TurnLockScreenView(attributes: context.attributes, state: context.state)
                // The whole surface is the tap target, and the tap is the only interaction.
                .widgetURL(context.attributes.deepLink)
                // A tinted background rather than a coloured card: the lock screen is already
                // busy, and the status is carried by the glyph and the word, not by a slab.
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TurnStatusGlyph(status: context.state.status)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TurnElapsed(state: context.state)
                        .font(.system(.title3, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TurnTitle.resolve(context.attributes.threadRef))
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.status.label)
                            .font(.subheadline)
                            .foregroundStyle(turnStatusTint(context.state.status))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                TurnStatusGlyph(status: context.state.status, compact: true)
            } compactTrailing: {
                // Compact is a few characters wide. The clock is the one that changes, so it is
                // the one worth the space; the glyph opposite it says what the clock is counting.
                TurnElapsed(state: context.state)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 44)
            } minimal: {
                TurnStatusGlyph(status: context.state.status, compact: true)
            }
            .widgetURL(context.attributes.deepLink)
            .keylineTint(turnStatusTint(context.state.status))
        }
    }
}

#Preview(
    "Lock screen",
    as: .content,
    using: TurnAttributes(threadId: "preview")
) {
    TurnLiveActivity()
} contentStates: {
    TurnAttributes.ContentState(status: .working, started: .now.addingTimeInterval(-64))
    TurnAttributes.ContentState(status: .needsApproval, started: .now.addingTimeInterval(-64))
    TurnAttributes.ContentState(status: .done, started: .now.addingTimeInterval(-64))
    TurnAttributes.ContentState(status: .failed, started: .now.addingTimeInterval(-64))
}
