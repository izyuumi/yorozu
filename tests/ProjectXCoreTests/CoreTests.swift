import XCTest
import Foundation
import GRDB
@testable import ProjectXCore

func testRoot(_ name: String = UUID().uuidString) throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/test-data/" + name)
    try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
    return root
}
func work(_ topic: Topic,_ message: Message,state: String = "queued") -> Work {
    Work(id: identifier(),topicID: topic.id,messageID: message.id,instruction: message.body,state: state,revision: 0,runID: nil,controllerKey: nil,sessionReady: false,suppressed: false,result: nil,error: nil,outputRevision: nil,created: Date().timeIntervalSince1970)
}
func eventually(_ condition: @escaping () async throws -> Bool) async throws {
    for _ in 0..<250 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
    XCTFail("Timed out waiting for fixture condition")
}

actor ControlledHarness: Harness {
    nonisolated let name = "TEST DOUBLE"
    var decisions: [Decision]; var calls = 0; var captures: [WorkerInput] = []
    var released = false; var failure = false; var status: RunStatus = .unknown
    var steerAccepted = true; var cancelAccepted = true; var applied = 0; var echo = true
    var proposals: [MemoryProposal] = []
    var retain = false
    var answer = "Synthetic completed answer"
    init(_ decisions: [Decision]) { self.decisions = decisions }
    func route(_ input: RoutingInput,stronger: Bool) async throws -> Decision { calls += 1; guard !decisions.isEmpty else { throw ProjectError.invalid("No fixture decision.") }; return decisions.removeFirst() }
    func enableRetention() { retain = true; answer = "Orchid planning is an unverified generated proposal." }
    func append(_ decision: Decision) { decisions.append(decision) }
    func release(fail: Bool = false) { released = true; failure = fail }
    func setStatus(_ value: RunStatus) { status = value }
    func setCancel(_ value: Bool) { cancelAccepted = value }
    func setSteer(_ value: Bool) { steerAccepted = value }
    func setEcho(_ value: Bool) { echo = value }
    func run(_ input: WorkerInput,update: @escaping @Sendable (StreamUpdate) async throws -> Void,memory: @escaping @Sendable (MemoryCall) async throws -> String) async throws -> WorkerOutput {
        captures.append(input)
        try await update(.handle(RunHandle(sessionKey: input.topic.sessionKey,controllerKey: "test-control",runID: "test-run-" + input.work.id)))
        try await update(.event(WorkerEvent(id: input.work.id + "-event",taskID: input.work.id,kind: "progress",body: "Synthetic public progress",created: Date().timeIntervalSince1970)))
        while !released { try await Task.sleep(for: .milliseconds(10)) }
        if failure { throw ProjectError.uncertain("Synthetic connection loss") }
        return WorkerOutput(text: retain ? answer : "Answer for: " + input.work.instruction,appliedRevision: applied)
    }
    func steer(_ work: Work,topic: Topic,amendment: Amendment) async throws -> Bool { if steerAccepted && echo { applied = amendment.revision }; return steerAccepted }
    func cancel(_ work: Work,topic: Topic) async throws -> Bool { cancelAccepted }
    func reconcile(_ work: Work,topic: Topic) async throws -> RunStatus { status }
    func extract(_ message: Message,existing: [MemoryHit]) async throws -> [MemoryProposal] {
        if retain, message.body.lowercased().contains("orchid") {
            return [MemoryProposal(sourceID: message.id,quote: message.body,title: "Orchid knowledge",body: message.body,knowledgeType: message.role == "assistant" ? "generated_analysis" : "source_claim",attribution: message.role == "assistant" ? "assistant" : "quoted_source",epistemicStatus: "unverified")]
        }
        return proposals.filter { $0.sourceID == message.id }
    }
}

