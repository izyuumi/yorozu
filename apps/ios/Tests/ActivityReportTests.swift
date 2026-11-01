import Foundation
import Testing
import YorozuWire

/// 2027-01-15T08:00:00Z, the instant `plugins/openclaw-yorozu/test/liveactivity.test.ts` builds the fixture from.
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let conv = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b"

@Suite struct ActivityReportTests {
    /// The plugin's counts-only state, as the relay forwards it in `content-state`, decodes the way ActivityKit
    /// decodes it: the default `JSONDecoder`, dates as seconds since 2001.
    @Test func pluginContentStateDecodes() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/activity-content-state.json")
        let state = try JSONDecoder().decode(YorozuActivityState.self, from: Data(contentsOf: url))
        #expect(state.jobs == [
            YorozuJob(token: "recLocal-_012345", kind: .recording, startedAt: t0 + 10.5),
            YorozuJob(token: "AAAAAAAAAAAAAAAA", kind: .turn, state: .done, steps: 2, startedAt: t0, finishedAt: t0 + 60.25),
        ])
        // And the app's own encoding is the same shape, so its updates and the plugin's agree.
        let again = try JSONDecoder().decode(YorozuActivityState.self, from: JSONEncoder().encode(state))
        #expect(again == state)
    }

    @Test func reportCarriesMillisAndOnlyRunningTurns() throws {
        let turn = YorozuJob(token: "AAAAAAAAAAAAAAAA", kind: .turn, steps: 3, startedAt: t0)
        let finished = YorozuJob(token: "BBBBBBBBBBBBBBBB", kind: .turn, state: .done, startedAt: t0, finishedAt: t0 + 0.25)
        let recording = YorozuJob(token: "CCCCCCCCCCCCCCCC", kind: .recording, startedAt: t0 + 1)
        let report = ActivityReport(pushToken: "ab", activity: [turn, finished, recording],
                                    turns: [turn.token: conv, finished.token: conv, recording.token: conv, "DDDDDDDDDDDDDDDD": "nope"])
        #expect(report.turns == [turn.token: conv])
        #expect(report.jobs == [
            .init(token: turn.token, kind: "turn", state: "running", steps: 3, startedAt: 1_800_000_000_000),
            .init(token: finished.token, kind: "turn", state: "done", startedAt: 1_800_000_000_000, finishedAt: 1_800_000_000_250),
            .init(token: recording.token, kind: "recording", state: "running", startedAt: 1_800_000_001_000),
        ])
        let json = try #require(String(data: WireEvent.liveActivity(report).encoded(), encoding: .utf8))
        #expect(json.hasPrefix(#"{"data":{"jobs":[{"kind":"turn","startedAt":1800000000000,"state":"running","steps":3"#))
        #expect(json.hasSuffix(#""kind":"live_activity"}"#))
    }

    @Test func endedReportHasNoToken() throws {
        let json = try #require(String(data: WireEvent.liveActivity(ActivityReport(pushToken: nil)).encoded(), encoding: .utf8))
        #expect(json == #"{"data":{"jobs":[],"turns":{}},"kind":"live_activity"}"#)
    }
}
