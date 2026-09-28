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

    init(delayMs: Int = 0, bytesPerSecond: Int = 0) async throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", harness.appendingPathComponent("test-support/wire-harness.mjs").path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "LINK_DELAY_MS": String(delayMs), "LINK_BYTES_PER_SECOND": String(bytesPerSecond)
        ]) { _, profile in profile }
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
    /// connections hundreds of milliseconds apart on a busy runner. The shortest scheduled
    /// retry is 750 ms, so connections within 500 ms still belong to one dial.
    func dials() async throws -> [Double] {
        struct Reply: Decodable { var dials: [Double] }
        let accepted = try await get(Reply.self, "dials").dials
        return accepted.enumerated().filter { $0.offset == 0 || $0.element - accepted[$0.offset - 1] > 500 }
            .map { $0.element / 1000 }
    }

    func answerStarted() async throws -> Bool {
        struct Reply: Decodable { var started: Bool }
        return try await get(Reply.self, "answer-started").started
    }

    struct Metrics: Decodable {
        var delayMs: Int
        var bytesPerSecond: Int
        var phoneToHostBytes: Int
        var hostToPhoneBytes: Int
        var droppedHostBytes: Int
        var peakQueuedBytes: Int
    }

    func metrics() async throws -> Metrics { try await get(Metrics.self, "metrics") }

    func freshPairing() async throws -> QrPayload {
        struct Pairing: Decodable { var qr: String }
        return try QrPayload.decode(try await get(Pairing.self, "pairing").qr)
    }
}

private func elapsedMs(since start: ContinuousClock.Instant) -> Int {
    let parts = (ContinuousClock.now - start).components
    return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
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
    @Test func pairingEndpointMintsAUniqueJoinTokenEachTime() async throws {
        let rig = try await WireRig()
        let first = await rig.pairing.token
        let second = try await rig.freshPairing().token
        #expect(first != second)
    }

    /// Real relay and sidecar on a shaped 100 ms / 64 KiB/s phone link. A receipt must be
    /// measured for this exact message, and recovery starts before redial, not after handshake.
    @Test func slowLinkProfileMeasuresAcceptanceCatchupAndLargeAnswer() async throws {
        let rig = try await WireRig(delayMs: 100, bytesPerSecond: 65_536)
        let model = try await pairedModel(rig)
        let thread = model.newDraft().id
        model.send("warm", in: thread)
        try await until("warm answer", within: .seconds(10)) {
            finalReply(in: thread, model).contains { $0.text == "echo: warm" }
        }

        let acceptanceStart = ContinuousClock.now
        model.send("profile acceptance", in: thread)
        let sentID = try #require(model.outbox.last?.id)
        let queuedOperationBytes = model.outbox.reduce(0) { total, item in
            total + ((try? JSONEncoder().encode(item.event).count) ?? 0)
        }
        try await until("profile receipt", within: .seconds(10)) {
            !model.outbox.contains { $0.id == sentID }
        }
        let acceptanceMs = elapsedMs(since: acceptanceStart)

        let beforeLarge = try await rig.metrics()
        model.send("__large_answer__", in: thread)
        let largeEnd = ContinuousClock.now + .seconds(20)
        while !finalReply(in: thread, model).contains(where: { $0.text.utf8.count == 98_304 }) {
            guard ContinuousClock.now < largeEnd else {
                let hostSizes = try await rig.events(in: thread).compactMap { event -> Int? in
                    if case .message(let data) = event.payload, data.role == .agent, data.done == true {
                        return data.text.utf8.count
                    }
                    return nil
                }
                Issue.record("large answer missing: host=\(hostSizes), phone=\(finalReply(in: thread, model).map { $0.text.utf8.count }), metrics=\(try await rig.metrics())")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let responseBytes = try #require(finalReply(in: thread, model)
            .first(where: { $0.text.utf8.count == 98_304 })).text.utf8.count
        let largeAnswerWireBytes = try await rig.metrics().hostToPhoneBytes - beforeLarge.hostToPhoneBytes

        try await rig.run("hold-answer")
        model.send("profile catchup", in: thread)
        let providerEnd = ContinuousClock.now + .seconds(10)
        while try await !rig.answerStarted() {
            guard ContinuousClock.now < providerEnd else { Issue.record("provider never started catch-up turn"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await rig.run("down")
        try await rig.run("release-answer")
        let hostEnd = ContinuousClock.now + .seconds(10)
        while try await !rig.events(in: thread).contains(where: {
            if case .message(let data) = $0.payload {
                return data.role == .agent && data.done == true && data.text == "echo: profile catchup"
            }
            return false
        }) {
            guard ContinuousClock.now < hostEnd else { Issue.record("host never finished while phone was down"); return }
            try await Task.sleep(for: .milliseconds(20))
        }

        let catchupStart = ContinuousClock.now
        try await rig.run("heal")
        model.reconnect()
        try await until("caught-up answer", within: .seconds(15)) {
            finalReply(in: thread, model).contains { $0.text == "echo: profile catchup" }
        }
        let catchupMs = elapsedMs(since: catchupStart)
        let metrics = try await rig.metrics()
        #expect(metrics.delayMs == 100 && metrics.bytesPerSecond == 65_536)
        #expect(metrics.phoneToHostBytes > 0 && metrics.hostToPhoneBytes >= 98_304)
        #expect(metrics.peakQueuedBytes > 0 && queuedOperationBytes > 0)
        #expect(responseBytes == 98_304 && largeAnswerWireBytes >= responseBytes)
        #expect(acceptanceMs >= 150 && acceptanceMs <= 3_000, "slow-link acceptance: \(acceptanceMs) ms")
        #expect(catchupMs <= 10_000, "recovery through the shaped link: \(catchupMs) ms")
        #expect(metrics.hostToPhoneBytes <= 1_048_576, "superseded snapshots flooded the link")
        #expect(largeAnswerWireBytes <= 786_432, "large-answer snapshots flooded the link")
        #expect(metrics.peakQueuedBytes <= 524_288, "the proxy queued too many encrypted frames")
        #expect(finalReply(in: thread, model).filter { $0.text == "echo: profile catchup" }.count == 1)
        print("YOROZU-NETWORK-PROFILE acceptanceMs=\(acceptanceMs) catchupMs=\(catchupMs) " +
            "queuedOperationBytes=\(queuedOperationBytes) responseBytes=\(responseBytes) " +
            "largeAnswerWireBytes=\(largeAnswerWireBytes) " +
            "phoneToHostBytes=\(metrics.phoneToHostBytes) hostToPhoneBytes=\(metrics.hostToPhoneBytes) " +
            "droppedHostBytes=\(metrics.droppedHostBytes) peakQueuedBytes=\(metrics.peakQueuedBytes)")
        model.close()
    }

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