final class StoreTests: XCTestCase {
    func testDurableTopicIdentityAndExclusiveLease() async throws {
        let root = try testRoot(); let store = try Store(root: root)
        let topic = try await store.topic(label: "PROJECTX")
        XCTAssertThrowsError(try Store(root: root))
        let read = try Store(root: root,exclusive: false)
        let saved = try await read.snapshot()
        XCTAssertEqual(saved.topics.first?.sessionKey,topic.sessionKey)
        XCTAssertTrue(topic.sessionKey.contains("projectx:"))
    }
    func testCompletionAmendmentRaceAndDeduplication() async throws {
        let store = try Store(root: testRoot()); let topic = try await store.topic(label: "Design")
        let m = try await store.message(role: "user",body: "red",topic: topic.id)
        let w = work(topic,m,state: "working"); try await store.insertWork(w)
        let change = try await store.message(role: "user",body: "blue",topic: topic.id)
        let a = try await store.amend(task: w.id,message: change.id,instruction: "blue")
        let first = try await store.complete(task: w.id,output: WorkerOutput(text: "blue result",appliedRevision: 1))
        XCTAssertNil(first)
        try await store.amendmentState(id: a.id,state: "accepted")
        let second = try await store.complete(task: w.id,output: WorkerOutput(text: "blue result",appliedRevision: 1)); XCTAssertNotNil(second)
        let duplicate = try await store.complete(task: w.id,output: WorkerOutput(text: "blue result",appliedRevision: 1)); XCTAssertNil(duplicate)
        let state = try await store.snapshot(); XCTAssertEqual(state.work[0].state,"done"); XCTAssertEqual(state.amendments[0].state,"applied")
    }
    func testRestartUncertainNoReplay() async throws {
        let root = try testRoot(); let store = try Store(root: root,exclusive: false)
        let topic = try await store.topic(label: "Topic"); let m = try await store.message(role: "user",body: "work",topic: topic.id)
        var running = work(topic,m,state: "working"); running.runID = "dispatched-run"; try await store.insertWork(running)
        let reopened = try Store(root: root,exclusive: false); let snapshot = try await reopened.snapshot()
        XCTAssertEqual(snapshot.work[0].state,"uncertain") // dispatched: never replayed; Engine.resume() re-attaches
        let harness = ControlledHarness([]); await harness.setStatus(.stopped)
        let engine = Engine(store: reopened,memory: try MemoryStore(dataRoot: root),harness: harness); await engine.resume()
        try await eventually { try await reopened.snapshot().messages.contains { $0.kind == "failure" } }
        let captures = await harness.captures; XCTAssertTrue(captures.isEmpty)
    }
    func testResumeDeliversRunThatFinishedDuringRestart() async throws {
        let root = try testRoot(); let store = try Store(root: root,exclusive: false)
        let topic = try await store.topic(label: "Topic"); let m = try await store.message(role: "user",body: "work",topic: topic.id)
        var running = work(topic,m,state: "working"); running.runID = "dispatched-run"; try await store.insertWork(running)
        let reopened = try Store(root: root,exclusive: false)
        let harness = ControlledHarness([]); await harness.setStatus(.completed(WorkerOutput(text: "Finished meanwhile")))
        let engine = Engine(store: reopened,memory: try MemoryStore(dataRoot: root),harness: harness); await engine.resume()
        try await eventually { try await reopened.snapshot().messages.contains { $0.kind == "result" && $0.body.contains("Finished meanwhile") } }
        let captures = await harness.captures; XCTAssertTrue(captures.isEmpty)
    }
    func testOneActiveTaskPerTopicAndSuppressedCompletion() async throws {
        let store = try Store(root: testRoot()); let topic = try await store.topic(label: "Topic")
        let m = try await store.message(role: "user",body: "work",topic: topic.id)
        var w = work(topic,m); try await store.insertWork(w)
        do { try await store.insertWork(work(topic,m)); XCTFail("duplicate") } catch { }
        w.suppressed = true; try await store.updateWork(w)
        let result = try await store.complete(task: w.id,output: WorkerOutput(text: "stale")); XCTAssertNil(result)
        let state = try await store.snapshot(); XCTAssertEqual(state.work[0].result,"stale"); XCTAssertEqual(state.messages.count,1)
    }
}

final class MemoryTests: XCTestCase {
    func testMarkdownFTSGlobalSearchCASAndForgetPreservesHistory() async throws {
        let root = try testRoot(); let store = try Store(root: root); let mem = try MemoryStore(dataRoot: root)
        let topic = try await store.topic(label: "Travel"); let msg = try await store.message(role: "user",body: "Useful airport knowledge",topic: topic.id)
        let doc = MemoryDocument(metadata: MemoryMetadata(title: "Airport transfers",topicID: topic.id,sources: [msg.id]),body: "The airport train is a generated planning proposal.")
        let path = "knowledge/" + doc.metadata.id + ".md"
        let result = try await mem.write(path: path,markdown: doc.markdown,expectedSHA256: nil,sources: [msg]); XCTAssertTrue(result.indexed)
        let hits = try await mem.search("airport"); XCTAssertEqual(hits.first?.document.metadata.attribution,"assistant")
        var updated = doc; updated.body = "Airport transport is uncertain."
        let written = try await mem.write(path: path,markdown: updated.markdown,expectedSHA256: result.sha256,sources: [msg])
        do { _ = try await mem.write(path: path,markdown: doc.markdown,expectedSHA256: result.sha256,sources: [msg]); XCTFail("lost update") } catch ProjectError.conflict { }
        let read = try await mem.read(path: path); let current = try MemoryDocument.parse(read.markdown)
        XCTAssertEqual(current.metadata.lineage.count,1)
        try await mem.forget(id: doc.metadata.id,expectedSHA256: written.sha256)
        let count = try await mem.rebuild(); XCTAssertEqual(count,0)
        let history = try await store.snapshot(); XCTAssertEqual(history.messages.first?.body,msg.body)
    }
    func testTraversalSymlinkHardlinkAndHistoryWriteRefused() async throws {
        let root = try testRoot(); let mem = try MemoryStore(dataRoot: root)
        let doc = MemoryDocument(metadata: MemoryMetadata(title: "Safe"),body: "Proposal")
        for path in ["../" + doc.metadata.id + ".md","/tmp/" + doc.metadata.id + ".md","operations.sqlite","x//" + doc.metadata.id + ".md"] {
            do { _ = try await mem.write(path: path,markdown: doc.markdown,expectedSHA256: nil); XCTFail("unsafe path \(path)") } catch { }
        }
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside,withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("memory/link"),withDestinationURL: outside)
        do { _ = try await mem.write(path: "link/" + doc.metadata.id + ".md",markdown: doc.markdown,expectedSHA256: nil); XCTFail("symlink") } catch { }
        try FileManager.default.removeItem(at: root.appendingPathComponent("memory/link"))
        let actual = root.appendingPathComponent("actual"); try Data("not memory".utf8).write(to: actual)
        try FileManager.default.linkItem(at: actual,to: root.appendingPathComponent("memory/" + doc.metadata.id + ".md"))
        do { _ = try await mem.read(path: doc.metadata.id + ".md"); XCTFail("hardlink") } catch { }
        do { _ = try await mem.invoke(MemoryCall(tool: "history.write"),sources: []); XCTFail("history write") } catch { }
    }
    func testAttributionEvidenceAndCredentialExclusion() async throws {
        let root = try testRoot(); let mem = try MemoryStore(dataRoot: root); let store = try Store(root: root)
        let pasted = try await store.message(role: "user",body: "Pasted source says the train is safe.")
        let bad = MemoryDocument(metadata: MemoryMetadata(title: "Belief",sources: [pasted.id],evidence: "the train is safe",knowledgeType: "user_belief",attribution: "user",epistemicStatus: "user_stated"),body: "The train is safe")
        do { _ = try await mem.write(path: bad.metadata.id + ".md",markdown: bad.markdown,expectedSHA256: nil,sources: [pasted]); XCTFail("source became belief") } catch { }
        var safe = bad; safe.metadata.knowledgeType = "source_claim"; safe.metadata.attribution = "quoted_source"; safe.metadata.epistemicStatus = "unverified"
        _ = try await mem.write(path: safe.metadata.id + ".md",markdown: safe.markdown,expectedSHA256: nil,sources: [pasted])
        let secret = MemoryDocument(metadata: MemoryMetadata(title: "Bad"),body: "password=synthetic-disallowed-value")
        do { _ = try await mem.write(path: secret.metadata.id + ".md",markdown: secret.markdown,expectedSHA256: nil); XCTFail("credential") } catch { }
    }
    func testRebuildReadsExternalMarkdownWithoutConversationReplay() async throws {
        let root = try testRoot(); let mem = try MemoryStore(dataRoot: root)
        var doc = MemoryDocument(metadata: MemoryMetadata(title: "External topic-free note"),body: "Orchid proposal")
        let path = doc.metadata.id + ".md"; _ = try await mem.write(path: path,markdown: doc.markdown,expectedSHA256: nil)
        doc.body = "Orchid corrected externally"
        try Data(doc.markdown.utf8).write(to: root.appendingPathComponent("memory/" + path),options: .atomic)
        let count = try await mem.rebuild(); XCTAssertEqual(count,1)
        let hits = try await mem.search("orchid"); XCTAssertEqual(hits.first?.document.body,"Orchid corrected externally")
        XCTAssertNil(hits.first?.document.metadata.topicID)
        let db = try DatabaseQueue(path: root.appendingPathComponent("memory-index.sqlite").path)
        let cols = try await db.read { try String.fetchAll($0,sql: "SELECT name FROM pragma_table_info('discovery')") }
        XCTAssertEqual(cols,["id","title","summary","path"])
    }
}

