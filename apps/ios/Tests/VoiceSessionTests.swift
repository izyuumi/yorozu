import Foundation
import Testing

@MainActor
@Suite(.serialized) struct VoiceSessionTests {
    @Test func cancellingWhileTranscribingNeverDelivers() async {
        PreviewScene.transcript = "hello"
        defer { PreviewScene.transcript = nil }
        let session = VoiceSession()
        var delivered: [String] = []

        await session.start()
        #expect(await eventually { !session.recorder.levels.isEmpty })
        session.finish { delivered.append($0) }
        #expect(session.phase == .transcribing)
        session.cancel()
        #expect(session.phase == .idle)

        try? await Task.sleep(for: .seconds(1))
        #expect(delivered.isEmpty)
        #expect(session.phase == .idle)
    }

    @Test func aStaleTranscriptionCannotEndANewRecording() async {
        PreviewScene.transcript = "hello"
        defer { PreviewScene.transcript = nil }
        let session = VoiceSession()
        var delivered: [String] = []

        await session.start()
        #expect(await eventually { !session.recorder.levels.isEmpty })
        session.finish { delivered.append($0) }
        session.cancel()
        await session.start()
        #expect(session.phase == .recording)

        try? await Task.sleep(for: .seconds(1))
        #expect(session.phase == .recording)
        #expect(delivered.isEmpty)
        session.cancel()
    }

    @Test func finishingDeliversTheTranscriptOnce() async {
        PreviewScene.transcript = "hello"
        defer { PreviewScene.transcript = nil }
        let session = VoiceSession()
        var delivered: [String] = []

        await session.start()
        #expect(await eventually { !session.recorder.levels.isEmpty })
        session.finish { delivered.append($0) }
        #expect(await eventually { session.phase == .idle })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(delivered == ["hello"])
    }
}

@MainActor func eventually(within timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}
