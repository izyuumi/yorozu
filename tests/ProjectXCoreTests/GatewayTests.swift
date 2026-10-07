import XCTest
import Foundation
@testable import ProjectXCore

func envelope(_ text: String) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["status":"ok","result":["payloads":[["text":text]],"meta":[:]]]),as: UTF8.self)
}
actor WireFixture {
    var methods: [String] = []; var params: [String] = []; var outputs: [String]
    var wait: String = "{\"status\":\"timeout\"}"
    var history: String = "{\"messages\":[]}"
    init(outputs: [String]) { self.outputs = outputs }
    func call(_ method: String,_ text: String,_ final: Bool) throws -> String {
        methods.append(method); params.append(text)
        let p = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String:Any]
        if method == "sessions.create" { return String(decoding: try JSONSerialization.data(withJSONObject: ["ok":true,"key":p["key"] as! String]),as: UTF8.self) }
        if method == "chat.history" { return history }
        if method == "tools.invoke" { return "{\"ok\":true,\"output\":{\"status\":\"rejected\"}}" }
        if method == "chat.abort" { return "{\"ok\":true,\"aborted\":false,\"runIds\":[]}" }
        if method == "agent.wait" { return wait }
        guard method == "agent", !outputs.isEmpty else { throw ProjectError.invalid("Unexpected fixture RPC") }
        return try envelope(outputs.removeFirst())
    }
    func setWait(_ value: String) { wait = value }
    func setHistory(_ value: [[String:Any]]) throws { history = String(decoding: try JSONSerialization.data(withJSONObject: ["messages":value]),as: UTF8.self) }
}
actor UpdateLog {
    var handles: [RunHandle] = []; var events: [WorkerEvent] = []
    func append(_ update: StreamUpdate) { switch update { case .handle(let h): handles.append(h); case .event(let e): events.append(e) } }
}
final class GatewayTests: XCTestCase {
    func input(_ root: URL) async throws -> WorkerInput {
        let store = try Store(root: root); let topic = try await store.topic(label: "Synthetic")
        let msg = try await store.message(role: "user",body: "Synthetic thought",topic: topic.id)
        return WorkerInput(policy: "Synthetic only",topic: topic,work: work(topic,msg),current: msg,history: [],memory: [])
    }
    func testAttributionGuardsBothMarkersAndNoReauthenticationClaim() throws {
        for env in [["OPENCLAW_SHELL":"exec"],["OPENCLAW_SUBAGENT_EXEC":"1"],["OPENCLAW_SUBAGENT_EXEC":""]] {
            XCTAssertThrowsError(try GatewayRPC.enforceAttribution(env)) { XCTAssertTrue($0.localizedDescription.contains("attribution")); XCTAssertTrue($0.localizedDescription.contains("authentication")) }
        }
        XCTAssertNoThrow(try GatewayRPC.enforceAttribution([:]))
    }
    func testSameSessionReuseAndExactWirePermissions() async throws {
        let root = try testRoot(); var input = try await input(root)
        let wire = WireFixture(outputs: ["{\"text\":\"first\",\"appliedRevision\":0}","{\"text\":\"second\",\"appliedRevision\":0}"])
        let rpc = GatewayRPC(fixture: { method,text,final in try await wire.call(method,text,final) })
        let adapter = OpenClawHarness(workspace: root.appendingPathComponent("workspaces"),rpc: rpc); let log = UpdateLog()
        _ = try await adapter.run(input,update: { await log.append($0) },memory: { _ in "{}" })
        input.work.sessionReady = true; input.work.id = identifier()
        _ = try await adapter.run(input,update: { await log.append($0) },memory: { _ in "{}" })
        let methods = await wire.methods; let params = await wire.params
        XCTAssertEqual(methods.filter { $0 == "sessions.create" }.count,2)
        let runs = try zip(methods,params).filter { $0.0 == "agent" }.map { try JSONSerialization.jsonObject(with: Data($0.1.utf8)) as! [String:Any] }
        XCTAssertEqual(runs.count,2); XCTAssertEqual(runs[0]["sessionKey"] as? String,runs[1]["sessionKey"] as? String)
        XCTAssertTrue(runs.allSatisfy { $0["model"] == nil && $0["provider"] == nil }) // Least-privilege agent calls cannot override models.
        XCTAssertEqual(runs[0]["bootstrapContextMode"] as? String,"lightweight"); XCTAssertEqual(runs[0]["deliver"] as? Bool,false)
        XCTAssertFalse(methods.contains("chat.send"))
        let creates = try zip(methods,params).filter { $0.0 == "sessions.create" }.map { try JSONSerialization.jsonObject(with: Data($0.1.utf8)) as! [String:Any] }
        XCTAssertTrue(creates.contains { $0["permissionMode"] as? String == "read-only" })
        // Shared-token CLI callers have no principal/device identity; Gateway rejects idempotent sessions.create for them.
        XCTAssertTrue(creates.allSatisfy { $0["idempotencyKey"] == nil })
    }
    func testRealScopedMemoryWriteBridgeInSameHarnessSession() async throws {
        let root = try testRoot(); let input = try await input(root); let mem = try MemoryStore(dataRoot: root)
        let doc = MemoryDocument(metadata: MemoryMetadata(title: "Synthetic worker knowledge"),body: "This is unverified generated analysis.")
        let call = MemoryCall(tool: "memory.write",path: "knowledge/" + doc.metadata.id + ".md",markdown: try doc.markdown)
        let first = "{\"memoryCall\":\(try encoded(call))}"
        let wire = WireFixture(outputs: [first,"{\"text\":\"Saved actual memory\",\"appliedRevision\":0}"])
        let adapter = OpenClawHarness(workspace: root.appendingPathComponent("workspaces"),rpc: GatewayRPC(fixture: { m,p,f in try await wire.call(m,p,f) }))
        let log = UpdateLog()
        let result = try await adapter.run(input,update: { await log.append($0) },memory: { try await mem.invoke($0,sources: [input.current]) })
        XCTAssertEqual(result.text,"Saved actual memory")
        let read = try await mem.read(path: call.path!); XCTAssertEqual(try MemoryDocument.parse(read.markdown).body,doc.body)
        let handles = await log.handles; XCTAssertEqual(handles.count,2); XCTAssertEqual(handles[0].sessionKey,handles[1].sessionKey)
        XCTAssertNotEqual(handles[0].runID,handles[1].runID)
        let methods = await wire.methods; let params = await wire.params
        let runs = zip(methods,params).filter { $0.0 == "agent" }
        XCTAssertTrue(runs.last!.1.contains("indexed"))
    }
    func testSteeringRefusalNoFallbackAndObservationTimeoutNotStopped() async throws {
        let root = try testRoot(); let input = try await input(root); let wire = WireFixture(outputs: [])
        let adapter = OpenClawHarness(workspace: root,rpc: GatewayRPC(fixture: { m,p,f in try await wire.call(m,p,f) }))
        var w = input.work; w.controllerKey = "controller"; w.runID = "synthetic-run"
        let a = Amendment(id: identifier(),taskID: w.id,messageID: w.messageID,revision: 1,instruction: "change",state: "pending")
        let steer = try await adapter.steer(w,topic: input.topic,amendment: a); XCTAssertFalse(steer)
        // Gateway aborted:false means nothing under this run ID is active, queued or pending.
        let cancel = try await adapter.cancel(w,topic: input.topic); XCTAssertTrue(cancel)
        switch try await adapter.reconcile(w,topic: input.topic) { case .unknown: break; default: XCTFail("Observation timeout was mistaken for stopped execution") }
        await wire.setWait("{\"runId\":\"synthetic-run\",\"status\":\"error\",\"endedAt\":123}")
        switch try await adapter.reconcile(w,topic: input.topic) { case .stopped: break; default: XCTFail("Terminal failure not recognized") }
        let methods = await wire.methods; XCTAssertFalse(methods.contains("chat.send")); XCTAssertFalse(methods.contains("agent"))
    }
    func testProgressProjectionExcludesReasoningToolArgumentsAndSecrets() {
        let history: [String:Any] = ["messages":[
            ["id":"1","role":"assistant","channel":"analysis","__openclaw":["runId":"run"],"content":[["type":"text","text":"private reasoning"]]],
            ["id":"2","role":"assistant","__openclaw":["runId":"run"],"content":[["type":"thinking","thinking":"private"],["type":"toolCall","name":"memory.read","arguments":["secret":"hidden"]],["type":"text","text":"Public progress"],["type":"text","text":"password=synthetic-secret"],["type":"text","text":"{\"text\":\"final answer\",\"appliedRevision\":0}"]]],
            ["id":"3","role":"tool","__openclaw":["runId":"run"],"content":[["type":"text","text":"raw result"]]],
            ["id":"4","role":"assistant","__openclaw":["runId":"other-run"],"content":[["type":"text","text":"Another run's message"]]]]]
        let result = OpenClawHarness.visibleEvents(history,task: "task",run: "run")
        XCTAssertEqual(result.map(\.body),["Tool: memory.read","Public progress"])
        XCTAssertEqual(Set(result.map(\.id)).count,2)
    }
}
