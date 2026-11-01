import Testing
@testable import VoiceText

struct TranscriptSeamTests {
    @Test func englishOverlapIsDropped() {
        #expect(TranscriptSeam.join(["We met on Monday to plan the release", "plan the release and the launch."])
            == "We met on Monday to plan the release and the launch.")
    }

    @Test func japaneseOverlapIsDropped() {
        #expect(TranscriptSeam.join(["明日の会議は十時からです。", "十時からです。資料は前日に送ります。"])
            == "明日の会議は十時からです。資料は前日に送ります。")
    }

    @Test func mixedScriptsOverlapIsDropped() {
        #expect(TranscriptSeam.join(["次のリリースはYorozu 2です", "Yorozu 2です。来週出します。"])
            == "次のリリースはYorozu 2です。来週出します。")
    }

    @Test func partsWithoutOverlapAreJoined() {
        #expect(TranscriptSeam.join(["First part.", "Second part."]) == "First part. Second part.")
        #expect(TranscriptSeam.join(["前半です。", "後半です。"]) == "前半です。後半です。")
    }

    @Test func oneRepeatedWordIsKept() {
        #expect(TranscriptSeam.join(["I think that", "that is right."]) == "I think that that is right.")
    }

    @Test func caseWidthAndPunctuationAreIgnored() {
        #expect(TranscriptSeam.join(["We shipped it, Last Week.", "last week we shipped the fix."])
            == "We shipped it, Last Week. we shipped the fix.")
        #expect(TranscriptSeam.join(["Build ＡＢＣ ready", "abc ready now"]) == "Build ＡＢＣ ready now")
        #expect(TranscriptSeam.join(["ｶﾀｶﾅです", "カタカナです、はい"]) == "ｶﾀｶﾅです、はい")
    }

    @Test func emptyPartsAreSkipped() {
        #expect(TranscriptSeam.join([]) == "")
        #expect(TranscriptSeam.join(["", "  ", "Hello there.", "", "General Kenobi."]) == "Hello there. General Kenobi.")
    }

    @Test func aPartThatIsAllOverlapAddsOnlyItsPunctuation() {
        #expect(TranscriptSeam.join(["See you tomorrow", "see you tomorrow."]) == "See you tomorrow.")
        #expect(TranscriptSeam.join(["See you tomorrow.", "see you tomorrow."]) == "See you tomorrow.")
    }

    @Test func overlapsLongerThanTheLimitAreKept() {
        let words = (1...20).map { "w\($0)" }.joined(separator: " ")
        #expect(TranscriptSeam.join([words, words]) == words + " " + words)
        let kana = "いろはにほへとちりぬるをわかよたれそつねならむうゐのおくやま"
        #expect(TranscriptSeam.join([kana, kana]) == kana + kana)
    }
}