final class EngineTests: XCTestCase {
    func testNonblockingReplyProgressPlacementAndSameTopicReuse() async throws {
        let root = try testRoot(); let store = try Store(root: root); let mem = try MemoryStore(dataRoot: root)
        let topic = try await store.topic(label: "PROJECTX")
        let harness = ControlledHarness([Decision(action: "delegate",topicID: topic.id,instruction: "Think"),Decision(action: "reply",topicID: topic.id,reply: "Still here")])
        let engine = Engine(store: store,memory: mem,harness: harness)
        try await engine.send("Think"); try await eventually { await harness.captures.count == 1 }
        try await engine.send("hello"); await engine.waitForRouting()
        let during = try await engine.snapshot()
        XCTAssertTrue(during.messages.contains { $0.body == "Still here" }); XCTAssertFalse(during.messages.contains { $0.body == "Synthetic public progress" }); XCTAssertEqual(during.events.count,1)
        await harness.release(); await engine.waitForIdle()
        await harness.append(Decision(action: "delegate",topicID: topic.id,instruction: "More thought"))
        try await engine.send("More thought"); await engine.waitForIdle()
        let captures = await harness.captures
        XCTAssertEqual(captures.count,2); XCTAssertEqual(captures[0].topic.sessionKey,captures[1].topic.sessionKey); XCTAssertTrue(captures[1].work.sessionReady)
        let after = try await engine.snapshot(); XCTAssertEqual(after.topics.count,1); XCTAssertEqual(after.work.count,2)
    }
    func testWrongTopicCorrectionCancelsWithoutHistoryMigration() async throws {
        let root = try testRoot(); let store = try Store(root: root); let mem = try MemoryStore(dataRoot: root)
        let wrong = try await store.topic(label: "Travel"); let right = try await store.topic(label: "PROJECTX")
        let harness = ControlledHarness([Decision(action: "delegate",topicID: wrong.id,instruction: "Mistaken request")]); let engine = Engine(store: store,memory: mem,harness: harness)
        let first = try await engine.send("Plan it"); try await eventually { await harness.captures.count == 1 }
        let initial = try await engine.snapshot(); let task = initial.work[0].id
        await harness.append(Decision(action: "correct",topicID: right.id,taskID: task,instruction: "Intended project"))
        let correction = try await engine.send("I meant PROJECTX"); await engine.waitForRouting(); await harness.release(); await engine.waitForIdle()
        let final = try await engine.snapshot()
        XCTAssertEqual(final.messages.first { $0.id == first }?.topicID,wrong.id)
        XCTAssertEqual(final.messages.first { $0.id == correction }?.topicID,right.id)
        XCTAssertTrue(final.work.first { $0.id == task }!.suppressed)
        XCTAssertFalse(final.messages.contains { $0.taskID == task && $0.kind == "result" })
        XCTAssertEqual(final.work.count,2)
    }
    func testUncertainRetryDoesNotDuplicateUntilReconciled() async throws {
        let root = try testRoot(); let store = try Store(root: root); let mem = try MemoryStore(dataRoot: root); let topic = try await store.topic(label: "Topic")
        let harness = ControlledHarness([Decision(action: "delegate",topicID: topic.id,instruction: "Original")]); let engine = Engine(store: store,memory: mem,harness: harness)
        await harness.release(fail: true); try await engine.send("Original"); await engine.waitForIdle()
        let first = try await engine.snapshot(); let old = first.work[0]
        XCTAssertEqual(old.state,"uncertain")
        await harness.append(Decision(action: "retry",topicID: topic.id,taskID: old.id)); try await engine.send("retry"); await engine.waitForIdle()
        var state = try await engine.snapshot(); XCTAssertEqual(state.work.count,1); XCTAssertTrue(state.messages.contains { $0.body.contains("has NOT started") })
        await harness.setStatus(.stopped); await harness.release(fail: false)
        await harness.append(Decision(action: "retry",topicID: topic.id,taskID: old.id)); try await engine.send("retry"); await engine.waitForIdle()
        state = try await engine.snapshot(); XCTAssertEqual(state.work.count,2)
        let captures = await harness.captures; XCTAssertEqual(captures[0].topic.sessionKey,captures[1].topic.sessionKey)
    }
    func testSteeringSameTaskAndUnadmittedStaleOutput() async throws {
        let root = try testRoot(); let store = try Store(root: root); let mem = try MemoryStore(dataRoot: root); let topic = try await store.topic(label: "Topic")
        let harness = ControlledHarness([Decision(action: "delegate",topicID: topic.id,instruction: "Red")]); let engine = Engine(store: store,memory: mem,harness: harness)
        try await engine.send("Red"); try await eventually { await harness.captures.count == 1 }
        let state = try await engine.snapshot(); await harness.setSteer(false)
        await harness.append(Decision(action: "steer",topicID: topic.id,taskID: state.work[0].id,instruction: "Blue"))
        try await engine.send("Blue"); await engine.waitForRouting(); await harness.release(); await engine.waitForIdle()
        // Unadmitted change: same task answers it in a follow-up turn of the same session, never a second task.
        let final = try await engine.snapshot(); XCTAssertEqual(final.work.count,1); XCTAssertEqual(final.work[0].state,"done"); XCTAssertEqual(final.messages.filter { $0.kind == "result" }.count,1)
        let captures = await harness.captures; XCTAssertEqual(captures.count,2); XCTAssertEqual(captures[1].work.id,captures[0].work.id)
        XCTAssertEqual(captures[1].topic.sessionKey,captures[0].topic.sessionKey); XCTAssertTrue(captures[1].work.instruction.contains("Amendment 1: Blue"))
        XCTAssertTrue(final.messages.first { $0.kind == "result" }!.body.contains("Amendment 1: Blue"))
        XCTAssertEqual(final.events.filter { $0.kind == "superseded_result" }.map(\.body),["Answer for: Red"])
    }
    func testAdmittedSteerTheWorkerDidNotEchoBecomesFollowUp() async throws {
        let root = try testRoot(); let store = try Store(root: root); let mem = try MemoryStore(dataRoot: root); let topic = try await store.topic(label: "Topic")
        let harness = ControlledHarness([Decision(action: "delegate",topicID: topic.id,instruction: "Red")]); let engine = Engine(store: store,memory: mem,harness: harness)
        try await engine.send("Red"); try await eventually { await harness.captures.count == 1 }
        await harness.setEcho(false); let id = try await engine.snapshot().work[0].id
        await harness.append(Decision(action: "steer",topicID: topic.id,taskID: id,instruction: "Blue"))
        try await engine.send("Blue"); await engine.waitForRouting()
        let during = try await engine.snapshot(); XCTAssertEqual(during.amendments.first?.state,"accepted")
        await harness.release(); await engine.waitForIdle()
        let final = try await engine.snapshot(); let captures = await harness.captures
        XCTAssertEqual(captures.count,2); XCTAssertEqual(captures[1].work.id,id); XCTAssertTrue(captures[1].work.instruction.contains("Amendment 1: Blue"))
        XCTAssertEqual(final.work[0].state,"done"); XCTAssertEqual(final.messages.filter { $0.kind == "result" }.count,1)
    }
    func testRetryOfFinishedRunAppliesSavedChangeOnSameTask() async throws {
        let root = try testRoot(); let store = try Store(root: root); let mem = try MemoryStore(dataRoot: root); let topic = try await store.topic(label: "Topic")
        let harness = ControlledHarness([Decision(action: "delegate",topicID: topic.id,instruction: "Red")]); let engine = Engine(store: store,memory: mem,harness: harness)
        try await engine.send("Red"); try await eventually { await harness.captures.count == 1 }
        let id = try await engine.snapshot().work[0].id; await harness.setSteer(false)
        await harness.append(Decision(action: "steer",topicID: topic.id,taskID: id,instruction: "Blue"))
        try await engine.send("Blue"); await engine.waitForRouting()
        // Local call lost, but the Gateway run finished with the pre-change answer.
        await harness.release(fail: true); await engine.waitForIdle()
        let lost = try await engine.snapshot(); XCTAssertEqual(lost.work[0].state,"uncertain")
        await harness.release(); await harness.setStatus(.completed(WorkerOutput(text: "Answer for: Red")))
        await harness.append(Decision(action: "retry",topicID: topic.id,taskID: id)); try await engine.send("retry"); await engine.waitForIdle()
        let final = try await engine.snapshot(); let captures = await harness.captures
        XCTAssertEqual(final.work.count,1); XCTAssertEqual(final.work[0].state,"done"); XCTAssertEqual(captures.count,2); XCTAssertEqual(captures[1].work.id,id)
        XCTAssertTrue(final.messages.first { $0.kind == "result" }!.body.contains("Amendment 1: Blue"))
    }
    func testNeverDispatchedRestartedWorkRunsAgainOnResume() async throws {
        let root = try testRoot(); let store = try Store(root: root,exclusive: false); let topic = try await store.topic(label: "Topic")
        let m = try await store.message(role: "user",body: "Queued",topic: topic.id); let queued = work(topic,m); try await store.insertWork(queued)
        let reopened = try Store(root: root,exclusive: false); let restarted = try await reopened.work(queued.id); XCTAssertEqual(restarted.state,"queued")
        let harness = ControlledHarness([]); await harness.release()
        let engine = Engine(store: reopened,memory: try MemoryStore(dataRoot: root),harness: harness)
        await engine.resume(); await engine.waitForIdle() // never dispatched, so it simply runs
        let captures = await harness.captures; XCTAssertEqual(captures.count,1); XCTAssertEqual(captures[0].topic.sessionKey,topic.sessionKey)
        let after = try await engine.snapshot(); XCTAssertEqual(after.work.filter { $0.state == "done" }.count,1)
    }
    func testAmbiguityEscalatesOnceThenClarifiesNoWorker() async throws {
        let root = try testRoot(); let store = try Store(root: root); let mem = try MemoryStore(dataRoot: root)
        let h = ControlledHarness([Decision(action: "clarify",reply: "Which subject?"),Decision(action: "clarify",reply: "Travel or PROJECTX?")]); let e = Engine(store: store,memory: mem,harness: h)
        try await e.send("change that"); await e.waitForIdle()
        let calls = await h.calls; let state = try await e.snapshot(); XCTAssertEqual(calls,2); XCTAssertTrue(state.work.isEmpty); XCTAssertEqual(state.messages.last?.body,"Travel or PROJECTX?")
    }
    func testCrossTopicMemoryButNotForeignConversation() async throws {
        let root = try testRoot(); let store = try Store(root: root); let mem = try MemoryStore(dataRoot: root)
        let a = try await store.topic(label: "Travel"); let b = try await store.topic(label: "Planning")
        _ = try await store.message(role: "user",body: "FOREIGN transcript",topic: a.id)
        let doc = MemoryDocument(metadata: MemoryMetadata(title: "Airport planning",topicID: a.id),body: "Airport proposal")
        _ = try await mem.write(path: doc.metadata.id + ".md",markdown: doc.markdown,expectedSHA256: nil)
        let h = ControlledHarness([Decision(action: "delegate",topicID: b.id,instruction: "Airport planning")]); await h.release()
        let e = Engine(store: store,memory: mem,harness: h); try await e.send("Airport planning"); await e.waitForIdle()
        let inputs = await h.captures; XCTAssertEqual(inputs[0].memory.count,1); XCTAssertFalse(inputs[0].history.contains { $0.body == "FOREIGN transcript" })
    }
}

