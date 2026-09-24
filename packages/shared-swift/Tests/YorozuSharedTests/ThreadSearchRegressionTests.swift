import Foundation
import Testing

@testable import YorozuShared

@Test func threadSearchUsesTheSameAccentFoldingAsMessageSearch() {
    let thread = ThreadSummary(id: "cafe", title: "Café planning", archived: false, lastActivity: 1)
    #expect(threadMatches(thread, query: "CAFE"))
    let messageOnly = ThreadSummary(id: "message", title: "Planning", archived: false, lastActivity: 1)
    #expect(threadMatches(messageOnly, query: "cafe", body: "Visit the café tomorrow"))
    #expect(searchExcerpt(in: "Visit the café tomorrow", matching: "CAFE")?.contains("café") == true)
}

@Test func blankThreadSearchAvoidsGatheringCachedMessages() {
    let thread = ThreadSummary(id: "t", title: "Planning", archived: false, lastActivity: 1)
    var reads = 0
    func body() -> String { reads += 1; return "cached message" }
    let matches = threadMatches(thread, query: " \n\t", body: body())
    #expect(matches)
    #expect(reads == 0)
    #expect(searchExcerpt(in: "cached message", matching: " \n\t") == nil)
}

@Test func threadSearchIncludesAgentAndRepositoryMatchesWithoutMessageText() {
    let agent = ThreadSummary(id: "agent", title: "Debugging", archived: false, lastActivity: 1, agent: .claudeCode)
    let repo = ThreadSummary(id: "repo", title: "Build changes", archived: false, lastActivity: 2, agent: .codex, cwd: "/projects/café")
    let agentResults = ThreadSearchResults(threads: [agent, repo], query: "claude", messageText: { _ in "" })
    #expect(agentResults.threads.map(\.id) == ["agent"])
    #expect(agentResults.messages.isEmpty)
    #expect(!agentResults.isEmpty)
    let repoResults = ThreadSearchResults(threads: [agent, repo], query: "cafe", messageText: { _ in "" })
    #expect(repoResults.threads.map(\.id) == ["repo"])
    #expect(!repoResults.isEmpty)
}

@Test func threadSearchPartitionsEachMatchOnceAndKeepsArchivedMatchesVisible() {
    let metadata = ThreadSummary(id: "metadata", title: "Coffee plans", archived: false, lastActivity: 1)
    let archived = ThreadSummary(id: "archive", title: "Coffee archive", archived: true, lastActivity: 3)
    let message = ThreadSummary(id: "message", title: "Errands", archived: true, lastActivity: 2)
    let results = ThreadSearchResults(threads: [metadata, message, archived], query: "coffee", messageText: { _ in "Buy coffee" })
    #expect(results.threads.map(\.id) == ["archive", "metadata"])
    #expect(results.messages.map(\.id) == ["message"])
    #expect(!results.isEmpty)
}

@Test func threadSearchHasAnUnambiguousEmptyStateAndSkipsWorkForBlankInput() {
    let thread = ThreadSummary(id: "thread", title: "Planning", archived: false, lastActivity: 1)
    var reads = 0
    let blank = ThreadSearchResults(threads: [thread], query: " \n\t") { _ in reads += 1; return "body" }
    #expect(blank.isEmpty)
    #expect(reads == 0)
    let absent = ThreadSearchResults(threads: [thread], query: "missing", messageText: { _ in "body" })
    #expect(absent.isEmpty)
}

@Test func openingASearchResultCarriesTheExactThreadAndTrimmedSearchIntent() {
    let first = ThreadSearchRequest(threadId: "archive-thread", query: " \nCafé\t")
    let repeated = ThreadSearchRequest(threadId: "archive-thread", query: "Café")
    #expect(first.threadId == "archive-thread")
    #expect(first.query == "Café")
    #expect(first.id != repeated.id)
    let message = YorozuEvent(id: "matching-message", threadId: first.threadId, ts: 0, agentId: "host",
        payload: .message(MessageData(role: .agent, text: "Meet at the cafe")))
    #expect(searchHits(in: [message], term: first.query).first?.eventId == "matching-message")
}
