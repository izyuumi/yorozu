import Foundation
import Testing

@MainActor
@Suite struct AppModelSceneTests {
    private let model: AppModel

    init() throws {
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
        model.setActive(true)
        model.setActive(false)
        let visit = model.enterBackground()
        model.prewarm()
        model.setActive(false)
        model.resume()
        model.setActive(true)
        model.suspend(visit: visit)
        #expect(model.active)

        try await Task.sleep(for: .milliseconds(600))
        #expect(model.active)
    }

    @Test func aDrainInTheSameVisitSuspends() {
        model.setActive(true)
        model.setActive(false)
        let visit = model.enterBackground()
        model.suspend(visit: visit)
        #expect(!model.active)
    }
}
