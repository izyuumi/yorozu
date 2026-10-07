import XCTest
import Foundation
@testable import ProjectXCore

/// Real database reopen checks; all harness/model traffic is explicitly synthetic.
final class TopicBindingTests: XCTestCase {
    private func seedCompletedTopic(_ root: URL) async throws -> (Topic, Topic, String) {
        let store = try Store(root: root)
        let first = try await store.topic(label: "PROJECTX design")
        let other = try await store.topic(label: "Travel planning")
        let message = try await store.message(role: "user", body: "Initial design work", topic: first.id)
        let initial = work(first, message, state: "working")
        try await store.insertWork(initial)
        try await store.setHandle(initial.id, handle: RunHandle(
            sessionKey: first.sessionKey,
            controllerKey: "agent:coding:projectx-control:\(first.id)",
            runID: "synthetic-initial-run"))
        _ = try await store.complete(task: initial.id, output: WorkerOutput(text: "Initial completed result"))
        return (first, other, initial.id)
    }

    func testCompletedTopicBindingSurvivesReopenAndOtherTopicStaysSeparate() async throws {
        let root = try testRoot()
        let (first, other, oldTask) = try await seedCompletedTopic(root)
        // Reacquire the exclusive workspace lease after the original Store closes.
        let reopened = try Store(root: root)
        let persisted = try await reopened.snapshot()
        XCTAssertEqual(persisted.topics.first { $0.id == first.id }?.sessionKey, first.sessionKey)
        XCTAssertEqual(persisted.topics.first { $0.id == other.id }?.sessionKey, other.sessionKey)
        XCTAssertNotEqual(first.sessionKey, other.sessionKey)
        let harness = ControlledHarness([
            Decision(action: "delegate", topicID: first.id, instruction: "Continue design"),
            Decision(action: "delegate", topicID: other.id, instruction: "Think about travel"),
            Decision(action: "delegate", topicID: first.id, instruction: "Return to design")])
        await harness.release()
        let engine = Engine(store: reopened, memory: try MemoryStore(dataRoot: root), harness: harness)
        for message in ["Continue design", "Travel planning", "Return to design"] {
            try await engine.send(message)
            await engine.waitForIdle()
        }
        let inputs = await harness.captures
        XCTAssertEqual(inputs.map { $0.topic.sessionKey }, [first.sessionKey, other.sessionKey, first.sessionKey])
        XCTAssertEqual(inputs.map { $0.work.sessionReady }, [true, false, true])
        XCTAssertEqual(Set(inputs.map { $0.work.id }).count, 3)
        XCTAssertFalse(inputs.contains { $0.work.id == oldTask })
        let after = try await engine.snapshot()
        XCTAssertEqual(after.topics.count, 2)
        XCTAssertEqual(after.work.count, 4)
    }

    func testFreshAdapterUsesReopenedBindingWithoutCreatingAnotherSubchat() async throws {
        let root = try testRoot()
        let (topic, _, oldTask) = try await seedCompletedTopic(root)
        let reopened = try Store(root: root)
        let persisted = try await reopened.snapshot()
        let message = try await reopened.message(role: "user", body: "Later request", topic: topic.id)
        var next = work(topic, message)
        next.sessionReady = persisted.work.contains { $0.topicID == topic.id && $0.sessionReady }
        XCTAssertNotEqual(next.id, oldTask)
        let input = WorkerInput(policy: "Synthetic only", topic: topic, work: next, current: message, history: [], memory: [])
        let fixture = WireFixture(outputs: ["{\"text\":\"continued\",\"appliedRevision\":0}"])
        let adapter = OpenClawHarness(workspace: root.appendingPathComponent("workspaces"), rpc: GatewayRPC(fixture: { m, p, f in
            try await fixture.call(m, p, f)
        }))
        let log = UpdateLog()
        _ = try await adapter.run(input, update: { await log.append($0) }, memory: { _ in "{}" })
        let methods = await fixture.methods
        let params = await fixture.params
        // A fresh adapter re-ensures the SAME topic session (permission upgrade), never a new sub-chat.
        let creates = try zip(methods, params).filter { $0.0 == "sessions.create" }.map {
            try JSONSerialization.jsonObject(with: Data($0.1.utf8)) as! [String: Any]
        }
        XCTAssertTrue(creates.allSatisfy { [topic.sessionKey, "agent:projectx:projectx-control:\(topic.id)"].contains($0["key"] as? String ?? "") })
        let runs = try zip(methods, params).filter { $0.0 == "agent" }.map {
            try JSONSerialization.jsonObject(with: Data($0.1.utf8)) as! [String: Any]
        }
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?["sessionKey"] as? String, topic.sessionKey)
        let handles = await log.handles
        XCTAssertEqual(handles.first?.sessionKey, topic.sessionKey)
        XCTAssertNotEqual(handles.first?.runID, "synthetic-initial-run")
    }
}
