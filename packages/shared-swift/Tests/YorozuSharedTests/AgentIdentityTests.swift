import Testing
@testable import YorozuShared

@Test func codingAgentsUseProviderMarksInsteadOfHomemadeGlyphs() {
    #expect(ThreadAgent.yorozu.mark == .yorozu)
    #expect(ThreadAgent.claudeCode.mark == .claude)
    #expect(ThreadAgent.codex.mark == .openAI)
}

@Test func settingsAttributionNamesBothMarkOwnersAndRejectsEndorsement() {
    let notice = ProviderMarkAttribution.notice
    #expect(notice.contains("Anthropic"))
    #expect(notice.contains("OpenAI"))
    #expect(notice.contains("Codex"))
    #expect(notice.contains("not affiliated with or endorsed"))
}
