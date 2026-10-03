import Foundation
import Darwin
import Observation
import YorozuShared

struct AlphaConfiguration {
    let profile: URL
    let host: URL
    let node: URL
    let worker: URL

    static let hostEnvironment = loginEnvironment(ProcessInfo.processInfo.environment)

    // Match the existing sidecar's login PATH discovery without starting its legacy runtime.
    // ponytail: one synchronous lookup per app launch, with a two-second wait ceiling.
    static func loginEnvironment(_ environment: [String: String]) -> [String: String] {
        let mark = "__YOROZU_PATH__"
        let process = Process()
        let output = Pipe()
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        process.executableURL = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-lc", "printf '\(mark)%s\(mark)' \"$PATH\""]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard (try? process.run()) != nil else { return environment }
        guard exited.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            return environment
        }
        // A background job may retain stdout. Bound the read instead of waiting for EOF.
        guard process.terminationStatus == 0,
              fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK) != -1,
              let bytes = try? output.fileHandleForReading.read(upToCount: 64 * 1024) else { return environment }
        let parts = String(decoding: bytes, as: UTF8.self).components(separatedBy: mark)
        guard parts.count == 3, parts[1].hasPrefix("/") else { return environment }
        let login = parts[1].split(separator: ":").map(String.init)
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        guard !Set(login).isSubset(of: inherited) else { return environment }
        var result = environment
        var seen = Set<String>()
        result["PATH"] = (login + inherited).filter { seen.insert($0).inserted }.joined(separator: ":")
        return result
    }

    var hasTemporaryProfile: Bool {
        let path = profile.resolvingSymlinksInPath().path
        return [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp")].contains {
            path.hasPrefix($0.resolvingSymlinksInPath().path + "/")
        }
    }

    static func launch() -> Self {
        let environment = ProcessInfo.processInfo.environment
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        func path(_ key: String, _ fallback: URL) -> URL {
            let name = key.prefix(1) + key.dropFirst().lowercased()
            return (launchArgument("alpha\(name)") ?? environment["YOROZU_ALPHA_\(key)"])
                .map { URL(fileURLWithPath: $0) } ?? fallback
        }
        let saved = UserDefaults(suiteName: "to.yumi.yorozu.alpha.internal")?
            .string(forKey: "profileRoot").map { URL(fileURLWithPath: $0) }
        let configuration = Self(profile: path("PROFILE", saved ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("yorozu-alpha-native-\(UUID().uuidString)")),
            host: path("HOST", resources.appendingPathComponent("yorozu-alpha-host")),
            node: path("NODE", resources.appendingPathComponent("node")),
            worker: path("WORKER", resources.appendingPathComponent("runtime/dist/alpha-worker.js")))
        if configuration.hasTemporaryProfile {
            UserDefaults(suiteName: "to.yumi.yorozu.alpha.internal")?.set(configuration.profile.path, forKey: "profileRoot")
        }
        return configuration
    }
}

struct AlphaEvent: Codable, Equatable, Sendable {
    let seq: Int
    let runId: String
    let kind: String
    let text: String?
    let data: JSONValue?
    let ts: Double
}

struct AlphaRequest: Encodable {
    let version = 1
    let id: String
    let op: String
    var runId: String? = nil
    var text: String? = nil
}

private struct AlphaEnvelope: Decodable {
    let version: Int
    let id: String?
    let event: AlphaEvent?
    let result: AlphaResult?
}

private struct AlphaResult: Decodable {
    let error: String?
    let profileRoot: String?
    let workspace: String?
    let events: [AlphaEvent]?
    let activeRunId: String?
    let accepted: Bool?
    let requested: Bool?
    let runId: String?
}

struct AlphaSubmission: Codable, Equatable {
    let runId: String
    let text: String
}

private struct AlphaCache: Codable {
    let draft: String
    let candidate: AlphaSubmission?
    let events: [AlphaEvent]
}

struct AlphaRun: Identifiable {
    let id: String
    var prompt = ""
    var answer = ""
    var kind = "accepted"
    var detail: String?
    var model: String?
    var activityCount = 0

    var terminal: Bool { ["completed", "stopped", "failed", "unconfirmed"].contains(kind) }
    var label: String {
        switch kind {
        case "accepted": "Waiting / 待機中"
        case "running", "update", "activity": "Working / 作業中"
        case "stop_requested": "Stop requested / 停止要求済み"
        case "completed": "Done / 完了"
        case "stopped": "Stopped / 停止確認済み"
        case "failed": "Failed / 失敗"
        default: "Outcome unconfirmed / 結果未確認"
        }
    }