final class AdditionalSafetyTests: XCTestCase {
    func testSuppressionCannotBeOverwrittenByLateHandleOrStart() async throws {
        let s = try Store(root: testRoot()); let t = try await s.topic(label: "Topic"); let m = try await s.message(role: "user",body: "Work",topic: t.id)
        let w = work(t,m); try await s.insertWork(w); _ = try await s.suppress(w.id)
        let started = try await s.startWork(w.id); XCTAssertNil(started)
        do { try await s.setHandle(w.id,handle: RunHandle(sessionKey: t.sessionKey,controllerKey: "c",runID: "r")); XCTFail("suppression overwritten") } catch { }
        let failed = try await s.failWork(w.id,error: "local failure"); XCTAssertNil(failed)
        let after = try await s.work(w.id); XCTAssertTrue(after.suppressed); XCTAssertEqual(after.state,"cancelled")
    }
    func testFixtureAndLiveRuntimeBindingCannotMix() async throws {
        let s = try Store(root: testRoot())
        try await s.bindRuntime("Synthetic fixture · NOT a live model")
        try await s.bindRuntime("Offline · no model calls")
        do { try await s.bindRuntime("Configured OpenClaw · live acceptance unverified"); XCTFail("fixture harness session reused as live") } catch { }
    }
    func testAutomaticQuotedAndGeneratedKnowledgeThenConversationalForgetNoReplay() async throws {
        let root = try testRoot(); let store = try Store(root: root); let mem = try MemoryStore(dataRoot: root); let topic = try await store.topic(label: "Garden")
        let h = ControlledHarness([Decision(action: "delegate",topicID: topic.id,instruction: "Analyze orchid source")]); await h.enableRetention(); await h.release()
        let e = Engine(store: store,memory: mem,harness: h)
        let mid = try await e.send("Pasted source says orchid light requirements vary."); await e.waitForIdle()
        let hits = try await mem.search("orchid"); XCTAssertEqual(hits.count,2)
        XCTAssertTrue(hits.contains { $0.document.metadata.attribution == "quoted_source" })
        XCTAssertTrue(hits.contains { $0.document.metadata.attribution == "assistant" })
        XCTAssertTrue(hits.allSatisfy { $0.document.metadata.epistemicStatus == "unverified" })
        let processed = try await store.memoryProcessed(mid); XCTAssertTrue(processed)
        let before = try await store.snapshot().messages
        await h.append(Decision(action: "forget",topicID: topic.id,memoryID: hits[0].id))
        try await e.send("Forget that orchid memory"); await e.waitForIdle()
        let count = try await mem.rebuild(); XCTAssertEqual(count,1)
        let after = try await store.snapshot().messages
        for original in before { XCTAssertEqual(after.first { $0.id == original.id }?.body,original.body) }
        // A fresh engine does not import/replay/extract past chat on startup.
        let reopened = Engine(store: store,memory: mem,harness: h); await reopened.waitForIdle()
        let still = try await mem.rebuild(); XCTAssertEqual(still,1)
    }
    func testTwoWorkerLanesAndQueuedThirdTopicWithoutBlockingSecretary() async throws {
        let root = try testRoot(); let s = try Store(root: root); let mem = try MemoryStore(dataRoot: root)
        let a = try await s.topic(label: "A"); let b = try await s.topic(label: "B"); let c = try await s.topic(label: "C")
        let h = ControlledHarness([Decision(action: "delegate",topicID: a.id,instruction: "A"),Decision(action: "delegate",topicID: b.id,instruction: "B"),Decision(action: "delegate",topicID: c.id,instruction: "C"),Decision(action: "reply",topicID: c.id,reply: "Secretary available")])
        let e = Engine(store: s,memory: mem,harness: h)
        try await e.send("A"); try await e.send("B"); try await e.send("C"); try await e.send("hello"); await e.waitForRouting()
        try await eventually { await h.captures.count == 2 }
        let during = try await e.snapshot(); XCTAssertEqual(during.work.filter { $0.state == "queued" }.count,1); XCTAssertTrue(during.messages.contains { $0.body == "Secretary available" })
        await h.release(); await e.waitForIdle(); let count = await h.captures.count; XCTAssertEqual(count,3)
    }
    func testUnacknowledgedCancellationIsNotClaimedConfirmed() async throws {
        let root = try testRoot(); let s = try Store(root: root); let mem = try MemoryStore(dataRoot: root)
        let a = try await s.topic(label: "A"); let b = try await s.topic(label: "B")
        let h = ControlledHarness([Decision(action: "delegate",topicID: a.id,instruction: "A")]); await h.setCancel(false)
        let e = Engine(store: s,memory: mem,harness: h); try await e.send("A"); try await eventually { await h.captures.count == 1 }
        let old = try await e.snapshot().work[0]
        await h.append(Decision(action: "correct",topicID: b.id,taskID: old.id,instruction: "B")); try await e.send("I meant B"); await e.waitForRouting()
        let during = try await e.snapshot(); XCTAssertEqual(during.work.first { $0.id == old.id }?.state,"cancellation_requested"); XCTAssertTrue(during.messages.contains { $0.body.contains("not confirmed") })
        await h.release(); await e.waitForIdle()
        let final = try await e.snapshot(); XCTAssertFalse(final.messages.contains { $0.taskID == old.id && $0.kind == "result" })
    }
    func testStopOfLocallyRunningStepIsNotClaimedUntilItEnds() async throws {
        let root = try testRoot(); let s = try Store(root: root); let mem = try MemoryStore(dataRoot: root)
        let a = try await s.topic(label: "A"); let b = try await s.topic(label: "B")
        let h = ControlledHarness([Decision(action: "delegate",topicID: a.id,instruction: "A")]) // cancel() reports nothing active
        let e = Engine(store: s,memory: mem,harness: h); try await e.send("A"); try await eventually { await h.captures.count == 1 }
        let old = try await e.snapshot().work[0]
        await h.append(Decision(action: "correct",topicID: b.id,taskID: old.id,instruction: "B")); try await e.send("I meant B"); await e.waitForRouting()
        let during = try await e.snapshot(); XCTAssertEqual(during.work.first { $0.id == old.id }?.state,"cancellation_requested"); XCTAssertTrue(during.messages.contains { $0.body.contains("not confirmed") })
        await h.release(fail: true); await e.waitForIdle()
        let settled = try await e.snapshot(); XCTAssertEqual(settled.work.first { $0.id == old.id }?.state,"cancelled")
        let m = try await s.message(role: "user",body: "New A work",topic: a.id); try await s.insertWork(work(a,m)) // topic A is free again
    }
    func testOfflineNeverInventsModelOutput() async throws {
        let root = try testRoot(); let e = Engine(store: try Store(root: root),memory: try MemoryStore(dataRoot: root),harness: OfflineHarness())
        try await e.send("Think about this"); await e.waitForIdle(); let snapshot = try await e.snapshot()
        XCTAssertTrue(snapshot.work.isEmpty); XCTAssertEqual(snapshot.messages.count,2); XCTAssertTrue(snapshot.messages.last!.body.contains("no model was called"))
    }
}

