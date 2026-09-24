import Foundation
import Testing
@testable import YorozuShared

@Test func resourceBundleIsLookedForUnderContentsResourcesBeforeTheAppRoot() {
    let app = URL(fileURLWithPath: "/Applications/Yorozu.app")
    let resources = app.appendingPathComponent("Contents/Resources")
    let candidates = ResourceBundle.candidates(resourceURL: resources, bundleURL: app)
    #expect(candidates.map(\.path) == [
        "/Applications/Yorozu.app/Contents/Resources/YorozuShared_YorozuShared.bundle",
        "/Applications/Yorozu.app/YorozuShared_YorozuShared.bundle",
    ])
}

@Test func resourceBundleFallsBackToTheAppRootWhenThereIsNoResourceDirectory() {
    let tool = URL(fileURLWithPath: "/usr/local/bin")
    let candidates = ResourceBundle.candidates(resourceURL: nil, bundleURL: tool)
    #expect(candidates.map(\.path) == ["/usr/local/bin/YorozuShared_YorozuShared.bundle"])
}

@Test func resourceBundleResolvesToTheBundleThatCarriesTheProviderMarks() {
    // Under `swift test` neither candidate exists beside the test host, so this is the
    // generated-accessor fallback: it must still be the bundle the marks are processed into.
    let bundle = ResourceBundle.shared
    #expect(bundle.bundleURL.lastPathComponent == "YorozuShared_YorozuShared.bundle")
}
