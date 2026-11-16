import Foundation
import Testing

@Suite struct NotificationEffectsTests {
    @Test func aReplyPushStillUpdatesTheWidgetSnapshot() {
        #expect(NotificationEffects.of("reply").updatesWidget)
        #expect(!NotificationEffects.of("failed").updatesWidget)
        #expect(!NotificationEffects.of("approval").updatesWidget)
        #expect(!NotificationEffects.of("sync").updatesWidget)
    }
}