final class QueuedSteeringTests: XCTestCase {
    func testQueuedAmendmentStartsSameTaskWithLatestInput() async throws {
        let s = try Store(root: testRoot()); let t = try await s.topic(label: "Topic")
        let m = try await s.message(role: "user",body: "Original",topic: t.id); let w = work(t,m); try await s.insertWork(w)
        let change = try await s.message(role: "user",body: "Blue",topic: t.id)
        let a = try await s.amend(task: w.id,message: change.id,instruction: "Blue")
        XCTAssertEqual(a.state,"queued_input")
        let started = try await s.startWork(w.id); XCTAssertEqual(started?.id,w.id); XCTAssertEqual(started?.revision,1); XCTAssertTrue(started!.instruction.contains("Blue"))
        let output = try await s.complete(task: w.id,output: WorkerOutput(text: "Blue answer",appliedRevision: 1)); XCTAssertNotNil(output)
        let all = try await s.snapshot(); XCTAssertEqual(all.work.count,1); XCTAssertEqual(all.amendments[0].state,"applied")
    }
}

final class CorrectionContinuationTests: XCTestCase {
    func testCorrectionSteersAlreadyWorkingIntendedTaskWithoutExtraTurn() async throws {
        let root = try testRoot(); let s = try Store(root: root); let mem = try MemoryStore(dataRoot: root)
        let wrong = try await s.topic(label: "Wrong"); let intended = try await s.topic(label: "Intended")
        let h = ControlledHarness([Decision(action: "delegate",topicID: wrong.id,instruction: "Mistaken"),Decision(action: "delegate",topicID: intended.id,instruction: "Existing intended work")])
        let e = Engine(store: s,memory: mem,harness: h)
        let original = try await e.send("Mistaken"); let intendedMessage = try await e.send("Existing intended work")
        try await eventually { await h.captures.count == 2 }
        let initial = try await e.snapshot(); let mistakenTask = initial.work.first { $0.topicID == wrong.id }!; let intendedTask = initial.work.first { $0.topicID == intended.id }!
        await h.append(Decision(action: "correct",topicID: intended.id,taskID: mistakenTask.id,instruction: "Corrected intended instruction"))
        let correction = try await e.send("I meant Intended"); await e.waitForRouting()
        let during = try await e.snapshot()
        XCTAssertEqual(during.work.count,2); XCTAssertEqual(during.amendments.count,1)
        XCTAssertEqual(during.amendments[0].taskID,intendedTask.id); XCTAssertEqual(during.amendments[0].state,"accepted")
        XCTAssertEqual(during.work.first { $0.id == intendedTask.id }?.state,"amendment_pending") // admission is not incorporation
        XCTAssertEqual(during.messages.first { $0.id == original }?.topicID,wrong.id)
        XCTAssertEqual(during.messages.first { $0.id == intendedMessage }?.topicID,intended.id)
        XCTAssertEqual(during.messages.first { $0.id == correction }?.topicID,intended.id)
        await h.release(); await e.waitForIdle(); let final = try await e.snapshot()
        XCTAssertEqual(final.work.first { $0.id == intendedTask.id }?.state,"done")
        XCTAssertFalse(final.messages.contains { $0.taskID == mistakenTask.id && $0.kind == "result" })
        let captures = await h.captures; XCTAssertEqual(captures.count,2)
    }
    func testCorrectionToPendingTaskRetainsSameTaskWhenSteeringRefused() async throws {
        let root = try testRoot(); let s = try Store(root: root); let mem = try MemoryStore(dataRoot: root)
        let wrong = try await s.topic(label: "Wrong"); let intended = try await s.topic(label: "Intended")
        let oldMessage = try await s.message(role: "user",body: "Wrong source",topic: wrong.id)
        let wrongTask = work(wrong,oldMessage,state: "done"); try await s.insertWork(wrongTask)
        let h = ControlledHarness([Decision(action: "delegate",topicID: intended.id,instruction: "Original intended")]); let e = Engine(store: s,memory: mem,harness: h)
        try await e.send("Original intended"); try await eventually { await h.captures.count == 1 }
        let target = try await e.snapshot().work.last!; await h.setSteer(false)
        await h.append(Decision(action: "steer",topicID: intended.id,taskID: target.id,instruction: "First change")); try await e.send("First change"); await e.waitForRouting()
        await h.append(Decision(action: "correct",topicID: intended.id,taskID: wrongTask.id,instruction: "Correction")); try await e.send("I meant Intended"); await e.waitForRouting()
        let during = try await e.snapshot(); XCTAssertEqual(during.work.count,2); XCTAssertEqual(during.amendments.count,2)
        XCTAssertTrue(during.amendments.allSatisfy { $0.taskID == target.id && $0.state == "pending" })
        XCTAssertEqual(during.work.last?.state,"amendment_pending"); XCTAssertFalse(during.messages.contains { $0.body.contains("pending reconciliation") })
        await h.release(); await e.waitForIdle(); let after = try await e.snapshot()
        let captures = await h.captures; XCTAssertEqual(captures.last?.work.id,target.id)
        XCTAssertTrue(captures.last!.work.instruction.contains("First change")); XCTAssertTrue(captures.last!.work.instruction.contains("Correction"))
        XCTAssertEqual(after.messages.filter { $0.taskID == target.id && $0.kind == "result" }.count,1)
        XCTAssertTrue(after.messages.first { $0.taskID == target.id && $0.kind == "result" }!.body.contains("Correction"))
    }
    func testCorrectionToUncertainTaskWaitsForReconciliationAndRetryKeepsInstruction() async throws {
        let root = try testRoot(); let s = try Store(root: root); let mem = try MemoryStore(dataRoot: root)
        let wrong = try await s.topic(label: "Wrong"); let intended = try await s.topic(label: "Intended")
        let oldMessage = try await s.message(role: "user",body: "Mistaken historical work",topic: wrong.id)
        let wrongTask = work(wrong,oldMessage,state: "done"); try await s.insertWork(wrongTask)
        let h = ControlledHarness([Decision(action: "delegate",topicID: intended.id,instruction: "Original")]); await h.release(fail: true)
        let e = Engine(store: s,memory: mem,harness: h); try await e.send("Original"); await e.waitForIdle()
        let target = try await e.snapshot().work.last!
        await h.append(Decision(action: "correct",topicID: intended.id,taskID: wrongTask.id,instruction: "IMPORTANT corrected requirement")); try await e.send("I meant Intended"); await e.waitForIdle()
        let during = try await e.snapshot(); XCTAssertEqual(during.work.count,2); XCTAssertEqual(during.work.last?.state,"uncertain")
        XCTAssertEqual(during.amendments[0].state,"pending_reconciliation"); XCTAssertEqual(during.amendments[0].taskID,target.id)
        XCTAssertFalse(during.messages.contains { $0.body.hasPrefix("Change sent") })
        let count = await h.captures.count; XCTAssertEqual(count,1)
        await h.setStatus(.stopped); await h.release(fail: false)
        await h.append(Decision(action: "retry",topicID: intended.id,taskID: target.id)); try await e.send("retry"); await e.waitForIdle()
        let inputs = await h.captures; XCTAssertEqual(inputs.count,2); XCTAssertTrue(inputs.last!.work.instruction.contains("IMPORTANT corrected requirement"))
        XCTAssertEqual(inputs[0].topic.sessionKey,inputs[1].topic.sessionKey)
        let after = try await e.snapshot(); XCTAssertEqual(after.messages.first { $0.id == oldMessage.id }?.topicID,wrong.id)
    }
    func testCorrectionToQueuedIntendedTaskUpdatesExistingQueuedInput() async throws {
        let root = try testRoot(); let s = try Store(root: root); let mem = try MemoryStore(dataRoot: root)
        let wrong = try await s.topic(label: "Wrong"); let intended = try await s.topic(label: "Intended"); let blocker = try await s.topic(label: "Blocker")
        let h = ControlledHarness([Decision(action: "delegate",topicID: wrong.id,instruction: "Wrong"),Decision(action: "delegate",topicID: blocker.id,instruction: "Blocker"),Decision(action: "delegate",topicID: intended.id,instruction: "Queued intended")]); let e = Engine(store: s,memory: mem,harness: h)
        try await e.send("Wrong"); try await e.send("Blocker"); try await e.send("Queued intended"); await e.waitForRouting()
        try await eventually { await h.captures.count == 2 }
        let initial = try await e.snapshot(); let mistaken = initial.work.first { $0.topicID == wrong.id }!; let target = initial.work.first { $0.topicID == intended.id }!
        await h.append(Decision(action: "correct",topicID: intended.id,taskID: mistaken.id,instruction: "Queued correction")); try await e.send("I meant Intended"); await e.waitForRouting()
        let during = try await e.snapshot(); XCTAssertEqual(during.work.count,3); XCTAssertEqual(during.amendments.first?.taskID,target.id); XCTAssertEqual(during.amendments.first?.state,"queued_input")
        let amended = try await s.work(target.id); XCTAssertEqual(amended.state,"queued"); XCTAssertTrue(amended.instruction.contains("Queued correction"))
        await h.release(); await e.waitForIdle()
    }
}

