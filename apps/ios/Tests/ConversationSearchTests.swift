import Testing

@Suite struct ConversationSearchTests {
    private func conversation(_ id: String, title: String? = nil, archived: Bool = false,
                              _ messages: [(ChatItem.Kind, String, Int64)]) -> Conversation {
        let items = messages.enumerated().map { index, message in
            ChatItem(id: "\(id)-\(index)", kind: message.0, text: message.1, ts: message.2)
        }
        return Conversation(id: id, createdAt: 0, updatedAt: messages.map(\.2).max() ?? 0, items: items, title: title,
            archived: archived ? true : nil)
    }

    private func matches(_ query: String, _ text: String) -> Bool { ConversationSearch(query).matches(text) }

    @Test func findsASingleWord() {
        #expect(matches("garden", "Water the garden at six"))
        #expect(!matches("garden", "Water the plants at six"))
    }

    @Test func ignoresCase() {
        #expect(matches("GARDEN", "the garden"))
        #expect(matches("garden", "The Garden"))
    }

    @Test func ignoresDiacritics() {
        #expect(matches("cafe", "Meet at the café"))
        #expect(matches("café", "Meet at the cafe"))
    }

    @Test func ignoresWidth() {
        #expect(matches("ＡＢＣ", "abc"))
        #expect(matches("abc", "ＡＢＣ"))
        #expect(matches("ｶﾀｶﾅ", "カタカナで書く"))
    }

    @Test func findsJapaneseInsideASentence() {
        #expect(matches("予定", "明日の予定を確認して"))
    }

    @Test func requiresEveryWord() {
        #expect(matches("lunch tomorrow", "Tomorrow we could have lunch"))
        #expect(!matches("lunch dinner", "Tomorrow we could have lunch"))
    }

    @Test func aQuotedPhraseNeedsTheWordsTogether() {
        #expect(matches("\"lunch tomorrow\"", "Shall we have lunch tomorrow?"))
        #expect(!matches("\"lunch tomorrow\"", "Tomorrow we could have lunch"))
        #expect(matches("“lunch tomorrow”", "lunch tomorrow"))
    }

    @Test func parsesTerms() {
        #expect(ConversationSearch("  a \"b c\"  d ").terms == ["a", "b c", "d"])
        #expect(ConversationSearch("「明日 の」予定").terms == ["明日 の", "予定"])
        #expect(ConversationSearch("明日\u{3000}予定").terms == ["明日", "予定"])
        #expect(ConversationSearch("\"\" 「」").terms.isEmpty)
    }

    @Test func aJapaneseBracketPhraseNeedsTheWordsTogether() {
        #expect(matches("「明日の予定」", "明日の予定を確認して"))
        #expect(!matches("「予定の明日」", "明日の予定を確認して"))
    }

    @Test func splitsOnTheIdeographicSpace() {
        #expect(matches("確認\u{3000}明日", "明日の予定を確認して"))
        #expect(!matches("確認\u{3000}来週", "明日の予定を確認して"))
    }

    @Test func emptyQueriesFindNothing() {
        let conversations = [conversation("a", [(.user, "anything", 1)])]
        #expect(ConversationSearch("").run(conversations).groups.isEmpty)
        #expect(ConversationSearch(" \u{3000}\n").run(conversations).groups.isEmpty)
        #expect(!matches("  ", "anything"))
    }

    @Test func matchesTheTextWithoutMarkdown() {
        let result = ConversationSearch("bold text").run([conversation("a", [(.agent, "Some **bold** text here", 1)])])
        #expect(result.groups.count == 1)
        #expect(ConversationSearch("\"bold text\"").matches(ConversationSearch.plain("Some **bold** text")))
        #expect(result.groups.first?.hits.first?.snippet == "Some bold text here")
    }

    @Test func userMessagesMatchAsTypedAndAgentMessagesAsShown() {
        let user = ConversationSearch("example.com").run([conversation("a", title: "Links", [(.user, "See [docs](https://example.com)", 1)])])
        let agent = ConversationSearch("example.com").run([conversation("b", title: "Links", [(.agent, "See [docs](https://example.com)", 1)])])
        #expect(user.groups.first?.hits.first?.snippet == "See [docs](https://example.com)")
        #expect(agent.groups.isEmpty)
    }

    @Test func matchesAnyNeedsOneWord() {
        #expect(ConversationSearch("garden hose").matchesAny("the hose is short"))
        #expect(!ConversationSearch("garden hose").matchesAny("the tap is short"))
    }

    @Test func theRevisionChangesOnlyWithSearchableContent() {
        let base = conversation("a", [(.user, "Water the garden", 1)])
        var read = base
        read.readPending = true
        var longer = base
        longer.items.append(ChatItem(id: "a-new", kind: .agent, text: "Done", ts: 2))
        var streamed = base
        streamed.items[0].text += " today"
        #expect(ConversationSearch.revision([base]) == ConversationSearch.revision([read]))
        #expect(ConversationSearch.revision([base]) != ConversationSearch.revision([longer]))
        #expect(ConversationSearch.revision([base]) != ConversationSearch.revision([streamed]))
    }

