import Testing

@testable import YorozuMac

/// Exercise the route used both when reopening setup and when choosing a role again.
/// Calling the pure helper never starts a session or touches pairing keys and preferences.
@MainActor @Test func onboardingRoutesByRoleAndHostHandshake() {
    #expect(OnboardingView.step(for: nil, connected: false) == .role)
    #expect(OnboardingView.step(for: nil, connected: true) == .role)
    #expect(OnboardingView.step(for: .host, connected: false) == .hostPair)
    #expect(OnboardingView.step(for: .host, connected: true) == .hostPair)

    // A pending or offline client must wait for an encrypted host greeting.
    #expect(OnboardingView.step(for: .client, connected: false) == .clientPair)
    // Includes a handshake that finished while the user was on the role page.
    #expect(OnboardingView.step(for: .client, connected: true) == .clientDone)
}
