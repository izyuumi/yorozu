import Testing

@Suite struct SceneLifecycleTests {
    @Test func aDrainThatOutlivesAQuickReturnDoesNotSuspend() {
        var lifecycle = SceneLifecycle()
        let visit = lifecycle.enterBackground()
        lifecycle.becomeInactive()
        lifecycle.becomeActive()

        let suspended = lifecycle.suspend(visit: visit)
        #expect(!suspended)
        #expect(lifecycle.isActive)
        #expect(!lifecycle.stillSuspended(visit: visit))
    }

    @Test func aDrainInTheSameVisitSuspends() {
        var lifecycle = SceneLifecycle()
        let visit = lifecycle.enterBackground()

        let suspended = lifecycle.suspend(visit: visit)
        #expect(suspended)
        #expect(lifecycle.stillSuspended(visit: visit))
    }

    @Test func aReturnAndLeaveAgainInvalidatesTheOldDrain() {
        var lifecycle = SceneLifecycle()
        let first = lifecycle.enterBackground()
        lifecycle.becomeInactive()
        lifecycle.becomeActive()
        lifecycle.becomeInactive()
        let second = lifecycle.enterBackground()

        let firstSuspended = lifecycle.suspend(visit: first)
        #expect(!firstSuspended)
        let secondSuspended = lifecycle.suspend(visit: second)
        #expect(secondSuspended)
        #expect(lifecycle.stillSuspended(visit: second))
        #expect(!lifecycle.stillSuspended(visit: first))
    }

    @Test func prewarmingInvalidatesTheDrainBeforeActivation() {
        var lifecycle = SceneLifecycle()
        let visit = lifecycle.enterBackground()
        lifecycle.becomeInactive()

        let suspended = lifecycle.suspend(visit: visit)
        #expect(!suspended)
        #expect(!lifecycle.isActive)
        #expect(!lifecycle.stillSuspended(visit: visit))
    }

    @Test func aScheduledStopCannotStopANewerSuspendedVisit() {
        var lifecycle = SceneLifecycle()
        let first = lifecycle.enterBackground()
        let firstSuspended = lifecycle.suspend(visit: first)
        #expect(firstSuspended)
        lifecycle.becomeInactive()
        #expect(!lifecycle.stillSuspended(visit: first))
        lifecycle.becomeActive()
        lifecycle.becomeInactive()
        let second = lifecycle.enterBackground()
        let secondSuspended = lifecycle.suspend(visit: second)

        #expect(secondSuspended)
        #expect(!lifecycle.stillSuspended(visit: first))
        #expect(lifecycle.stillSuspended(visit: second))
    }

    @Test func aForegroundRoundTripInvalidatesAWakeSnapshot() {
        var lifecycle = SceneLifecycle()
        let snapshot = lifecycle
        lifecycle.becomeActive()
        lifecycle.becomeInactive()

        #expect(!lifecycle.isActive)
        #expect(lifecycle != snapshot)
    }
}
