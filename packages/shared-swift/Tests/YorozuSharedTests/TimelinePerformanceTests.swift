import Foundation
import Testing
@testable import YorozuShared

@MainActor @Test func unchangedTimelineReusesGroupingAndInvalidatesForResultsAndRunningState() {
    let timeline = ThreadTimeline()
    timeline.events = (0..<1000).map { i in
        YorozuEvent(id: "event-\(i)", threadId: "t", ts: i, agentId: "main",
            payload: .toolCall(ToolCallData(callId: "call-\(i)", name: "Bash", args: [:])))
    }
    let reference = chatRows(from: timeline.events, generating: true)
    #expect(timeline.rows(generating: true) == reference)
    let rawStart = ContinuousClock.now
    for _ in 0..<100 { #expect(chatRows(from: timeline.events, generating: true).count == reference.count) }
    let raw = rawStart.duration(to: .now)
    let cachedStart = ContinuousClock.now
    for _ in 0..<100 { #expect(timeline.rows(generating: true).count == reference.count) }
    let cached = cachedStart.duration(to: .now)
    print("PERF row-grouping 100x1000: raw=\(raw), cached=\(cached)")
    #expect(cached < raw)
    timeline.events.append(YorozuEvent(id: "result", threadId: "t", ts: 1001, agentId: "main", payload: .toolResult(ToolResultData(callId: "call-999", ok: true, output: "done"))))
    #expect(timeline.rows(generating: true) == chatRows(from: timeline.events, generating: true))
    #expect(timeline.rows(generating: false) == chatRows(from: timeline.events, generating: false))
}
