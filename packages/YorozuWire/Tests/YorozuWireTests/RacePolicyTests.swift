import Testing
@testable import YorozuWire

/// When each leg starts and how long a lost session waits (#532 items 5 and 6).
struct RacePolicyTests {
    typealias Start = RacePolicy.Start
    let direct = ["ws://127.0.0.1:8738", "ws://[::1]:8738"]

    @Test func withoutHistoryEverythingStartsAtOnceButTheStagger() {
        #expect(RacePolicy.plan(direct: direct, lastWinner: nil)
            == .init(direct: [Start(index: 0, delay: .zero), Start(index: 1, delay: .milliseconds(50))], relay: .zero))
    }

    @Test func aDirectWinnerGoesFirstAndTheRelayWaits() {
        #expect(RacePolicy.plan(direct: direct, lastWinner: direct[1])
            == .init(direct: [Start(index: 1, delay: .zero), Start(index: 0, delay: .milliseconds(50))], relay: .milliseconds(300)))
        #expect(RacePolicy.plan(direct: direct, lastWinner: direct[0])
            == .init(direct: [Start(index: 0, delay: .zero), Start(index: 1, delay: .milliseconds(50))], relay: .milliseconds(300)))
    }

    @Test func theCandidatesAfterTheWinnerFollow50msApart() {
        let three = direct + ["ws://192.168.1.2:8738"]
        #expect(RacePolicy.plan(direct: three, lastWinner: three[2]).direct
            == [Start(index: 2, delay: .zero), Start(index: 0, delay: .milliseconds(50)), Start(index: 1, delay: .milliseconds(100))])
    }

    @Test func aRelayWinnerStartsFirst() {
        #expect(RacePolicy.plan(direct: direct, lastWinner: RacePolicy.relayKey)
            == .init(direct: [Start(index: 0, delay: .zero), Start(index: 1, delay: .milliseconds(50))], relay: .zero))
    }

    @Test func aStaleOrUnknownWinnerIsNoHistory() {
        let none = RacePolicy.plan(direct: direct, lastWinner: nil)
        #expect(RacePolicy.plan(direct: direct, lastWinner: "ws://10.0.0.9:8738") == none)
        #expect(RacePolicy.plan(direct: direct, lastWinner: "") == none)
        #expect(RacePolicy.plan(direct: [], lastWinner: direct[0]) == .init(direct: [], relay: .zero))
    }

    @Test func quickLossesBackOffUpTo30s() {
        let pauses = (0...9).map(RacePolicy.pause(quickLosses:))
        #expect(pauses == [.zero, .zero, .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30), .seconds(30)])
        #expect(RacePolicy.pause(quickLosses: 1000) == .seconds(30))
    }

    @Test func aLongSessionResetsTheCount() {
        #expect(RacePolicy.quickLosses(after: 0, lived: .seconds(3)) == 1)
        #expect(RacePolicy.quickLosses(after: 1, lived: .milliseconds(9_999)) == 2)
        #expect(RacePolicy.quickLosses(after: 5, lived: .seconds(10)) == 0)
        #expect(RacePolicy.quickLosses(after: 5, lived: .seconds(600)) == 0)
    }
}
