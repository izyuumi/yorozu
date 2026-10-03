import Foundation
import XCTest
@testable import YorozuAlpha

final class AlphaChatTests: XCTestCase {
    func testReplayProjectsStopAndTerminalWithoutLateMutation() {
        let first = UUID().uuidString
        let second = UUID().uuidString
        let events = [
            event(1, first, "accepted", "こんにちは\nFirst request"),
            AlphaEvent(seq: 3, runId: first, kind: "running", text: nil,
                       data: .object(["model": .string("actual-provider-model")]), ts: 3),
            event(8, first, "stop_requested"),
            event(12, first, "update", "Partial result"),
            event(15, first, "activity"),
            event(18, first, "stopped", "Verified stopped result"),
            event(19, first, "update", "Late text must not replace result"),
            event(20, second, "accepted", "New topic, same chat"),
            event(25, second, "completed", "Independent result")
        ]
        let stopping = AlphaRun.project(Array(events.prefix(5)))
        XCTAssertEqual(stopping.first?.kind, "stop_requested")
        XCTAssertEqual(stopping.first?.answer, "Partial result")
        let replay = AlphaRun.project(events.reversed())
        XCTAssertEqual(replay.map(\.prompt), ["こんにちは\nFirst request", "New topic, same chat"])
        XCTAssertEqual(replay.map(\.kind), ["stopped", "completed"])
        XCTAssertEqual(replay.map(\.answer), ["Verified stopped result", "Independent result"])
        XCTAssertEqual(replay.first?.model, "actual-provider-model")
        XCTAssertNil(replay.last?.model)
    }

    func testLoginEnvironmentDiscoversPathWithoutImportingShellVariables() throws {
        let shell = FileManager.default.temporaryDirectory.appendingPathComponent("alpha-login-\(UUID().uuidString)")
        let script = "#!/bin/sh\necho 'Profile greeting'\nexport ALPHA_SHELL_ONLY=private\nPATH=/provider/bin:/usr/bin:/bin\nexec /bin/sh -c \"$2\"\n"
        try Data(script.utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        defer { try? FileManager.default.removeItem(at: shell) }
        let inherited = ["SHELL": shell.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let resolved = AlphaConfiguration.loginEnvironment(inherited)
        XCTAssertEqual(resolved["PATH"], "/provider/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(resolved["ALPHA_SHELL_ONLY"])
        XCTAssertEqual(resolved["SHELL"], shell.path)
        let failing = ["SHELL": "/usr/bin/false", "PATH": "/usr/bin:/bin"]
        XCTAssertEqual(AlphaConfiguration.loginEnvironment(failing), failing)
    }

    @MainActor
    func testRealHostAcceptanceDraftAndReconnect() async throws {
        guard let hostPath = ProcessInfo.processInfo.environment["YOROZU_ALPHA_TEST_HOST"] else {
            throw XCTSkip("Set YOROZU_ALPHA_TEST_HOST to the built isolated Rust alpha host.")
        }
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("yorozu-alpha-ui-test-\(UUID().uuidString)")
        let config = AlphaConfiguration(profile: profile, host: URL(fileURLWithPath: hostPath),
            node: URL(fileURLWithPath: "/usr/bin/true"), worker: profile.appendingPathComponent("unused-worker.js"))
        let model = AlphaChatModel(configuration: config)
        defer { model.close() }
        model.reconnect()
        try await until { model.ready || model.transportFailure != nil }
        XCTAssertTrue(model.ready, model.transportFailure ?? "Host was not ready")
        XCTAssertTrue(model.runs.isEmpty)
        XCTAssertEqual(model.workspace.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() },
            profile.appendingPathComponent("workspace").resolvingSymlinksInPath())
        let prompt = "こんにちは、よろず\nEnglish and 日本語 draft"
        model.draft = prompt
        XCTAssertTrue(model.canSend)
        model.send()
        // A write to the pipe is not acceptance, and must not discard the draft.
        XCTAssertEqual(model.draft, prompt)
        XCTAssertTrue(model.sending)
        try await until { !model.runs.isEmpty && model.runs.last?.terminal == true }
        XCTAssertEqual(model.runs.first?.prompt, prompt)
        XCTAssertEqual(model.draft, "")
        // Inert fixture exits without provider evidence: UI must never display Done.
        XCTAssertEqual(model.runs.first?.kind, "unconfirmed")
        let retained = model.events
        model.draft = "次の下書き\nStill here after reconnect"
        model.reconnect()
        try await until { model.ready }
        XCTAssertEqual(model.events, retained)
        XCTAssertEqual(model.runs.count, 1)
        XCTAssertEqual(model.draft, "次の下書き\nStill here after reconnect")
        XCTAssertNil(model.activeRunId)
        model.close()
        try await until { !model.ready }
        let restored = AlphaChatModel(configuration: config)
        defer { restored.close() }
        restored.reconnect()
        try await until { restored.ready || restored.transportFailure != nil }
        XCTAssertTrue(restored.ready, restored.transportFailure ?? "Reconnect not ready")
        XCTAssertEqual(restored.draft, "次の下書き\nStill here after reconnect")
        XCTAssertEqual(restored.runs.count, 1)
        XCTAssertEqual(restored.runs.first?.kind, "unconfirmed")
        XCTAssertNil(restored.activeRunId)
    }

    @MainActor
    private func until(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard predicate() else { throw NSError(domain: "AlphaClientBoundaryTimeout", code: 1) }
    }

    private func event(_ seq: Int, _ run: String, _ kind: String, _ text: String? = nil) -> AlphaEvent {
        AlphaEvent(seq: seq, runId: run, kind: kind, text: text, data: nil, ts: Double(seq))
    }
}
