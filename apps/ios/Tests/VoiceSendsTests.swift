import Foundation
import SpeechEngines
import Testing

extension VoiceSessionTests {
    /// Voice messages sent straight from the composer, against a speech engine the test answers.
    @MainActor
    @Suite struct Sends {
        private let conv = "conv-a"

        @Test func discardingWhileTranscribingNeverSends() async throws {
            PreviewScene.transcript = nil
            let engine = HeldEngine()
            let sends = VoiceSends()
            var sent: [String] = []

            sends.add(clip(engine), in: conv) { sent.append($0) }
            #expect(await engine.reaches(1))
            let id = try #require(sends.pending[conv]?.first?.id)
            sends.discard(id, in: conv)
            await engine.answer(.success("hello"))

            try? await Task.sleep(for: .milliseconds(200))
            #expect(sent.isEmpty)
            #expect((sends.pending[conv] ?? []).isEmpty)
        }

        @Test func retryWhileTranscribingSendsOnce() async throws {
            PreviewScene.transcript = nil
            defer { PreviewScene.transcript = nil }
            let engine = HeldEngine()
            let sends = VoiceSends()
            var sent: [String] = []

            sends.add(clip(engine), in: conv) { sent.append($0) }
            #expect(await engine.reaches(1))
            let id = try #require(sends.pending[conv]?.first?.id)
            // A second transcription, should Retry start one, gets the preview's transcript 600 ms later.
            PreviewScene.transcript = "hello"
            sends.retry(id, in: conv)
            #expect(sends.pending[conv]?.first?.failure == nil)
            await engine.answer(.success("hello"))

            #expect(await eventually { !sent.isEmpty })
            try? await Task.sleep(for: .milliseconds(800))
            await engine.answer(.success("hello"))
            #expect(sent == ["hello"])
            #expect(await engine.calls == 1)
            #expect((sends.pending[conv] ?? []).isEmpty)
        }

        @Test func aFailureThenRetrySendsOnceAndClearsTheRow() async throws {
            PreviewScene.transcript = nil
            let engine = HeldEngine()
            let sends = VoiceSends()
            var sent: [String] = []

            sends.add(clip(engine), in: conv) { sent.append($0) }
            #expect(await engine.reaches(1))
            await engine.answer(.failure(SpeechEngineError.modelUnavailable))
            #expect(await eventually { sends.pending[conv]?.first?.failure != nil })
            #expect(sent.isEmpty)

            let id = try #require(sends.pending[conv]?.first?.id)
            sends.retry(id, in: conv)
            #expect(sends.pending[conv]?.first?.failure == nil)
            #expect(await engine.reaches(2))
            await engine.answer(.success("hi"))

            #expect(await eventually { (sends.pending[conv] ?? []).isEmpty })
            try? await Task.sleep(for: .milliseconds(100))
            #expect(sent == ["hi"])
        }

        @Test func successSendsOnceAndRemovesTheRow() async {
            PreviewScene.transcript = nil
            let engine = HeldEngine()
            let sends = VoiceSends()
            var sent: [String] = []

            sends.add(clip(engine), in: conv) { sent.append($0) }
            #expect(sends.pending[conv]?.count == 1)
            #expect(sends.pending[conv]?.first?.failure == nil)
            #expect(await engine.reaches(1))
            await engine.answer(.success("hello"))

            #expect(await eventually { (sends.pending[conv] ?? []).isEmpty })
            try? await Task.sleep(for: .milliseconds(100))
            #expect(sent == ["hello"])
        }

        private func clip(_ engine: HeldEngine) -> VoiceClip {
            VoiceClip(samples: [0.1, 0.2, 0.1], loading: Task<any SpeechEngine, Error> { engine })
        }
    }
}

/// A speech engine whose calls wait until the test answers them.
private actor HeldEngine: SpeechEngine {
    private(set) var calls = 0
    private var waiting: [CheckedContinuation<String, Error>] = []

    func transcribe(_ samples: [Float], language: String?, hints: [String]) async throws -> String {
        calls += 1
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    /// Answers every call waiting now.
    func answer(_ result: Result<String, Error>) {
        for call in waiting { call.resume(with: result) }
        waiting = []
    }

    /// Whether `count` calls have started within two seconds.
    func reaches(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while calls < count, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return calls >= count
    }
}
