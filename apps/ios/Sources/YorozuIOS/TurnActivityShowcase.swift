import SwiftUI
import YorozuShared

/// Screenshot only. Draws the Live Activity as the lock screen presents it — the same
/// ``TurnLockScreenView`` the widget uses, in the rounded container iOS puts it in — once per
/// status, so one picture says what all four look like.
///
/// It exists because a simulator cannot be told to lock its screen with an activity running on
/// it, and the Dynamic Island will not render one for a headless `simctl` screenshot either.
/// Rendering the real view is the honest version of that picture.
struct TurnActivityShowcase: View {
    private static let started = Date().addingTimeInterval(-64)

    var body: some View {
        ZStack {
            // Standing in for a wallpaper, so the cards are read the way they are on a lock
            // screen: floating on something, not on a page.
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.10, blue: 0.16), Color(red: 0.03, green: 0.03, blue: 0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                VStack(spacing: -6) {
                    Text(Self.started, format: .dateTime.weekday(.wide).day().month(.wide))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(Self.started, format: .dateTime.hour().minute())
                        .font(.system(size: 84, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.bottom, 18)

                ForEach([TurnStatus.working, .needsApproval, .done, .failed], id: \.self) { status in
                    TurnLockScreenView(
                        attributes: TurnAttributes(threadId: "showcase"),
                        state: TurnAttributes.ContentState(status: status, started: Self.started),
                        title: "Weeknight dinners"
                    )
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 60)
        }
        .environment(\.colorScheme, .dark)
    }
}
