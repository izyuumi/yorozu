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
            name: DeviceModel.name, capabilities: [Attachment.capability])
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
        let count = file.map { Attachment.chunkCount($0.attachment.size) } ?? 0
        var state = RelayConnection.State.connecting
        var heard = ContinuousClock.now
        var uploaded = file == nil
        var next = 0, inFlight = 0, acked = 0

        func pump() async throws {
            guard let file, let reader else { return }
            while inFlight < window && next < count {
                try reader.seek(toOffset: UInt64(next * Attachment.chunkBytes))
                let data = try reader.read(upToCount: Attachment.chunkBytes) ?? Data()
                let upload = Upload(attachmentId: file.attachment.id, name: file.attachment.name, mime: file.attachment.mime,
                    size: file.attachment.size, index: next, count: count, data: data.base64EncodedString())
                guard await connection.send(.upload(upload)) else { return }
                next += 1
                inFlight += 1
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
            case .update(.sessionOpen):
                // A new session starts the upload over; the host drops partial uploads with the old one.
                heard = .now
                (next, inFlight, acked) = (0, 0, 0)
                if uploaded { await connection.send(message) } else { try await pump() }
            case .update(.event(let event)):
                switch event {
                case .uploadAck(let ack) where ack.attachmentId == file?.attachment.id:
                    heard = .now
                    if ack.done {
                        uploaded = true
                        progress(1)
                        await connection.send(message)
                    } else {
                        inFlight -= 1
                        acked += 1
                        progress(Double(acked) / Double(count))
                        try await pump()
                    }
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
