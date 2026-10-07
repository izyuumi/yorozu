import XCTest
import Foundation
import CryptoKit
@testable import ProjectXCore

/// Opt-in end-to-end check against the local OpenClaw Gateway (real models, CLI transport):
///   PROJECTX_LIVE_TEST=1 ./scripts/test_native.sh --filter LiveGatewayTests
/// Creates sessions only on the dedicated projectx agent and deletes them afterwards.
final class LiveGatewayTests: XCTestCase {
    func testGreetingDelegationAndSameTopicFollowUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROJECTX_LIVE_TEST"] == "1", "Live Gateway test is opt-in.")
        let root = try testRoot(); let store = try Store(root: root); let memory = try MemoryStore(dataRoot: root)
        let workspace = root.appendingPathComponent("harness-workspaces")
        let rpc = GatewayRPC(audit: { try await store.gatewayReceipt($0) })
        let harness = OpenClawHarness(workspace: workspace,rpc: rpc)
        let engine = Engine(store: store,memory: memory,harness: harness)
        do {
            try await engine.send("hi"); await engine.waitForIdle()
            var s = try await engine.snapshot()
            XCTAssertEqual(s.messages.filter { $0.role == "assistant" && $0.kind == "conversation" }.count,1,"Greeting got no secretary reply: \(s.messages.map(\.body))")

            try await engine.send("Explain in three sentences why plain Markdown files are a good format for long-term personal memory."); await engine.waitForIdle()
            s = try await engine.snapshot()
            XCTAssertEqual(s.work.first?.state,"done","Delegated work did not finish: \(s.work.map { "\($0.state) \($0.error ?? "")" })")
            XCTAssertEqual(s.messages.filter { $0.kind == "result" }.count,1)

            try await engine.send("Building on that, analyse the biggest drawback of this approach and how to mitigate it, in three sentences."); await engine.waitForIdle()
            s = try await engine.snapshot()
            XCTAssertEqual(s.topics.count,1,"Follow-up opened a new topic")
            XCTAssertEqual(s.work.count,2,"Follow-up was not delegated: \(s.messages.suffix(2).map(\.body))")
            XCTAssertTrue(s.work.allSatisfy { $0.state == "done" && $0.topicID == s.topics[0].id })
            XCTAssertEqual(s.messages.filter { $0.kind == "result" }.count,2)
            XCTAssertFalse(s.messages.contains { $0.kind == "failure" },"Failures: \(s.messages.filter { $0.kind == "failure" }.map(\.body))")
            for m in s.messages { print("[\(m.role)/\(m.kind)] \(m.body.prefix(300))") }
        } catch { await cleanup(); throw error }
        await cleanup()

        func cleanup() async {
            let topics = (try? await store.snapshot().topics) ?? []
            let models = [harness.secretaryModel,harness.workerModel].map { "agent:projectx:projectx-model:" + SHA256.hash(data: Data((workspace.path + "|" + $0).utf8)).map { String(format: "%02x",$0) }.joined() }
            for key in topics.flatMap({ [$0.sessionKey,"agent:projectx:projectx-control:\($0.id)"] }) + models {
                _ = try? await rpc.call("sessions.delete",["key":key,"agentId":"projectx","deleteTranscript":true])
            }
        }
    }
}
