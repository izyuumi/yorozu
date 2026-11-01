import Testing
@testable import VoiceText

struct TranscriptDensityTests {
    /// A transcript of `count` letters.
    private func text(_ count: Int) -> String { String(repeating: "a", count: count) }

    @Test func lettersCountWordsAndCJKCharactersButNotSpacesOrPunctuation() {
        #expect(TranscriptDensity.letters(in: "Hello, world 42!") == 12)
        #expect(TranscriptDensity.letters(in: "今日は、カタカナ。") == 7)
        #expect(TranscriptDensity.letters(in: " .,!?") == 0)
    }

    @Test func aWindowFarBelowTheMedianIsSparse() {
        // 18 letters a second, except the third window at 9 (a skipped stretch).
        let windows = [(text(1_620), 90.0), (text(1_620), 90.0), (text(810), 90.0), (text(1_620), 90.0)]
        #expect(TranscriptDensity.sparse(windows) == [2])
    }

    @Test func aWindowJustAboveTheThresholdIsNotSparse() {
        // Median 10 a second; 7.1 is above 0.7 of it, 6.9 below.
        #expect(TranscriptDensity.sparse([(text(100), 10.0), (text(100), 10.0), (text(71), 10.0)]).isEmpty)
        #expect(TranscriptDensity.sparse([(text(100), 10.0), (text(100), 10.0), (text(69), 10.0)]) == [2])
    }

    @Test func densityIsPerSecondOfSpeech() {
        // The same rate in windows with different speech.
        #expect(TranscriptDensity.sparse([(text(900), 90.0), (text(300), 30.0), (text(500), 50.0)]).isEmpty)
    }

    @Test func fewerThanThreeJudgedWindowsAreNeverSparse() {
        #expect(TranscriptDensity.sparse([(text(1_000), 90.0), (text(10), 90.0)]).isEmpty)
        // Windows under ten seconds of speech are not judged, nor count towards the three.
        #expect(TranscriptDensity.sparse([(text(1_000), 90.0), (text(10), 90.0), (text(0), 9.0)]).isEmpty)
    }

    @Test func aShortWindowIsNeverSparse() {
        let windows = [(text(900), 90.0), (text(900), 90.0), (text(900), 90.0), (text(0), 9.9)]
        #expect(TranscriptDensity.sparse(windows).isEmpty)
    }

    @Test func theMedianOfAnEvenCountIsTheMeanOfTheMiddleTwo() {
        // Densities 4, 10, 20, 30: median 15, threshold 10.5, so 4 and 10 are sparse.
        let windows = [(text(400), 100.0), (text(1_000), 100.0), (text(2_000), 100.0), (text(3_000), 100.0)]
        #expect(TranscriptDensity.sparse(windows) == [0, 1])
    }

    @Test func anEmptyTranscriptWithSpeechIsSparse() {
        #expect(TranscriptDensity.sparse([(text(900), 90.0), (text(900), 90.0), ("", 60.0)]) == [2])
    }

    @Test func aReplacementMustSayFifteenPercentMore() {
        #expect(TranscriptDensity.isBetter(text(115), than: text(100)))
        #expect(!TranscriptDensity.isBetter(text(114), than: text(100)))
        #expect(!TranscriptDensity.isBetter(text(90), than: text(100)))
        #expect(TranscriptDensity.isBetter(text(1), than: ""))
        #expect(!TranscriptDensity.isBetter("", than: ""))
    }
}
