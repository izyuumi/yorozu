import Testing
@testable import YorozuMac

@Test func hostPresentationDefaultsWithoutOverwritingSavedChoices() {
    #expect(HostWindowMode.enabled(savedPreference: nil))
    #expect(HostWindowMode.enabled(savedPreference: true))
    #expect(!HostWindowMode.enabled(savedPreference: false))
}

@Test func onlyHostsUseBackgroundPresentation() {
    for enabled in [true, false] {
        #expect(!HostWindowMode.active(role: nil, enabled: enabled))
        #expect(!HostWindowMode.active(role: .client, enabled: enabled))
        #expect(HostWindowMode.active(role: .host, enabled: enabled) == enabled)
    }
}

@Test func automaticLaunchPreservesClientAndOnboardingRoutes() {
    for enabled in [true, false] {
        #expect(HostWindowMode.suppressAutomaticChat(role: nil, enabled: enabled))
        #expect(!HostWindowMode.suppressAutomaticChat(role: .client, enabled: enabled))
        #expect(HostWindowMode.suppressAutomaticChat(role: .host, enabled: enabled) == enabled)
    }
}

@MainActor @Test func closingLastWindowDoesNotQuitHost() {
    #expect(!AppDelegate().applicationShouldTerminateAfterLastWindowClosed(.shared))
}
