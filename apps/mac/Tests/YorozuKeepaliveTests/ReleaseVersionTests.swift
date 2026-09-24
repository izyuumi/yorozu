import Testing

@testable import YorozuKeepalive

@Test func releaseUpdatesNeverDowngradeMarketingVersion() {
    // Build counters intentionally play no part: 0.4.1 may be built after the 0.5.0 beta.
    #expect(!ReleaseVersion.allowsUpdate(from: "0.5.0", to: "0.4.1"))
    #expect(ReleaseVersion.allowsUpdate(from: "0.5.0", to: "0.5.0"))
    #expect(ReleaseVersion.allowsUpdate(from: "0.5.0", to: "0.5.1"))
    #expect(ReleaseVersion.allowsUpdate(from: "0.9.0", to: "0.10.0"))
    #expect(!ReleaseVersion.allowsUpdate(from: "0.10.0", to: "0.9.0"))
}

@Test func legacyBetaDisplayLabelsRetainTheirNumericVersion() {
    #expect(ReleaseVersion.allowsUpdate(from: "0.5.0", to: "0.5.0 Beta"))
    #expect(!ReleaseVersion.allowsUpdate(from: "0.5.0", to: "0.4.1 Beta"))
    #expect(ReleaseVersion.allowsUpdate(from: "0.5.0 Beta", to: "0.5.0"))
}

@Test func unverifiedReleaseVersionsAreRejected() {
    for version in ["", "12000", "0.5", "0.5.0.1", "0..5", "0.5.-1", "0.5.+1", "0.5.0beta",
                    "0.5.0 Beta invalid", "0.5.0\n", "０.５.０", "999999999999999999999999.0.0"] {
        #expect(!ReleaseVersion.allowsUpdate(from: "0.5.0", to: version))
        #expect(!ReleaseVersion.allowsUpdate(from: version, to: "0.5.0"))
    }
    #expect(!ReleaseVersion.allowsUpdate(from: nil, to: "0.5.0"))
}
