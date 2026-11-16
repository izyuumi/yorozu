import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private let running = [YorozuJob(token: "turn", kind: .turn, startedAt: t0)]

private var turnLabel: ActivityLabels {
    var labels = ActivityLabels()
    labels.upsert(token: "turn", convId: "conv", kind: .turn, title: "Trip", previews: true)
    // A leftover entry the parent `pushed` path would prune, so a write changes the file bytes.
    labels.upsert(token: "stale", convId: "other", kind: .turn, title: "Old", previews: true)
    return labels
}

@Suite struct NotificationEffectsTests {
    @Test(arguments: ["reply", "failed", "approval"])
    func aReplyPushNeverWritesTheActivity(_ cls: String) {
        let effects = NotificationEffects.of(cls, convId: "conv", jobs: running, labels: turnLabel)
        #expect(effects.activity == nil)
        #expect(effects.labels == nil)
    }

    @Test func aReplyPushStillUpdatesTheWidgetSnapshot() {
        #expect(NotificationEffects.of("reply", convId: "conv", jobs: running, labels: turnLabel).updatesWidget)
        #expect(!NotificationEffects.of("failed", convId: "conv", jobs: running, labels: turnLabel).updatesWidget)
        #expect(!NotificationEffects.of("approval", convId: "conv", jobs: running, labels: turnLabel).updatesWidget)
    }

    @Test(arguments: ["reply", "approval"])
    func labelsFileIsByteIdenticalAfterAPush(_ cls: String) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ActivityLabels-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        ActivityLabelsStore.write(turnLabel, previews: true, to: url)
        let before = try Data(contentsOf: url)
        let effects = NotificationEffects.of(cls, convId: "conv", jobs: running, labels: ActivityLabelsStore.read(from: url))
        if let labels = effects.labels { ActivityLabelsStore.write(labels, previews: true, to: url) }
        #expect(try Data(contentsOf: url) == before)
    }
}
