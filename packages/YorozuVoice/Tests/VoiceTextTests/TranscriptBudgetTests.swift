import Testing
@testable import VoiceText

struct TranscriptBudgetTests {
    /// Clip length and tokens LFM3-Audio wrote for the densest and fastest clips measured.
    private let measured: [(seconds: Double, tokens: Int)] = [(5.89, 61), (7.94, 63), (6.85, 56), (5.12, 32), (13.5, 57)]

    @Test func realSpeechKeepsTwiceTheRoomItNeeded() {
        for clip in measured {
            #expect(TranscriptBudget.maxTokens(seconds: clip.seconds) >= 2 * clip.tokens)
        }
    }

    @Test func theBudgetGrowsWithTheClip() {
        #expect(TranscriptBudget.maxTokens(seconds: 4) == 132)
        #expect(TranscriptBudget.maxTokens(seconds: 60) == 1_980)
    }

    @Test func aLoopStopsLongBeforeTheContextEnds() {
        #expect(TranscriptBudget.maxTokens(seconds: 8) < 300)
    }

    @Test func shortOrOddClipsGetTheMinimum() {
        #expect(TranscriptBudget.maxTokens(seconds: 0.5) == TranscriptBudget.minimum)
        #expect(TranscriptBudget.maxTokens(seconds: 0) == TranscriptBudget.minimum)
        #expect(TranscriptBudget.maxTokens(seconds: -1) == TranscriptBudget.minimum)
        #expect(TranscriptBudget.maxTokens(seconds: .nan) == TranscriptBudget.minimum)
    }

    @Test func longClipsStopAtTheContext() {
        #expect(TranscriptBudget.maxTokens(seconds: 300) == TranscriptBudget.maximum)
        #expect(TranscriptBudget.maxTokens(seconds: .infinity) == TranscriptBudget.maximum)
    }
}
