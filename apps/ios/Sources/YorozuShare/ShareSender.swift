import Foundation
import YorozuWire

/// Sends one share over a relay session of the extension's own, under the app's pairing: uploads the file
/// in chunks read from disk, sends the message, and returns once the host answers `delivered` or
/// `run_started`. The host keeps one session per device, so this replaces the app's while it runs.
enum ShareSender {
    enum Failure: LocalizedError {
        case hostOffline, unreachable, noAnswer, needsPairing, needsUpdate, refused(String)

        var errorDescription: String? {
            switch self {
            case .hostOffline: String(localized: "The host is offline.")
            case .unreachable: String(localized: "Couldn’t reach the relay.")
            case .noAnswer: String(localized: "The host didn’t answer in time.")
            case .needsPairing: String(localized: "Open Yorozu to check this device’s pairing.")
            case .needsUpdate: String(localized: "Update Yorozu to send from here.")
            case .refused(let why): why
            }
        }
    }

    struct File {
        var url: URL
        var attachment: Attachment
    }

    static let idleLimit: Duration = .seconds(20)
    static let window = 4

    private enum Step: Sendable { case update(RelayConnection.Update), tick }

    @MainActor
    static func send(_ message: Message, file: File?, pairing: Pairing, progress: (Double) -> Void) async throws {
        let local = PeerInfo(app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            name: DeviceModel.name, capabilities: [Attachment.capability, Attachment.resumeCapability])
        let connection = try RelayConnection(pairing: pairing.pairing, identity: pairing.identity,
            relayKnows: pairing.relayKnows, local: local)
        let (steps, feed) = AsyncStream<Step>.makeStream()
        let updates = await connection.updates()
        let forward = Task { for await update in updates { feed.yield(.update(update)) } }
        let clock = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                feed.yield(.tick)
            }
        }
        defer {
            forward.cancel()
            clock.cancel()
            feed.finish()
        }
        await connection.start()
        do {
            try await run(message, file: file, over: connection, steps: steps, progress: progress)
        } catch {
            await connection.stop()
            throw error
        }
        await connection.stop()
    }

    @MainActor
    private static func run(_ message: Message, file: File?, over connection: RelayConnection,
        steps: AsyncStream<Step>, progress: (Double) -> Void) async throws {
        let reader = try file.map { try FileHandle(forReadingFrom: $0.url) }
        defer { try? reader?.close() }
        var sender = UploadSender(size: file?.attachment.size ?? 0, window: window)
        var state = RelayConnection.State.connecting
        var heard = ContinuousClock.now
        var uploaded = file == nil
        var sha256: String?
        var restarted = false

        func pump() async throws {
            guard let file, let reader else { return }
            while let index = sender.next() {
                let range = sender.range(of: index)
                try reader.seek(toOffset: UInt64(range.lowerBound))
                let data = try reader.read(upToCount: range.count) ?? Data()
                let upload = Upload(attachmentId: file.attachment.id, name: file.attachment.name, mime: file.attachment.mime,
                    size: file.attachment.size, index: index, count: sender.count, data: data.base64EncodedString(), sha256: sha256)
                guard await connection.send(.upload(upload)) else { return }
            }
        }

        for await step in steps {
            switch step {
            case .tick:
                guard ContinuousClock.now - heard > idleLimit else { continue }
                switch state {
                case .hostOffline: throw Failure.hostOffline
                case .handshaking, .ready: throw Failure.noAnswer
                default: throw Failure.unreachable
                }
            case .update(.state(let new)):
                state = new
                switch new {
                case .unpaired, .pairingFailed: throw Failure.needsPairing
                case .updateRequired: throw Failure.needsUpdate
                default: break
                }
            case .update(.sessionOpen(let host)):
                // A host listing `resume` says which chunks it kept; an older one starts the upload over.
                heard = .now
                guard !uploaded else {
                    await connection.send(message)
                    continue
                }
                let resumes = host.capabilities.contains(Attachment.resumeCapability)
                if !resumes {
                    sha256 = nil
                } else if sha256 == nil, let url = file?.url {
                    sha256 = await Task.detached(priority: .userInitiated) { try? FileDigest.sha256(of: url) }.value
                }
                if resumes, let file, let sha256 {
                    await connection.send(.uploadStatus(UploadStatus(attachmentId: file.attachment.id, size: file.attachment.size,
                        count: sender.count, sha256: sha256)))
                } else {
                    sender.restart()
                    try await pump()
                }
            case .update(.event(let event)):
                switch event {
                case .uploadState(let held) where held.attachmentId == file?.attachment.id && !uploaded:
                    heard = .now
                    if held.done {
                        uploaded = true
                        progress(1)
                        await connection.send(message)
                    } else {
                        sender.resume(have: held.have)
                        progress(sender.progress)
                        try await pump()
                    }
                case .uploadAck(let ack) where ack.attachmentId == file?.attachment.id:
                    heard = .now
                    if ack.done {
                        uploaded = true
                        progress(1)
                        await connection.send(message)
                    } else {
                        sender.ack(ack.index)
                        progress(sender.progress)
                        try await pump()
                    }
                case .error(let error) where error.code == ErrorInfo.hashMismatch && error.attachmentId != nil
                    && error.attachmentId == file?.attachment.id && !restarted:
                    heard = .now
                    restarted = true
                    sender.restart()
                    progress(0)
                    try await pump()
                case .delivered(let ref) where ref.messageId == message.messageId:
                    return
                case .runStarted(let ref) where ref.messageId == message.messageId:
                    return
                case .error(let error) where error.messageId == message.messageId
                    || (error.attachmentId != nil && error.attachmentId == file?.attachment.id):
                    throw Failure.refused(error.message)
                default:
                    break
                }
            case .update:
                break
            }
        }
        throw CancellationError()
    }
}
