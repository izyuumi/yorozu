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

/// One harness process: a relay, a sidecar paired to nothing yet, and the proxy in front.
private actor WireRig {
    private let process = Process()
    private let control: URL
    private(set) var pairing: QrPayload!

    init() async throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", harness.appendingPathComponent("test-support/wire-harness.mjs").path]
        // Held open for the harness's lifetime: it stops when this end closes.
        process.standardInput = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        struct Ready: Decodable { var control: Int }
        var lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
        guard let line = try await lines.next() else { throw CancellationError() }
        control = URL(string: "http://127.0.0.1:\(try JSONDecoder().decode(Ready.self, from: Data(line.utf8)).control)")!
        struct Pairing: Decodable { var qr: String }
        pairing = try QrPayload.decode(try await get(Pairing.self, "pairing").qr)
    }

    deinit { process.terminate() }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        let url = control.appending(path: path).appending(queryItems: query)
        return try JSONDecoder().decode(type, from: try await URLSession.shared.data(from: url).0)
    }

    /// Applies one fault, or `heal`.
    func run(_ fault: String) async throws {
        var request = URLRequest(url: control.appending(path: fault))
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }

    /// The thread as the Mac recorded it.
    func events(in thread: String) async throws -> [YorozuEvent] {
        struct Reply: Decodable { var events: [YorozuEvent] }
        return try await get(Reply.self, "events", [URLQueryItem(name: "thread", value: thread)]).events
    }

    /// When each redial reached the proxy, in seconds. URLSession makes a refused dial as a few
    /// connections a millisecond apart, so connections that close together are one dial.
    func dials() async throws -> [Double] {
        struct Reply: Decodable { var dials: [Double] }
        let accepted = try await get(Reply.self, "dials").dials
        return accepted.enumerated().filter { $0.offset == 0 || $0.element - accepted[$0.offset - 1] > 50 }
            .map { $0.element / 1000 }
    }
}

@MainActor
private func pairedModel(_ rig: WireRig) async throws -> ChatModel {
    let client = try RelayClient(pairing: await rig.pairing, identity: .generate(),
                                 counters: MemoryCounterStorage())
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
    /// The relay spends a pairing code before it says `joined`. A first join cut off in between
    /// leaves the phone remembered but unaware of it, and the code is gone: the phone has to
    /// come back as the device the room knows, not keep offering a code that cannot work.
    @Test func aFirstJoinCutOffBeforeJoinedStillPairs() async throws {
        let rig = try await WireRig()
        try await rig.run("lose-joined")
        let model = try await pairedModel(rig)
        let thread = model.newDraft().id
        model.send("paired after all", in: thread)
        try await until("the answer") { finalReply(in: thread, model).map(\.text) == ["echo: paired after all"] }
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
        let model = try await pairedModel(rig)

        var mark = try await rig.dials().count
        try await rig.run("down")
        let end = ContinuousClock.now + .seconds(130)
        while try await rig.dials().count - mark < 7 {
            guard ContinuousClock.now < end else { Issue.record("not enough redials: \(try await rig.dials())"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let refused = try await rig.dials().dropFirst(mark)
        let gaps = zip(refused.dropFirst(), refused).map { $0 - $1 }
        #expect(gaps.count >= 6, "redialled \(gaps.count) times")
        // Jitter never overlaps one step and the next, so each wait is longer than the last.
        #expect(zip(gaps.dropFirst(), gaps).prefix(3).allSatisfy { $0 > $1 }, "\(gaps)")
        #expect(gaps.last! < 31.25, "two retries capped near 30 seconds: \(gaps)")

        // Back by itself, then away again: the first waits are short once more.
        try await rig.run("heal")
        try await until("the link back", within: .seconds(40)) { model.canDeliver }
        mark = try await rig.dials().count
        try await rig.run("down")
        let resetEnd = ContinuousClock.now + .seconds(5)
        while try await rig.dials().count - mark < 2 {
            guard ContinuousClock.now < resetEnd else { Issue.record("join did not reset backoff"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Ask right after another refusal, while the next backoff is still pending.
        mark = try await rig.dials().count
        let refusal = ContinuousClock.now + .seconds(12)
        while try await rig.dials().count == mark {
            guard ContinuousClock.now < refusal else {
                Issue.record("no redial while the relay was away; dials: \(try await rig.dials())")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await rig.run("heal")
        model.reconnect()
        try await until("a redial on request", within: .seconds(2)) { model.canDeliver }
        model.close()
    }
}
