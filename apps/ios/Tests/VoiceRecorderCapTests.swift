import Foundation
import Testing

extension VoiceSessionTests {
    /// The recording limit, at a quarter second of the preview's clip.
    @MainActor
    @Suite struct RecordingCap {
        @Test func theRecorderStopsAtItsLimit() async throws {
            PreviewScene.transcript = "hello"
            defer { PreviewScene.transcript = nil }
            let recorder = VoiceRecorder(limit: 0.25)

            try recorder.start()
            #expect(recorder.capture == .running)
            #expect(await eventually { recorder.capture == .capped })
            #expect(recorder.seconds == 0.25)
            let levels = recorder.levels.count

            try? await Task.sleep(for: .milliseconds(300))
            #expect(recorder.capture == .capped)
            #expect(recorder.seconds == 0.25)
            #expect(recorder.levels.count == levels)

            #expect(recorder.stop().count == 4_000)
            #expect(recorder.capture == .idle)
        }

        @Test func aCappedSessionStillTranscribes() async {
            PreviewScene.transcript = "hello"
            defer { PreviewScene.transcript = nil }
            let session = VoiceSession(recorder: VoiceRecorder(limit: 0.25))
            var delivered: [String] = []

            await session.start()
            #expect(!session.capped)
            #expect(await eventually { session.capped })
            #expect(session.phase == .recording)

            session.finish { delivered.append($0) }
            #expect(!session.capped)
            #expect(await eventually { session.phase == .idle })
            #expect(delivered == ["hello"])
        }
    }
}
