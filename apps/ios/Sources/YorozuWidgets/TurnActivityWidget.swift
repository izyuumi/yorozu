import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity for a turn left running: "Working", the tool steps and the elapsed time. Nothing
/// from the conversation itself.
struct TurnActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TurnActivityAttributes.self) { context in
            TurnLockScreenView(steps: context.state.steps, startedAt: context.attributes.startedAt)
                .activityBackgroundTint(nil)
                .widgetURL(WidgetLink.conversation(context.attributes.convId).url)
        } dynamicIsland: { context in
            let tint = TurnStyle.tint
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WorkingGlyph(tint: tint).font(.title2).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 64)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("Yorozu is working").font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(TurnStyle.steps(context.state.steps))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                WorkingGlyph(tint: tint)
            } compactTrailing: {
                Text("\(context.state.steps)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                    .accessibilityLabel(TurnStyle.steps(context.state.steps))
            } minimal: {
                WorkingGlyph(tint: tint)
            }
            .widgetURL(WidgetLink.conversation(context.attributes.convId).url)
            .keylineTint(tint)
        }
    }
}

enum TurnStyle {
    static var tint: Color { WidgetStore.read()?.tint ?? Accent.vermilion.tint }

    static func steps(_ count: Int) -> String {
        count == 0 ? String(localized: "Working") : String(localized: "\(count) tool steps")
    }
}

struct TurnLockScreenView: View {
    let steps: Int
    let startedAt: Date

    var body: some View {
        HStack(spacing: 12) {
            WorkingGlyph(tint: TurnStyle.tint).font(.title)
            VStack(alignment: .leading, spacing: 2) {
                Text("Yorozu is working").font(.headline)
                Text(TurnStyle.steps(steps))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(startedAt, style: .timer)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 72)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

/// Pulses while the agent works; holds still under Reduce Motion.
struct WorkingGlyph: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "ellipsis.bubble.fill")
            .foregroundStyle(tint)
            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            .accessibilityLabel(Text("Yorozu is working"))
    }
}