    static func project(_ events: [AlphaEvent]) -> [Self] {
        var order: [String] = []
        var runs: [String: Self] = [:]
        for event in events.sorted(by: { $0.seq < $1.seq }) {
            if runs[event.runId] == nil { order.append(event.runId) }
            var run = runs[event.runId] ?? Self(id: event.runId)
            if run.terminal { continue }
            switch event.kind {
            case "accepted": run.prompt = event.text ?? ""
            case "running":
                if case .object(let data) = event.data, case .string(let model) = data["model"] {
                    run.model = model
                }
            case "update": run.answer = event.text ?? run.answer
            case "completed", "stopped": run.answer = event.text ?? run.answer
            case "failed", "unconfirmed": run.detail = event.text
            case "activity": run.activityCount += 1
            default: break
            }
            // Activity and partial text cannot undo a requested stop or terminal outcome.
            if !run.terminal && !(run.kind == "stop_requested" && ["running", "update", "activity"].contains(event.kind)) {
                run.kind = event.kind
            }
            runs[event.runId] = run
        }
        return order.compactMap { runs[$0] }
    }
}

@MainActor @Observable
final class AlphaChatModel {
    let configuration: AlphaConfiguration
    var draft = "" { didSet { persist() } }
    private(set) var events: [AlphaEvent] = []
    private(set) var ready = false
    private(set) var connecting = false
    private(set) var sending = false
    private(set) var activeRunId: String?
    private(set) var workspace: String?
    private(set) var notice: String?
    private(set) var transportFailure: String?
    private(set) var stopSending = false
    private var requestedStopRunId: String?
    private var candidate: AlphaSubmission?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var requests: [String: String] = [:]
    @ObservationIgnored private var requestTimeouts: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var cacheEnabled = false

    init(configuration: AlphaConfiguration) {
        self.configuration = configuration
        guard configuration.hasTemporaryProfile else { return }
        if let bytes = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(AlphaCache.self, from: bytes) {
            draft = cache.draft
            candidate = cache.candidate
            events = cache.events
        }
    }

    var runs: [AlphaRun] { AlphaRun.project(events) }
    var canSend: Bool { ready && !sending && activeRunId == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf8.count <= 16000 }
    var stopPending: Bool { stopSending || (activeRunId != nil && requestedStopRunId == activeRunId) || runs.contains { $0.id == activeRunId && $0.kind == "stop_requested" } }
    var canStop: Bool { ready && activeRunId != nil && !stopPending }
    private var cacheURL: URL { configuration.profile.appendingPathComponent("state/native-ui.json") }

