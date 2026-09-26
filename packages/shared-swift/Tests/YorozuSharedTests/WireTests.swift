import Foundation
import Testing

@testable import YorozuShared

// The phone's real client against the real relay and the real Mac sidecar, over a proxy that
// fails the way a phone's network does. Everything above the socket has fake-transport tests;
// these own what only a real socket can show: noticing a dead one, and coming back whole.
// The rig is packages/runtime/test-support/wire-harness.mjs, which needs `pnpm -r build`.
// Without that build these skip locally; CI always runs them.

private let harness = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("runtime")
private let rigAvailable = ProcessInfo.processInfo.environment["CI"] != nil
    || FileManager.default.fileExists(atPath: harness.appendingPathComponent("dist/serve.js").path)

extension RelayClient.Timing {
    /// Production's shape in milliseconds: a dead socket is found within half a second.
    static let wire = Self(firstBackoff: 0.05, maxBackoff: 0.4, pingInterval: .milliseconds(200),
                           pongDeadline: .milliseconds(300), connectionDeadline: .seconds(1.5))
}

/// One harness process: a relay, a sidecar paired to nothing yet, and the proxy in front.
private actor WireRig {
    private let process = Process()
    private let input = Pipe()
    private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
    private(set) var pairing: QrPayload!

    init() async throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", harness.appendingPathComponent("test-support/wire-harness.mjs").path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        try process.run()
        struct Ready: Decodable { var qr: String; var proxy: Int }
        let ready = try JSONDecoder().decode(Ready.self, from: try await nextLine())
        var pairing = try QrPayload.decode(ready.qr)
        pairing.relayUrl = "ws://127.0.0.1:\(ready.proxy)"
        self.pairing = pairing
    }

    deinit { process.terminate() }

    private func nextLine() async throws -> Data {
        var lines = self.lines
        defer { self.lines = lines }
        guard let line = try await lines.next() else { throw CancellationError() }
        return Data(line.utf8)
    }

    /// Sends one command and returns its reply.
    @discardableResult
    func run(_ command: String) async throws -> Data {
        input.fileHandleForWriting.write(Data("\(command)\n".utf8))
        return try await nextLine()
    }

    /// The thread as the Mac recorded it.
    func events(in thread: String) async throws -> [YorozuEvent] {
        struct Reply: Decodable { var events: [YorozuEvent] }
        return try JSONDecoder().decode(Reply.self, from: try await run("events \(thread)")).events
    }

    /// When each redial reached the proxy, in seconds. URLSession makes a refused dial as a few
    /// connections a millisecond apart, so connections that close together are one dial.
    func dials() async throws -> [Double] {
        struct Reply: Decodable { var dials: [Double] }
        let accepted = try JSONDecoder().decode(Reply.self, from: try await run("dials")).dials
        return accepted.enumerated().filter { $0.offset == 0 || $0.element - accepted[$0.offset - 1] > 50 }
            .map { $0.element / 1000 }
    }
}

@MainActor
private func pairedModel(_ rig: WireRig, timing: RelayClient.Timing = .wire) async throws -> ChatModel {
    let client = try RelayClient(pairing: await rig.pairing, identity: .generate(),
                                 counters: MemoryCounterStorage(), timing: timing)
    let model = ChatModel(transport: client)
    model.start()
    try await until("paired") { model.canDeliver }
    return model
}

