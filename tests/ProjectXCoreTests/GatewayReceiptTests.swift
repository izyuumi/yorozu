import XCTest
import Foundation
import GRDB
@testable import ProjectXCore

private actor ReceiptWire {
    var methods: [String] = []
    var agentCalls = 0
    func call(_ method: String,_ raw: String,_ final: Bool) throws -> String {
        methods.append(method); agentCalls += 1
        if agentCalls == 1 { throw ProjectError.uncertain("Synthetic disconnected transport") }
        return try envelope("Recovered new request")
    }
}
final class GatewayReceiptTests: XCTestCase {
    func testLostRawRequestKeepsReceiptButNeverBlocksNextTurn() async throws {
        let root = try testRoot(); let store = try Store(root:root); let wire = ReceiptWire()
        let rpc = GatewayRPC(fixture:{ m,p,f in try await wire.call(m,p,f) },audit:{ try await store.gatewayReceipt($0) })
        let params: [String:Any] = ["idempotencyKey":"owned-request","sessionKey":"agent:projectx:projectx-model:synthetic","modelRun":true,"message":"Prompt must not be stored in correlation receipt"]
        do { _ = try await rpc.call("agent",params,final:true,sourceMessageID:"saved-message-id"); XCTFail("Expected disconnect") } catch { XCTAssertTrue(error.localizedDescription.contains("owned-request")) }
        let bodies = try await DatabaseQueue(path:root.appendingPathComponent("operations.sqlite").path).read { try String.fetchAll($0,sql:"SELECT body FROM receipts WHERE kind='gateway-request' ORDER BY rowid") }
        let last = try JSONDecoder().decode(GatewayRequestReceipt.self,from:Data(bodies.last!.utf8))
        XCTAssertEqual(last.requestID,"owned-request"); XCTAssertEqual(last.sourceMessageID,"saved-message-id"); XCTAssertEqual(last.state,"uncertain")
        XCTAssertFalse(bodies.contains { $0.contains("Prompt must not") })
        // Raw runs are stateless, so the next turn dispatches directly; agent.wait forgets unknown runs and would wedge chat.
        var next = params; next["idempotencyKey"] = "next-request"
        _ = try await rpc.call("agent",next,final:true)
        let methods = await wire.methods; XCTAssertEqual(methods,["agent","agent"])
    }
    func testFailureToPersistReceiptPreventsDispatch() async throws {
        let rpc = GatewayRPC(fixture:{ _,_,_ in XCTFail("Dispatch before durable linkage"); return "{}" },audit:{ _ in throw ProjectError.invalid("Synthetic disk error") })
        do { _ = try await rpc.call("agent",["idempotencyKey":"owned-run"],final:true); XCTFail("Expected persistence failure") } catch { XCTAssertEqual(error.localizedDescription,"Synthetic disk error") }
    }
}