    func reconnect() {
        guard !connecting else { return }
        guard configuration.hasTemporaryProfile else {
            transportFailure = "An isolated temporary profile is required / 一時フォルダ内の専用プロファイルが必要です"
            return
        }
        connecting = true
        ready = false
        transportFailure = nil
        if process?.isRunning == true {
            guard input != nil else {
                connecting = false
                transportFailure = "Host is shutting down; reconnect shortly / ホスト終了中・しばらくして再接続してください"
                return
            }
            request(op: "snapshot")
            return
        }
        let next = Process()
        next.executableURL = configuration.host
        next.arguments = [configuration.profile.path, configuration.node.path, configuration.worker.path]
        next.environment = AlphaConfiguration.hostEnvironment
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        next.standardInput = stdinPipe
        next.standardOutput = stdoutPipe
        // Never put arbitrary provider logs, account paths or secrets into the transcript.
        next.standardError = FileHandle.nullDevice
        do {
            try next.run()
            process = next
            input = stdinPipe.fileHandleForWriting
            generation = UUID()
            buffer = Data()
            requests.removeAll()
            let token = generation
            let reader = stdoutPipe.fileHandleForReading
            Task.detached(priority: .utility) { [weak self] in
                // read(upToCount:) can wait to fill its buffer on a still-open pipe.
                // availableData returns each available JSONL chunk without waiting for EOF.
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    await self?.receive(chunk, token: token)
                }
                await self?.disconnected(token: token)
                try? reader.close()
            }
            request(op: "snapshot")
        } catch {
            connecting = false
            transportFailure = "Could not start the isolated host / ホストを起動できません: \(error.localizedDescription)"
        }
    }

    func send() {
        guard canSend else { return }
        let submission = candidate?.text == draft ? candidate! : AlphaSubmission(runId: UUID().uuidString, text: draft)
        candidate = submission
        sending = true
        notice = "Sending; waiting for host acceptance / 送信中・ホストの受付待ち"
        persist()
        request(op: "submit", submission: submission)
    }

    func stop() {
        guard canStop, let activeRunId else { return }
        stopSending = true
        notice = "Sending Stop; cessation is not confirmed / 停止を要求中・停止未確認"
        request(op: "stop", runId: activeRunId)
    }

    private func request(op: String, submission: AlphaSubmission? = nil, runId: String? = nil) {
        let id = UUID().uuidString
        requests[id] = op
        do {
            guard let input else { throw CocoaError(.fileWriteUnknown) }
            var bytes = try JSONEncoder().encode(AlphaRequest(id: id, op: op, runId: submission?.runId ?? runId, text: submission?.text))
            bytes.append(10)
            try input.write(contentsOf: bytes)
            requestTimeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self, self.requests.removeValue(forKey: id) != nil else { return }
                self.requestTimeouts[id] = nil
                self.connecting = false
                self.ready = false
                self.sending = false
                self.stopSending = false
                self.transportFailure = "Host acknowledgement timed out. Reconnect to check history / ホストの応答待ちが時間切れ。再接続して履歴を確認してください"
            }
        } catch {
            disconnected(token: generation)
        }
    }

    private func receive(_ chunk: Data, token: UUID) {
        guard token == generation else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard line.count <= 1024 * 1024,
                  let envelope = try? JSONDecoder().decode(AlphaEnvelope.self, from: line), envelope.version == 1
            else { protocolFailure(); return }
            if let event = envelope.event { merge([event]) }
            if let id = envelope.id, let result = envelope.result, let op = requests.removeValue(forKey: id) {
                requestTimeouts.removeValue(forKey: id)?.cancel()
                response(result, op: op)
            }
        }
        if buffer.count > 1024 * 1024 { protocolFailure() }
    }

    private func response(_ result: AlphaResult, op: String) {
        if let error = result.error {
            connecting = false
            sending = false
            stopSending = false
            notice = "Host refused \(op): \(error) / ホストが要求を拒否しました"
            if op == "snapshot" { transportFailure = notice }
            persist()
            return
        }
        switch op {
        case "snapshot":
            guard let profile = result.profileRoot, let workspace = result.workspace, let retained = result.events,
                  URL(fileURLWithPath: profile).resolvingSymlinksInPath() == configuration.profile.resolvingSymlinksInPath()
            else { protocolFailure(); return }
            cacheEnabled = true
            self.workspace = workspace
            guard merge(retained, replacing: true) else { return }
            activeRunId = result.activeRunId
            requestedStopRunId = nil
            sending = false
            stopSending = false
            connecting = false
            ready = true
            transportFailure = nil
            notice = candidate == nil ? nil : "Acceptance not found. Send retries the same message ID / 受付が見つかりません。送信で同じIDを再試行します"
            persist()
        case "submit":
            sending = false
            if result.accepted == true, let runId = result.runId {
                if !runs.contains(where: { $0.id == runId && $0.terminal }) { activeRunId = runId }
                acknowledge(runId)
            }
            else { notice = "Message was not accepted; draft kept / 未受付・下書きを保持しました" }
        case "stop":
            stopSending = false
            if result.requested == true { requestedStopRunId = result.runId }
            notice = result.requested == true
                ? "Stop requested; waiting for the worker to end / 停止要求済み・ワーカー終了待ち"
                : "No active run accepted Stop; reconnect to check / 停止対象が見つかりません。再接続して確認してください"
        default: break
        }
    }

    @discardableResult private func merge(_ incoming: [AlphaEvent], replacing: Bool = false) -> Bool {
        var retained = replacing ? [:] : Dictionary(events.map { ($0.seq, $0) }, uniquingKeysWith: { first, _ in first })
        for event in incoming {
            guard event.seq > 0, UUID(uuidString: event.runId) != nil,
                  ["accepted", "running", "update", "activity", "stop_requested", "completed", "stopped", "failed", "unconfirmed"].contains(event.kind),
                  retained[event.seq] == nil || retained[event.seq] == event
            else { protocolFailure(); return false }
            retained[event.seq] = event
            if event.kind == "accepted" { acknowledge(event.runId) }
        }
        events = retained.values.sorted { $0.seq < $1.seq }
        activeRunId = runs.last(where: { !$0.terminal })?.id
        if activeRunId == nil { stopSending = false; requestedStopRunId = nil }
        persist()
        return true
    }

    private func acknowledge(_ runId: String) {
        guard let submission = candidate, submission.runId == runId else { return }
        candidate = nil
        if draft == submission.text { draft = "" }
        sending = false
        notice = nil
        persist()
    }

    private func protocolFailure() {
        ready = false
        connecting = false
        sending = false
        stopSending = false
        transportFailure = "Unsupported or invalid host response. Outcome unconfirmed / ホストの応答が無効・結果未確認"
    }

    private func disconnected(token: UUID) {
        guard token == generation else { return }
        ready = false
        connecting = false
        sending = false
        stopSending = false
        requests.removeAll()
        requestTimeouts.values.forEach { $0.cancel() }
        requestTimeouts.removeAll()
        input = nil
        process = nil
        transportFailure = "Host disconnected. Active outcomes are unconfirmed until replay / ホスト切断・再接続まで作業結果は未確認"
        persist()
    }

    private func persist() {
        guard cacheEnabled else { return }
        do {
            let bytes = try JSONEncoder().encode(AlphaCache(draft: draft, candidate: candidate, events: events))
            try bytes.write(to: cacheURL, options: .atomic)
        } catch {
            notice = "Could not save the draft/history cache / 下書き・履歴を保存できません: \(error.localizedDescription)"
        }
    }

    func close() {
        persist()
        requestTimeouts.values.forEach { $0.cancel() }
        try? input?.close()
        input = nil
        // EOF is the host's shutdown path; never turn killing a process into a Stop receipt.
    }
}