    @Test func searchesOnlyUserAndAgentMessages() {
        let result = ConversationSearch("failed").run([conversation("a", title: "Notes", [(.error, "It failed", 1)])])
        #expect(result.groups.isEmpty)
    }

    @Test func aTitleOnlyMatchHasNoMessage() {
        let result = ConversationSearch("kyoto").run([conversation("a", title: "A weekend in Kyoto", [(.user, "Plan a trip", 5)])])
        let hit = result.groups.first?.hits.first
        #expect(result.groups.first?.hits.count == 1)
        #expect(hit?.messageId == nil)
        #expect(hit?.convId == "a")
        #expect(hit?.ts == 5)
    }

    @Test func flagsArchivedConversations() {
        let result = ConversationSearch("seeds").run([
            conversation("a", archived: true, [(.user, "Order seeds", 1)]),
            conversation("b", [(.user, "More seeds", 2)]),
        ])
        #expect(result.groups.map(\.convId) == ["b", "a"])
        #expect(result.groups.map(\.archived) == [false, true])
        #expect(result.groups.last?.hits.first?.archived == true)
    }

    @Test func ordersByNewestHitAndGroupsByConversation() {
        let result = ConversationSearch("rain").run([
            conversation("old", [(.user, "rain one", 10), (.agent, "rain two", 40), (.user, "sunny", 90)]),
            conversation("new", [(.user, "rain three", 20), (.agent, "rain four", 50)]),
        ])
        #expect(result.groups.map(\.convId) == ["new", "old"])
        #expect(result.groups.map { $0.hits.map(\.ts) } == [[50, 20], [40, 10]])
        #expect(result.groups[0].hits.map(\.messageId) == ["new-1", "new-0"])
        #expect(!result.truncated)
    }

    @Test func capsHitsAndSaysSo() {
        let many = (0..<30).map { (ChatItem.Kind.user, "tick \($0)", Int64($0)) }
        let perConversation = ConversationSearch("tick").run([conversation("a", many)], perConversation: 20)
        #expect(perConversation.groups[0].hits.count == 20)
        #expect(perConversation.groups[0].hits.first?.ts == 29)
        #expect(perConversation.truncated)

        let total = ConversationSearch("tick").run([conversation("a", many), conversation("b", many.map { ($0.0, $0.1, $0.2 + 100) })],
            limit: 25, perConversation: 20)
        #expect(total.groups.map(\.convId) == ["b", "a"])
        #expect(total.groups.map(\.hits.count) == [20, 5])
        #expect(total.truncated)

        let exact = ConversationSearch("tick").run([conversation("a", Array(many.prefix(3)))], limit: 3)
        #expect(exact.groups[0].hits.count == 3)
        #expect(!exact.truncated)
    }

    @Test func theSnippetShowsTheMatchWithHighlights() {
        let text = "This is a fairly long opening sentence that rambles on.\nThen the Garden plan comes, and the garden needs water."
        let search = ConversationSearch("garden water")
        let (snippet, highlights) = search.snippet(text)
        #expect(snippet.hasPrefix("…"))
        #expect(!snippet.contains("\n"))
        #expect(snippet.contains("Garden plan"))
        #expect(highlights.map { String(snippet[$0]) } == ["Garden", "garden", "water"])
    }

    @Test func theContextBeforeAMatchFitsTheSameWidthInEnglishAndJapanese() {
        let english = ConversationSearch("water").snippet(String(repeating: "x", count: 100) + "water")
        let japanese = ConversationSearch("水").snippet(String(repeating: "あ", count: 100) + "水")
        #expect(english.0 == "…" + String(repeating: "x", count: ConversationSearch.context) + "water")
        #expect(japanese.0 == "…" + String(repeating: "あ", count: ConversationSearch.context / 2) + "水")
    }

    @Test func aShortTextIsNotCut() {
        let (snippet, highlights) = ConversationSearch("予定").snippet("明日の予定を\n確認して")
        #expect(snippet == "明日の予定を 確認して")
        #expect(highlights.map { String(snippet[$0]) } == ["予定"])
    }

    @Test func aLongJapaneseTextIsCutWithoutSpaces() {
        let text = String(repeating: "あ", count: 100) + "予定" + String(repeating: "い", count: 300)
        let (snippet, highlights) = ConversationSearch("予定").snippet(text)
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.hasSuffix("…"))
        #expect(snippet.count == ConversationSearch.length + 2)
        #expect(highlights.map { snippet.distance(from: snippet.startIndex, to: $0.lowerBound) } == [ConversationSearch.context / 2 + 1])
    }
}