final class RuntimeDisclosureTests: XCTestCase {
    func testOwnerRequestedDefaultIsLiveAndUnknownModeFailsOffline() {
        XCTAssertEqual(RuntimeMode.from([:]),.live)
        XCTAssertEqual(RuntimeMode.from(["PROJECTX_MODE":"unexpected"]),.offline)
        XCTAssertEqual(RuntimeMode.from(["PROJECTX_MODE":"live"]),.live)
    }
    func testFixtureCannotAcceptInputWithoutExplicitAcknowledgment() {
        let mode = RuntimeMode.from(["PROJECTX_MODE":"fixture","OPENCLAW_SHELL":"exec"])
        XCTAssertEqual(mode,.fixture); XCTAssertFalse(mode.permitsInput(fixtureAcknowledged: false)); XCTAssertTrue(mode.permitsInput(fixtureAcknowledged: true))
        XCTAssertEqual(mode.windowTitle,"Yorozu — TEST FIXTURE (no AI)")
        XCTAssertTrue(mode.bannerTitle.contains("NO LLM")); XCTAssertTrue(mode.explanation.contains("scripted")); XCTAssertEqual(mode.sendLabel,"Send test message")
        // Acknowledgment enables synthetic input only, never changes the adapter mode.
        XCTAssertEqual(mode,.fixture)
    }
    func testOfflineDisclosureDoesNotPromiseAnswers() {
        XCTAssertTrue(RuntimeMode.offline.windowTitle.contains("OFFLINE"))
        XCTAssertTrue(RuntimeMode.offline.explanation.contains("cannot answer"))
        XCTAssertEqual(RuntimeMode.offline.sendLabel,"Save offline")
    }
}
