import Testing
@testable import VoiceText

struct TranscriptDegenerationTests {
    private let hints = ["万事屋", "Yorozu", "OpenClaw", "WhisperKit"]

    private func detect(_ text: String) -> TranscriptDegeneration? { TranscriptDegeneration.detect(in: text, hints: hints) }

    @Test func cleanTranscriptsPass() {
        #expect(detect("Open Yorozu and ask OpenClaw to check the build.") == nil)
        #expect(detect("明日の会議は十時からです。") == nil)
        #expect(detect("") == nil)
    }

    @Test func speechThatRepeatsItselfPasses() {
        #expect(detect("No no, that's not it.") == nil)
        #expect(detect("Yorozu, Yorozu, are you there?") == nil)
        #expect(detect("very very good, very good") == nil)
        #expect(detect("はい、はい、わかりました。") == nil)
    }

    @Test func loopsAreCaught() {
        #expect(detect(String(repeating: "万事屋、", count: 40)) == .repetition)
        #expect(detect("I said that I said that I said that") == .repetition)
        #expect(detect("今日は今日は今日は今日は") == .repetition)
        #expect(detect("no no no") == .repetition)
    }

    @Test func aVocabularyEchoIsCaught() {
        #expect(detect("Vocabulary: 万事屋, Yorozu, OpenClaw.") == .promptEcho)
        #expect(detect("vocabulary: Yorozu") == .promptEcho)
    }

    @Test func mostlyHintsIsCaught() {
        #expect(detect("Yorozu, Test, OpenClaw") == .hintEcho)
        #expect(detect("万事屋 Yorozu") == .hintEcho)
        #expect(detect("ＹＯＲＯＺＵ whisperkit") == .hintEcho)
    }

    @Test func oneHintOrHintsInASentencePass() {
        #expect(detect("Yorozu") == nil)
        #expect(detect("万事屋") == nil)
        #expect(detect("Yorozu, Yorozu") == nil)
        #expect(detect("I moved the Yorozu build from WhisperKit to the new engine yesterday.") == nil)
    }

    @Test func withoutHintsOnlyLoopsAndEchoesCount() {
        #expect(TranscriptDegeneration.detect(in: "Yorozu OpenClaw", hints: []) == nil)
        #expect(TranscriptDegeneration.detect(in: "la la la la", hints: []) == .repetition)
    }
}
