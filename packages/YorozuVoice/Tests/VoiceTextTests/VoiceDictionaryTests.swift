import Foundation
import Testing
@testable import VoiceText

struct VoiceDictionaryTests {
    private func dictionary(_ pairs: [(String, String)]) -> VoiceDictionary {
        VoiceDictionary(entries: pairs.map { VoiceDictionary.Entry(term: $0.0, heardAs: $0.1) })
    }

    @Test func replacesWholeWordsOnly() {
        let words = dictionary([("Yorozu", "yo rozu"), ("Kai", "kye")])
        #expect(words.apply(to: "open yo rozu and ask kye") == "open Yorozu and ask Kai")
        #expect(words.apply(to: "kyes and skye stay") == "kyes and skye stay")
        #expect(words.apply(to: "kye, kye. (kye)") == "Kai, Kai. (Kai)")
    }

    @Test func ignoresCaseAndWidthWhenMatching() {
        let words = dictionary([("OpenClaw", "open claw")])
        #expect(words.apply(to: "Open Claw runs") == "OpenClaw runs")
        #expect(words.apply(to: "ＯＰＥＮ ＣＬＡＷ") == "OpenClaw")
    }

    @Test func aTermAloneFixesItsCasing() {
        let words = dictionary([("iPhone", ""), ("TestFlight", "")])
        #expect(words.apply(to: "my Iphone has testflight") == "my iPhone has TestFlight")
    }

    @Test func aLowercaseTermTakesASentenceCapital() {
        let words = dictionary([("pnpm", "p n p m")])
        #expect(words.apply(to: "P n p m is fast, run p n p m") == "Pnpm is fast, run pnpm")
    }

    @Test func japaneseMatchesInsideRunningText() {
        let words = dictionary([("万事屋", "よろず屋"), ("泉", "和泉")])
        #expect(words.apply(to: "よろず屋で和泉さんに会う") == "万事屋で泉さんに会う")
        #expect(words.apply(to: "ヨロズ") == "ヨロズ")
    }

    @Test func halfwidthKatakanaMatchesFullwidth() {
        let words = dictionary([("ヨロズ", "ﾖﾛｽﾞ")])
        #expect(words.apply(to: "ﾖﾛｽﾞを開く") == "ヨロズを開く")
    }

    @Test func latinTermNextToJapaneseNeedsNoSpace() {
        let words = dictionary([("Yorozu", "yorozu")])
        #expect(words.apply(to: "yorozuを開いて") == "Yorozuを開いて")
        #expect(words.apply(to: "yorozus") == "yorozus")
    }

    @Test func longestMatchWinsAndReplacementsAreNotRescanned() {
        let words = dictionary([("New York", "new york"), ("Newark", "new"), ("York", "new york city")])
        #expect(words.apply(to: "new york city") == "York")
        #expect(words.apply(to: "new york") == "New York")
        let chain = dictionary([("b", "a"), ("c", "b")])
        #expect(chain.apply(to: "a b") == "b c")
    }

    @Test func diacriticsStayDistinct() {
        let words = dictionary([("Café", "cafe")])
        #expect(words.apply(to: "café cafe") == "café Café")
    }

    @Test func entriesAreCleanedAndCapped() {
        var words = VoiceDictionary()
        let saved1 = words.save(.init(term: "  \n "))
        #expect(!saved1)
        let saved2 = words.save(.init(term: " Yorozu\nApp ", heardAs: "yorozu app"))
        #expect(saved2)
        #expect(words.entries == [VoiceDictionary.Entry(id: words.entries[0].id, term: "Yorozu App", heardAs: "")])
        let saved3 = words.save(.init(term: String(repeating: "x", count: 100)))
        #expect(saved3)
        #expect(words.entries[1].term.count == VoiceDictionary.maxLength)
        for index in words.entries.count..<VoiceDictionary.maxEntries { words.save(.init(term: "term \(index)")) }
        #expect(words.isFull)
        let saved4 = words.save(.init(term: "one more"))
        #expect(!saved4)
        var edited = words.entries[0]
        edited.term = "Yorozu"
        let saved5 = words.save(edited)
        #expect(saved5)
        #expect(words.entries[0].term == "Yorozu")
        words.remove(edited.id)
        #expect(words.entries.count == VoiceDictionary.maxEntries - 1)
    }

    @Test func hintsAreDistinctTerms() {
        let words = dictionary([("Yorozu", "yo rozu"), ("yorozu", ""), ("万事屋", "よろず屋")])
        #expect(words.hints == ["Yorozu", "万事屋"])
    }

    @Test func roundTripsThroughJSON() throws {
        let words = dictionary([("Yorozu", "yo rozu")])
        let decoded = try JSONDecoder().decode(VoiceDictionary.self, from: JSONEncoder().encode(words))
        #expect(decoded == words)
    }
}
