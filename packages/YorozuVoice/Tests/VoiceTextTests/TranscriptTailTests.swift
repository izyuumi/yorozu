import Foundation
import Testing
@testable import VoiceText

struct TranscriptTailTests {
    private let rate = 16_000

    /// A clip of `seconds`, a 440 Hz tone everywhere except the silent `gaps` (start and length in seconds).
    private func clip(seconds: Double, gaps: [(Double, Double)] = []) -> [Float] {
        var samples = (0..<Int(seconds * Double(rate))).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
        for (start, length) in gaps {
            let from = Int(start * Double(rate)), to = min(samples.count, Int((start + length) * Double(rate)))
            for index in from..<to { samples[index] = 0 }
        }
        return samples
    }

    private func probe(_ samples: [Float]) -> AudioWindow? {
        let activity = VoiceActivity(samples: samples, sampleRate: rate)
        return TranscriptTail.probe(of: AudioWindow(range: 0..<samples.count, activity: activity), sampleRate: rate, activity: activity)
    }

    @Test func aWindowThatStoppedEarlyIsNotCovered() {
        // Botchan, a window that repeated an earlier sentence and stopped about 12 s before its end.
        let transcript = "んである。このばあさんがどういう因縁か俺を非常にかわいがってくれた。不思議なものである。母も死ぬ三日前に愛想をつかした親父も年中もてやましている。町内では乱暴者のアクタロウとつまびきをする。この俺を無安に人長してくれた。不思議なものである。"
        let tail = "に取り扱われるのは何とも思わない。帰ってこの清のように� four やしてくれるのを不信に考えた。"
        #expect(!TranscriptTail.covers(transcript, tail: tail))
    }

    @Test func aCompleteJapaneseWindowIsCovered() {
        let transcript = "いた。何がダメなんだか今に分からない。妙な親父があったもんだ。兄は実業家になるとか言ってしきりに英語を勉強していた。眼鏡女のような処分でずるいから中が良くなかった。10日に異変ぐらいの割で喧嘩をしていた。ある時将棋を指したら卑怯な対駒をして"
        let tail = "良くなかった。十日に異変ぐらいの割で喧嘩をしていた。ある時将棋を指したら卑怯な大駒をして。"
        #expect(TranscriptTail.covers(transcript, tail: tail))
    }

    @Test func aCompleteEnglishWindowIsCovered() {
        let transcript = "e no mice in the air, I'm afraid. But you might catch a bat, and that's very like a mouse, you know. But do cats eat bats? I wonder. And here Alice began to get rather sleepy, and went on saying to herself, in a dreamy sort of way, do cats eat bats? Do cats eat bats? And sometimes, do bats eat cats?"
        let tail = "Paying to herself, in a dreamy sort of way, do cats eat bats? Do cats eat bats? And sometimes, do bats eat cats?"
        #expect(TranscriptTail.covers(transcript, tail: tail))
    }

    @Test func anEmptyTailIsCovered() {
        #expect(TranscriptTail.covers("anything", tail: ""))
        #expect(TranscriptTail.covers("", tail: " 。, "))
    }

    @Test func caseWidthAndPunctuationAreIgnored() {
        #expect(TranscriptTail.covers("We met at ＡＢＣ Cafe!", tail: "we, met at abc cafe"))
        #expect(TranscriptTail.covers("明日は晴れ。", tail: "明日は、晴れ"))
    }

    @Test func textOnlyEarlierInTheTranscriptIsNotCovered() {
        let transcript = "the cat sat on the mat and then a long story followed about many other things entirely"
        #expect(!TranscriptTail.covers(transcript, tail: "the cat sat on the mat"))
        #expect(TranscriptTail.covers(transcript, tail: "about many other things entirely"))
    }

    @Test func aShortWindowIsNotProbed() {
        #expect(probe(clip(seconds: 29)) == nil)
    }

    @Test func aWindowWithASilentEndIsNotProbed() {
        #expect(probe(clip(seconds: 40, gaps: [(31, 9)])) == nil)
        #expect(probe(clip(seconds: 40, gaps: [(0, 40)])) == nil)
    }

    @Test func aLongWindowIsProbedOverItsLastSeconds() throws {
        let samples = clip(seconds: 40, gaps: [(32, 5)])
        let span = try #require(probe(samples))
        #expect(span.range == (samples.count - 8 * rate)..<samples.count)
        #expect(abs(span.speechSeconds - 3) < 0.2)
    }
}
