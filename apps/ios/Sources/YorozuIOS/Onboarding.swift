import SwiftUI

/// Shown once per pairing, after the first handshake: how a client device works, then the notification
/// permission. A sheet, so an iPad gets the system's centred form-sheet width; each page scrolls at large type.
struct OnboardingView: View {
    let onFinish: () -> Void

    private enum Page { case howItWorks, notifications }
    @State private var page = Page.howItWorks

    var body: some View {
        TabView(selection: $page) {
            howItWorks.tag(Page.howItWorks)
            notifications.tag(Page.notifications)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .interactiveDismissDisabled()
        .yorozuTint()
    }

    private var howItWorks: some View {
        OnboardingPage(symbol: "desktopcomputer", title: "How Yorozu works") {
            OnboardingPoint(symbol: "cpu", title: "Your host does the work",
                            detail: "Yorozu runs on your host. Research, writing and code happen there.")
            OnboardingPoint(symbol: "ipad.and.iphone", title: "This device is a client",
                            detail: "Chat, follow Activities and Scheduled tasks, and see the results here.")
            OnboardingPoint(symbol: "lock", title: "End-to-end encrypted",
                            detail: "Messages go through the relay end-to-end encrypted, or straight to the host on the same network when Direct connection is on.")
            OnboardingPoint(symbol: "moon.zzz", title: "Keep the host awake",
                            detail: "Work runs only while the host is awake. Messages wait in the relay for up to 24 hours.")
        } actions: {
            Button { withAnimation { page = .notifications } } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var notifications: some View {
        OnboardingPage(symbol: "bell.badge", title: "Stay in the loop") {
            Text("Get a notification when a result is ready, a task fails, Yorozu has a question, or the host is back online. Notifications never show message content.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } actions: {
            Button {
                Task {
                    // The token is asked for at every launch already; asking again once allowed is harmless.
                    if await LocalNotices.askPermission() { UIApplication.shared.registerForRemoteNotifications() }
                    onFinish()
                }
            } label: {
                Text("Allow Notifications").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Not Now", action: onFinish)
                .frame(minHeight: controlTarget)
        }
    }
}

/// One page: a symbol, a title, the content, and the buttons pinned below it.
private struct OnboardingPage<Content: View, Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(spacing: LayoutMetrics.section) {
                Image(systemName: symbol)
                    .font(.system(.largeTitle))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title.weight(.semibold))
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: LayoutMetrics.gutter) { content }
            }
            .padding(LayoutMetrics.section)
            .frame(maxWidth: LayoutMetrics.readingWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: LayoutMetrics.inner) { actions }
                .padding(.horizontal, LayoutMetrics.section)
                // Clear of the page dots.
                .padding(.bottom, LayoutMetrics.section + LayoutMetrics.gutter)
                .frame(maxWidth: LayoutMetrics.readingWidth)
        }
    }
}

private struct OnboardingPoint: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    /// One column for every icon, so the titles line up whatever each symbol's width; scales with the headline.
    @ScaledMetric(relativeTo: .headline) private var iconColumn: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: LayoutMetrics.stack) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(.tint)
                .frame(width: iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
