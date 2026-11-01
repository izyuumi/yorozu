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

    @Test func aRepeatAcrossASilentOverlapIsKept() {
        #expect(TranscriptSeam.join(["彼はそう言った", "言ったことを覚えている"], overlapSpeechSeconds: [0])
            == "彼はそう言った言ったことを覚えている")
        #expect(TranscriptSeam.join(["Thank you, you know", "You know, it was great"], overlapSpeechSeconds: [0])
            == "Thank you, you know You know, it was great")
    }

    @Test func twoCJKCharactersAreKeptAndThreeDropped() {
        #expect(TranscriptSeam.join(["これは本当", "本当にいい"], overlapSpeechSeconds: [1]) == "これは本当本当にいい")
        #expect(TranscriptSeam.join(["今日は晴れた", "晴れた日だ"], overlapSpeechSeconds: [1]) == "今日は晴れた日だ")
    }

    @Test func theSpeechInTheOverlapCapsTheRepeat() {
        // 1 s of speech: 4 words, 10 characters.
        #expect(TranscriptSeam.join(["We said one two three four five", "one two three four five again"], overlapSpeechSeconds: [1])
            == "We said one two three four five one two three four five again")
        #expect(TranscriptSeam.join(["We said one two three four", "one two three four again"], overlapSpeechSeconds: [1])
            == "We said one two three four again")
        #expect(TranscriptSeam.join(["前あいうえおかきくけこさ", "あいうえおかきくけこさ後"], overlapSpeechSeconds: [1])
            == "前あいうえおかきくけこさあいうえおかきくけこさ後")
        #expect(TranscriptSeam.join(["前あいうえおかきくけこ", "あいうえおかきくけこ後"], overlapSpeechSeconds: [1])
            == "前あいうえおかきくけこ後")
        // 0.5 s: 2 words, 5 characters.
        #expect(TranscriptSeam.join(["x one two three", "one two three y"], overlapSpeechSeconds: [0.5])
            == "x one two three one two three y")
        #expect(TranscriptSeam.join(["x one two", "one two y"], overlapSpeechSeconds: [0.5]) == "x one two y")
        #expect(TranscriptSeam.join(["前あいうえおか", "あいうえおか後"], overlapSpeechSeconds: [0.5]) == "前あいうえおかあいうえおか後")
        #expect(TranscriptSeam.join(["前あいうえお", "あいうえお後"], overlapSpeechSeconds: [0.5]) == "前あいうえお後")
        // Never more than the overlap's length allows.
        #expect(TranscriptSeam.caps(speechSeconds: 5) == (4, 10))
        #expect(TranscriptSeam.caps(speechSeconds: 0.3) == (2, 3))
    }

    @Test func aPartAfterAnEmptyOneSharesNoAudio() {
        #expect(TranscriptSeam.join(["See you tomorrow", "", "see you tomorrow."], overlapSpeechSeconds: [1, 1])
            == "See you tomorrow see you tomorrow.")
    }
}
