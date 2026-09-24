import Foundation
import Testing
@testable import YorozuShared

private func presentationThread(agent: ThreadAgent? = nil, cwd: String? = nil) -> ThreadSummary {
    ThreadSummary(id: "presentation", title: "", archived: false, lastActivity: 0, agent: agent, cwd: cwd)
}

@Test func threadPresentationUsesCompatibleAgentFallbackAfterDecoding() throws {
    for agentField in ["", ",\"agent\":\"future-agent\""] {
        let wire = "{\"id\":\"legacy\",\"title\":\"\",\"archived\":false,\"lastActivity\":0,\"cwd\":\"/Projects/old\"\(agentField)}"
        let thread = try JSONDecoder().decode(ThreadSummary.self, from: Data(wire.utf8))
        let presentation = ThreadPresentation(thread: thread)
        #expect(presentation.agent == .yorozu)
        #expect(presentation.projectPath == nil)
        #expect(presentation.projectName == nil)
    }
}

@Test func threadPresentationDistinguishesSameNamedCodingProjects() {
    for agent in [ThreadAgent.claudeCode, .codex] {
        let first = ThreadPresentation(thread: presentationThread(agent: agent, cwd: "/Work/client/app"))
        let second = ThreadPresentation(thread: presentationThread(agent: agent, cwd: "/Personal/app"))
        #expect(first.agent == agent)
        #expect(second.agent == agent)
        #expect(first.projectName == second.projectName)
        #expect(first.projectName == "app")
        #expect(first.projectPath == "/Work/client/app")
        #expect(second.projectPath == "/Personal/app")
        #expect(first.projectPath != second.projectPath)
    }
}

@Test func threadPresentationRejectsAbsentProjectsWithoutRewritingValidPaths() {
    for agent in [ThreadAgent.claudeCode, .codex] {
        for cwd in [nil, "", " \n\t"] as [String?] {
            let presentation = ThreadPresentation(thread: presentationThread(agent: agent, cwd: cwd))
            #expect(presentation.projectPath == nil)
            #expect(presentation.projectName == nil)
        }
        let unusual = "/Projects/資料 and notes "
        let presentation = ThreadPresentation(thread: presentationThread(agent: agent, cwd: unusual))
        #expect(presentation.projectPath == unusual)
        #expect(presentation.projectName == "資料 and notes ")
    }
    let assistant = ThreadPresentation(thread: presentationThread(agent: .yorozu, cwd: "/Projects/unrelated"))
    #expect(assistant.projectPath == nil)
    #expect(assistant.projectName == nil)
}

@Test func threadPresentationKeepsAgentIdentityConsistentAcrossEntryPoints() {
    let assistant = ThreadPresentation(thread: presentationThread())
    for agent in [ThreadAgent.claudeCode, .codex] {
        let coding = ThreadPresentation(thread: presentationThread(agent: agent, cwd: "/Projects/app"))
        #expect(coding.composerPlaceholder.contains(agent.label))
        #expect(coding.emptyTitle.contains(agent.label))
        #expect(coding.composerPlaceholder != assistant.composerPlaceholder)
        #expect(coding.emptyTitle != assistant.emptyTitle)
        #expect(coding.emptyMessage != assistant.emptyMessage)
    }
}
