import Foundation
import Testing

@MainActor
@Suite struct AppModelSceneTests {
    private let model: AppModel

    init() throws {
        // Fail before AppModel can choose the live path or resolve an app-owned support directory.
        try #require(ProcessInfo.processInfo.arguments.contains("--demo"))
        let bundleID = try #require(Bundle.main.bundleIdentifier)
        try #require(!bundleID.hasPrefix("to.yumi.yorozu"))
        try #require(!clientSupportDirectory.path.contains("to.yumi.yorozu"))
        let environment = ProcessInfo.processInfo.environment
        let home = try #require(environment["HOME"])
        try #require(home == environment["CFFIXED_USER_HOME"])
        try #require(URL(fileURLWithPath: home).lastPathComponent.hasPrefix("YorozuTests-"))
        try #require(FileManager.default.fileExists(atPath: home))
        model = AppModel()
        try #require(model.isDemo)
    }

    @Test func aStaleDrainAfterAQuickReturnLeavesTheModelActive() async throws {
        model.setActive(true) // RootView initial onChange: .active.
        model.setActive(false) // RootView initial-enabled onChange: .inactive from .active.
        let visit = model.enterBackground() // RootView onChange: .background; hold the drain before suspend(visit:); iOS initial-enabled handler does nothing.
        model.prewarm() // RootView onChange: .inactive from .background.
        model.setActive(false) // RootView initial-enabled onChange: .inactive from .background.
        model.resume() // RootView onChange: .active.
        model.setActive(true) // RootView initial-enabled onChange: .active.
        model.suspend(visit: visit) // RootView .background handler: held drain finishes after the return to .active.
        #expect(model.active)

        try await Task.sleep(for: .milliseconds(600))
        #expect(model.active)
    }

    @Test func aDrainInTheSameVisitSuspends() {
        model.setActive(true) // RootView initial onChange: .active.
        model.setActive(false) // RootView initial-enabled onChange: .inactive from .active.
        let visit = model.enterBackground() // RootView onChange: .background; iOS initial-enabled handler does nothing.
        model.suspend(visit: visit) // RootView .background handler: drain finishes during the same background visit.
        #expect(!model.active)
    }
}
