import Testing

@testable import YorozuShared

@MainActor @Test func newThreadRuntimesSeparateImmediateAndProjectBoundAgents() {
    #expect(NewThreadPicker.assistants == [.yorozu])
    #expect(NewThreadPicker.codingAgents == [.claudeCode, .codex])
}

@MainActor @Test func recentProjectsAppearNewestFirstWithoutReorderingTheRest() {
    let projects = [
        ProjectFolder(path: "/Projects/older", name: "older", lastUsed: 10),
        ProjectFolder(path: "/Projects/first", name: "first"),
        ProjectFolder(path: "/Projects/newer", name: "newer", lastUsed: 20),
        ProjectFolder(path: "/Projects/second", name: "second"),
    ]

    let sections = NewThreadPicker.sections(projects)

    #expect(sections.recent.map(\.name) == ["newer", "older"])
    #expect(sections.other.map(\.name) == ["first", "second"])
}

@MainActor @Test func everyRuntimeExplainsHowItsThreadStarts() {
    for agent in ThreadAgent.allCases {
        #expect(!NewThreadPicker.summary(agent).isEmpty)
    }
    #expect(NewThreadPicker.summary(.yorozu).contains("Starts right away"))
    #expect(NewThreadPicker.summary(.claudeCode).contains("project on your Mac"))
    #expect(NewThreadPicker.summary(.codex).contains("project on your Mac"))
}