@MainActor
private func until(_ what: String, within limit: Duration = .seconds(5),
                   _ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let end = clock.now + limit
    while !condition() {
        guard clock.now < end else {
            Issue.record("timed out waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func finalReply(in thread: String, _ model: ChatModel) -> [MessageData] {
    (model.events[thread] ?? []).compactMap {
        guard case .message(let data) = $0.payload, data.role == .agent, data.done == true else { return nil }
        return data
    }
}

@Suite(.serialized, .enabled(if: rigAvailable, "needs `pnpm -r build` for the wire harness"))
@MainActor
struct WireTests {
    /// The foreground case nothing else catches: an idle phone whose socket died without a
    /// close. Only the pong deadline can tell, and the link has to come back by itself.
    @Test func aSilentlyDeadLinkIsNoticedAndReplacedWithoutTheAppAsking() async throws {
        let rig = try await WireRig()
        let model = try await pairedModel(rig)
        try await rig.run("blackhole")
        // Ping interval plus pong deadline, with room for a loaded CI machine.
        try await until("the dead link noticed", within: .seconds(2)) { !model.canDeliver }
        try await rig.run("heal")
        try await until("the link back") { model.canDeliver }
        let thread = model.newDraft().id
        model.send("still there", in: thread)
        try await until("the answer") { finalReply(in: thread, model).map(\.text) == ["echo: still there"] }
        model.close()
    }

    /// What a user sends into a link that died silently reaches the Mac once each, in order.
    /// Sending is when the dead link matters most, so a send does not wait for the idle ping
    /// to find out: it is checked within one pong deadline.
    @Test func messagesSentIntoADeadLinkArriveOnceEachInOrder() async throws {
        let rig = try await WireRig()
        // An idle ping that would take half a minute, so only the send itself can notice.
        let timing = RelayClient.Timing(firstBackoff: 0.05, maxBackoff: 0.4, pingInterval: .seconds(30),
                                        pongDeadline: .milliseconds(300), connectionDeadline: .seconds(1.5))
        let model = try await pairedModel(rig, timing: timing)
        let thread = model.newDraft().id
        try await rig.run("blackhole")
        model.send("first", in: thread)
        model.send("second", in: thread)
        try await until("the dead link noticed", within: .seconds(2)) { !model.canDeliver }
        try await rig.run("heal")
        try await until("both messages receipted") { model.canDeliver && model.outbox.isEmpty }
        let sent = try await rig.events(in: thread).compactMap { event -> String? in
            if case .message(let data) = event.payload, data.role == .user { data.text } else { nil }
        }
        #expect(sent == ["first", "second"])
        model.close()
    }

    /// A link that drops while the Mac is streaming an answer, and stays down until the answer is
    /// done, loses none of it and repeats none of it: the phone ends with one complete answer,
    /// just as the Mac recorded it.
    @Test func aReplyCutOffMidStreamArrivesWholeAndOnce() async throws {
        let rig = try await WireRig()
        let model = try await pairedModel(rig)
        let text = "one two three four five six seven eight nine ten"
        let thread = model.newDraft().id
        model.send(text, in: thread)
        try await until("the answer to start") {
            (model.events[thread] ?? []).contains {
                if case .message(let data) = $0.payload { data.role == .agent } else { false }
            }
        }
        try await rig.run("down")
        // The Mac finishes the answer while the phone is away, so none of it can arrive live.
        let clock = ContinuousClock()
        let end = clock.now + .seconds(5)
        while try await !rig.events(in: thread).contains(where: {
            if case .message(let data) = $0.payload { data.role == .agent && data.done == true } else { false }
        }) {
            guard clock.now < end else { Issue.record("the Mac never finished"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await rig.run("heal")
        try await until("the whole answer") { finalReply(in: thread, model).map(\.text) == ["echo: \(text)"] }
        let recorded = try await rig.events(in: thread).compactMap { event -> MessageData? in
            if case .message(let data) = event.payload, data.done != false { data } else { nil }
        }
        #expect(recorded.map(\.text) == [text, "echo: \(text)"])
        #expect(finalReply(in: thread, model).count == 1)
        model.close()
    }

    /// Redialling slows down while the relay stays away, never past its cap, starts fast again
    /// after a join, and a nudge from the app skips whatever wait is left.
    @Test func redialsBackOffToACapResetOnJoinAndYieldToAReconnect() async throws {
        let rig = try await WireRig()
        let timing = RelayClient.Timing(firstBackoff: 0.1, maxBackoff: 1, pingInterval: .seconds(30),
                                        pongDeadline: .seconds(10), connectionDeadline: .seconds(5))
        let model = try await pairedModel(rig, timing: timing)

        var mark = try await rig.dials().count
        try await rig.run("down")
        try await Task.sleep(for: .seconds(3.5))
        let refused = try await rig.dials().dropFirst(mark)
        let gaps = zip(refused.dropFirst(), refused).map { $0 - $1 }
        #expect(gaps.count >= 4, "redialled \(gaps.count) times")
        // Jitter never overlaps one step and the next, so each wait is longer than the last.
        #expect(zip(gaps.dropFirst(), gaps).prefix(3).allSatisfy { $0 > $1 }, "\(gaps)")
        #expect(gaps.allSatisfy { $0 < 1.25 }, "\(gaps)")

        // Back by itself, then away again: the first waits are short once more.
        try await rig.run("heal")
        try await until("the link back") { model.canDeliver }
        mark = try await rig.dials().count
        try await rig.run("down")
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await rig.dials().count - mark >= 2, "a join resets the backoff to its first step")

        // Let the waits grow again, then ask right after a refusal, with a second or so to go.
        try await Task.sleep(for: .seconds(2.5))
        mark = try await rig.dials().count
        while try await rig.dials().count == mark { try await Task.sleep(for: .milliseconds(10)) }
        try await rig.run("heal")
        model.reconnect()
        try await until("a redial on request", within: .milliseconds(500)) { model.canDeliver }
        model.close()
    }
}
