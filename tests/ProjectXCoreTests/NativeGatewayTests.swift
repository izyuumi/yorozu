import XCTest
import Foundation
import CryptoKit
@testable import ProjectXCore

final class NativeGatewayTests: XCTestCase {
    private func decodeURL(_ value: String) -> Data {
        let s = value.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        return Data(base64Encoded:s + String(repeating:"=",count:(4 - s.count % 4) % 4))!
    }
    func testV3DeviceProofBindsExactChallengeClientGrantAndBootstrap() throws {
        let key = Curve25519.Signing.PrivateKey()
        let proof = try NativeGatewayProtocol.proof(key:key,token:"synthetic-not-a-credential",scopes:NativeGatewayProtocol.scopes,nonce:"synthetic-challenge",timestamp:123)
        let id = SHA256.hash(data:key.publicKey.rawRepresentation).map { String(format:"%02x",$0) }.joined()
        XCTAssertEqual(proof["id"] as? String,id)
        XCTAssertEqual(decodeURL(proof["publicKey"] as! String),key.publicKey.rawRepresentation)
        let exact = "v3|\(id)|webchat|ui|operator|operator.read,operator.write|123|synthetic-not-a-credential|synthetic-challenge|macos|mac"
        let signature = decodeURL(proof["signature"] as! String)
        XCTAssertTrue(key.publicKey.isValidSignature(signature,for:Data(exact.utf8)))
        XCTAssertFalse(key.publicKey.isValidSignature(signature,for:Data(exact.replacingOccurrences(of:"synthetic-challenge",with:"replayed-challenge").utf8)))
        XCTAssertThrowsError(try NativeGatewayProtocol.proof(key:key,token:nil,scopes:[],nonce:"",timestamp:123))
        XCTAssertThrowsError(try NativeGatewayProtocol.proof(key:key,token:nil,scopes:[],nonce:"nonce",timestamp:-1))
    }
    func testCLIDiagnosticsAreCategoriesNotRawSecrets() {
        XCTAssertEqual(GatewayRPC.diagnosticCategory("provider/model overrides are not authorized for this caller. token=SECRET"),"model-override-not-authorized")
        XCTAssertEqual(GatewayRPC.diagnosticCategory("unknown option --bad password=SECRET"),"request-schema")
        XCTAssertEqual(GatewayRPC.diagnosticCategory("some unknown failure containing SECRET"),"unclassified-refusal-or-disconnect")
        XCTAssertEqual(GatewayRPC.diagnosticCategory("Gateway agent from agent exec would lose inter-session attribution"),"caller-attribution-restriction")
    }
    func testNativeTargetRejectsRemoteCredentialAndAlternatePath() throws {
        XCTAssertNoThrow(try NativeGatewayProtocol.target("ws://127.0.0.1:18789"))
        for value in ["ws://example.com:18789","http://127.0.0.1:18789","ws://u:p@127.0.0.1:18789","ws://localhost:18789?token=synthetic","ws://localhost:18789/internal"] { XCTAssertThrowsError(try NativeGatewayProtocol.target(value)) }
    }
    func testRefusalsExposeOnlySafePairingIdentifierNeverServerText() {
        let error: [String:Any] = ["error":["message":"password=must-not-leak","details":["code":"PAIRING_REQUIRED","requestId":"request-123"]]]
        let message = NativeGatewayProtocol.refusal(error).localizedDescription
        XCTAssertTrue(message.contains("request-123")); XCTAssertFalse(message.contains("must-not-leak"))
        XCTAssertFalse(NativeGatewayProtocol.refusal(["error":["details":["code":"PAIRING_REQUIRED","requestId":"token=must-not-leak"]]]).localizedDescription.contains("must-not-leak"))
    }
    func testRealEventContractFiltersExactRunAndNeverPersistsReasoning() throws {
        func event(_ stream: String,_ data: [String:Any],run: String = "run",session: String = "session") throws -> String {
            String(decoding:try JSONSerialization.data(withJSONObject:["event":"agent","payload":["runId":run,"sessionKey":session,"seq":1,"stream":stream,"data":data]]),as:UTF8.self)
        }
        let publicEvent = OpenClawHarness.publicEvent(try event("lifecycle",["phase":"start"]),session:"session",run:"run",task:"task")
        XCTAssertEqual(publicEvent?.body,"Worker lifecycle: start")
        XCTAssertNil(OpenClawHarness.publicEvent(try event("assistant",["text":"private or incomplete text"]),session:"session",run:"run",task:"task"))
        XCTAssertNil(OpenClawHarness.publicEvent(try event("lifecycle",["phase":"start"],run:"foreign"),session:"session",run:"run",task:"task"))
        XCTAssertNil(OpenClawHarness.publicEvent(try event("lifecycle",["phase":"start"],session:"foreign"),session:"session",run:"run",task:"task"))
        let tool = OpenClawHarness.publicEvent(try event("tool",["phase":"start","name":"memory.read","arguments":["secret":"must-not-leak"]]),session:"session",run:"run",task:"task")
        XCTAssertEqual(tool?.body,"Tool start: memory.read")
    }
    func testSecretaryHasExplicitContractAndDedicatedAgentOnActualWire() async throws {
        let root = try testRoot()
        let wire = WireFixture(outputs:["{\"action\":\"reply\",\"reply\":\"Hello!\"}"])
        let harness = OpenClawHarness(workspace:root,rpc:GatewayRPC(fixture:{ m,p,f in try await wire.call(m,p,f) }))
        let input = RoutingInput(policy:"Delegate substantive work; reuse broad topics.",message:"Hello",recent:[],topics:[],work:[],latestTopic:nil,memory:[])
        let decision = try await harness.route(input,stronger:false)
        XCTAssertEqual(decision.reply,"Hello!"); XCTAssertEqual(harness.agentID,"projectx")
        let params = await wire.params
        let request = try JSONSerialization.jsonObject(with:Data(params.last!.utf8)) as! [String:Any]
        let selection = try JSONSerialization.jsonObject(with:Data(params[0].utf8)) as! [String:Any]
        XCTAssertEqual(selection["model"] as? String,"openai-pool/gpt-6-astra")
        XCTAssertNil(request["model"]); XCTAssertNil(request["provider"])
        XCTAssertEqual(request["sessionKey"] as? String,selection["key"] as? String)
        XCTAssertEqual(request["agentId"] as? String,"projectx"); XCTAssertEqual(request["promptMode"] as? String,"none"); XCTAssertEqual(request["modelRun"] as? Bool,true)
        let prompt = request["message"] as! String
        XCTAssertTrue(prompt.contains("Return exactly ONE JSON object")); XCTAssertTrue(prompt.contains("camelCase")); XCTAssertTrue(prompt.contains("CONTEXT DATA"))
    }
    func testAuthoritativeNonvisibleTerminalCannotLeakEarlierPayload() async throws {
        let root = try testRoot()
        let rpc = GatewayRPC(fixture:{ method,params,_ in
            if method == "sessions.create" { let p = try JSONSerialization.jsonObject(with:Data(params.utf8)) as! [String:Any]; return String(decoding:try JSONSerialization.data(withJSONObject:["ok":true,"key":p["key"]!]),as:UTF8.self) }
            return "{\"status\":\"ok\",\"result\":{\"payloads\":[{\"text\":\"{\\\"action\\\":\\\"reply\\\",\\\"reply\\\":\\\"must not escape\\\"}\"}],\"meta\":{\"terminalReply\":{\"disposition\":\"suppressed\"}}}}"
        })
        let harness = OpenClawHarness(workspace:root,rpc:rpc)
        do { _ = try await harness.route(RoutingInput(policy:"",message:"Hello",recent:[],topics:[],work:[],latestTopic:nil,memory:[]),stronger:false); XCTFail("Nonvisible terminal escaped") } catch { XCTAssertTrue(error.localizedDescription.contains("withheld")) }
    }
    func testInstalledHistoryMetadataIdentityIsProjected() {
        let events = OpenClawHarness.visibleEvents(["messages":[["role":"assistant","__openclaw":["id":"committed-id","seq":3,"runId":"run"],"content":[["type":"text","text":"Committed public progress"]]]]],task:"task",run:"run")
        XCTAssertEqual(events.first?.id,"task:committed-id:0")
    }
    func testReconcileUsesExactRunTranscriptAfterGatewayForgetsRun() async throws {
        let root = try testRoot(); let store = try Store(root:root); let topic = try await store.topic(label:"Synthetic")
        let message = try await store.message(role:"user",body:"Synthetic",topic:topic.id); var item = work(topic,message); item.runID = "owned-run"
        let wire = WireFixture(outputs:[])
        let adapter = OpenClawHarness(workspace:root,rpc:GatewayRPC(fixture:{ m,p,f in try await wire.call(m,p,f) }))
        // agent.wait forgets runs ~10 min after they end: bare timeout, no endedAt.
        await wire.setWait("{\"runId\":\"owned-run\",\"status\":\"timeout\"}")
        let owned: [String:Any] = ["role":"assistant","__openclaw":["runId":"owned-run"],"content":[["type":"text","text":"{\"text\":\"Recovered substantive answer\",\"appliedRevision\":2}"]]]
        let foreign: [String:Any] = ["role":"assistant","__openclaw":["runId":"foreign-run"],"content":[["type":"text","text":"{\"text\":\"Foreign\",\"appliedRevision\":0}"]]]
        try await wire.setHistory([owned,foreign])
        switch try await adapter.reconcile(item,topic:topic) { case .completed(let output): XCTAssertEqual(output.appliedRevision,2); XCTAssertEqual(output.text,"Recovered substantive answer"); default: XCTFail("Exact run transcript not recovered") }
        // Admitted recently, no reply yet: possibly still running, so never declared stopped.
        try await wire.setHistory([foreign,["role":"user","idempotencyKey":"owned-run:user","timestamp":Date().timeIntervalSince1970 * 1000,"content":"Synthetic"]])
        switch try await adapter.reconcile(item,topic:topic) { case .unknown: break; default: XCTFail("Possibly active run declared settled") }
        // Never admitted: safe to retry.
        try await wire.setHistory([foreign])
        switch try await adapter.reconcile(item,topic:topic) { case .stopped: break; default: XCTFail("Unadmitted run not settled") }
        // Admitted but silent for over 15 minutes (timestamps are epoch ms): gone.
        try await wire.setHistory([["role":"user","idempotencyKey":"owned-run:user","timestamp":(Date().timeIntervalSince1970 - 1000) * 1000,"content":"Synthetic"]])
        switch try await adapter.reconcile(item,topic:topic) { case .stopped: break; default: XCTFail("Long-silent admitted run not settled") }
        // Aborted partial reply: ended, not a usable answer.
        try await wire.setHistory([["role":"assistant","__openclaw":["runId":"owned-run"],"content":[["type":"text","text":"partial prose"]]]])
        switch try await adapter.reconcile(item,topic:topic) { case .stopped: break; default: XCTFail("Aborted partial not settled") }
        await wire.setWait("{\"runId\":\"owned-run\",\"status\":\"pending\"}")
        switch try await adapter.reconcile(item,topic:topic) { case .running: break; default: XCTFail("Queued run not reported running") }
    }
    func testFullPayloadWinsOverTruncatedTerminalPreview() async throws {
        let full = "{\"action\":\"reply\",\"reply\":\"" + String(repeating: "x",count: 5000) + "\"}"
        let envelope = String(decoding:try JSONSerialization.data(withJSONObject:["status":"ok","result":["payloads":[["text":full]],"meta":["terminalReply":["disposition":"visible","text":String(full.prefix(4096)) + "…"]]]]),as:UTF8.self)
        let rpc = GatewayRPC(fixture:{ method,params,_ in
            if method == "sessions.create" { let p = try JSONSerialization.jsonObject(with:Data(params.utf8)) as! [String:Any]; return String(decoding:try JSONSerialization.data(withJSONObject:["ok":true,"key":p["key"]!]),as:UTF8.self) }
            return envelope
        })
        let decision = try await OpenClawHarness(workspace:try testRoot(),rpc:rpc).route(RoutingInput(policy:"",message:"Hello",recent:[],topics:[],work:[],latestTopic:nil,memory:[]),stronger:false)
        XCTAssertEqual(decision.reply?.count,5000)
    }
    func testDeletedRoleSessionIsRecreatedWhenGatewayRunsAnotherModel() async throws {
        actor Calls { var creates = 0; var runs = 0; func create() { creates += 1 }; func run() -> Int { runs += 1; return runs } }
        let calls = Calls()
        let rpc = GatewayRPC(fixture:{ method,params,_ in
            if method == "sessions.create" { await calls.create(); let p = try JSONSerialization.jsonObject(with:Data(params.utf8)) as! [String:Any]; return String(decoding:try JSONSerialization.data(withJSONObject:["ok":true,"key":p["key"]!]),as:UTF8.self) }
            let model = await calls.run() == 1 ? "gpt-6-astra" : "gpt-6-sol"
            return String(decoding:try JSONSerialization.data(withJSONObject:["status":"ok","result":["payloads":[["text":"{\"action\":\"clarify\",\"reply\":\"Which?\"}"]],"meta":["agentMeta":["provider":"openai-pool","model":model]]]]),as:UTF8.self)
        })
        let decision = try await OpenClawHarness(workspace:try testRoot(),rpc:rpc).route(RoutingInput(policy:"",message:"Hello",recent:[],topics:[],work:[],latestTopic:nil,memory:[]),stronger:true)
        XCTAssertEqual(decision.reply,"Which?"); let creates = await calls.creates; XCTAssertEqual(creates,2)
    }
    func testPersonalAgentRefusedBeforeTransport() async throws {
        let root = try testRoot(); let harness = OpenClawHarness(workspace:root,agent:"coding",rpc:GatewayRPC(fixture:{ _,_,_ in XCTFail("Personal agent RPC dispatched"); return "{}" }))
        do { _ = try await harness.route(RoutingInput(policy:"",message:"Hello",recent:[],topics:[],work:[],latestTopic:nil,memory:[]),stronger:false); XCTFail("Personal agent allowed") } catch { XCTAssertTrue(error.localizedDescription.contains("dedicated projectx")) }
    }
}
