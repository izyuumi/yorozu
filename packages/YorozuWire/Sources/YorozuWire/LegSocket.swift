import Foundation
import Network

/// One WebSocket of the phone's session: the relay's `URLSessionWebSocketTask` or a direct `NWConnection`.
/// `send` only enqueues, synchronously, so frames leave in the order the caller sealed them.
protocol LegSocket: AnyObject, Sendable {
    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void)
    /// The next text message; throws once the socket has ended.
    func receive() async throws -> String
    /// nil: drop the socket; otherwise close it with that WebSocket close code first.
    func close(code: Int?)
    /// What the peer said when it closed, for diagnostics; nil while open or when it said nothing.
    var closeReason: String? { get }
    /// The peer's WebSocket close code; nil while open or when it sent none.
    var closeCode: Int? { get }
}

final class RelaySocket: LegSocket, @unchecked Sendable {
    let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) { self.task = task }

    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        task.send(.string(text)) { completion($0) }
    }

    func receive() async throws -> String {
        while true {
            if case .string(let text) = try await task.receive() { return text }
        }
    }

    func close(code: Int?) {
        if let code, let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) {
            task.cancel(with: closeCode, reason: nil)
        } else {
            task.cancel()
        }
    }

    var closeReason: String? { task.closeReason.flatMap { String(data: $0, encoding: .utf8) } }
    var closeCode: Int? { task.closeCode == .invalid ? nil : task.closeCode.rawValue }
}

/// A direct WebSocket to the Mac's listener (`NWConnection` + `NWProtocolWebSocket`): no ATS question, and
/// it says when iOS withholds Local Network access. A LAN candidate never goes over cellular.
final class DirectSocket: LegSocket, @unchecked Sendable {
    struct Closed: LocalizedError {
        let code: Int?
        var errorDescription: String? {
            switch code.flatMap(DirectCloseCode.init(rawValue:)) {
            case .sleeping: String(localized: "The Mac went to sleep")
            case .unauthorized: String(localized: "The Mac refused this iPhone on the direct path")
            case .superseded: String(localized: "A newer connection took over")
            case .tooLarge: String(localized: "A message was too large")
            case nil: String(localized: "The direct connection closed")
            }
        }
    }

    private enum Opcode: Sendable { case text, close, other }
    private struct Received: Sendable { var data: Data?; var opcode: Opcode?; var closeCode: Int? }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "to.yumi.yorozu.direct")
    private let lock = NSLock()
    private var closedCode: Int?
    /// Called on `.waiting`: whether iOS is withholding Local Network access, and the error.
    private let onWaiting: @Sendable (_ localNetworkDenied: Bool, _ reason: String) -> Void

    init(_ candidate: DirectCandidate, onWaiting: @escaping @Sendable (Bool, String) -> Void) {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = DirectMessage.maxBytes
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        if candidate.kind == .lan { parameters.prohibitedInterfaceTypes = [.cellular] }
        connection = NWConnection(host: NWEndpoint.Host(candidate.host),
                                  port: NWEndpoint.Port(rawValue: UInt16(clamping: candidate.port)) ?? .any, using: parameters)
        self.onWaiting = onWaiting
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .waiting(let error):
                onWaiting(connection.currentPath?.unsatisfiedReason == .localNetworkDenied, error.localizedDescription)
            case .failed:
                // Pending receives fail with it, which ends the leg.
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                        completion: .contentProcessed { completion($0) })
    }

    func receive() async throws -> String {
        while true {
            let message: Received = try await withCheckedThrowingContinuation { continuation in
                connection.receiveMessage { data, context, _, error in
                    if let error { return continuation.resume(throwing: error) }
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                    let opcode: Opcode? = switch metadata?.opcode {
                    case .text?: .text
                    case .close?: .close
                    case nil: nil
                    default: .other
                    }
                    let code: Int? = switch metadata?.closeCode {
                    case .privateCode(let value)?: Int(value)
                    case .applicationCode(let value)?: Int(value)
                    case .protocolCode(let value)?: Int(value.rawValue)
                    default: nil
                    }
                    continuation.resume(returning: Received(data: data, opcode: opcode, closeCode: code))
                }
            }
            switch message.opcode {
            case .text?:
                return String(decoding: message.data ?? Data(), as: UTF8.self)
            case .close?:
                lock.withLock { closedCode = message.closeCode }
                connection.cancel()
                throw Closed(code: message.closeCode)
            case .other?:
                continue
            case nil:
                if message.data == nil {
                    connection.cancel()
                    throw Closed(code: nil)
                }
            }
        }
    }

    func close(code: Int?) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = switch code {
        case let code? where code >= 4000: .privateCode(UInt16(clamping: code))
        case let code?: NWProtocolWebSocket.CloseCode.Defined(rawValue: UInt16(clamping: code)).map { .protocolCode($0) } ?? .protocolCode(.normalClosure)
        case nil: .protocolCode(.normalClosure)
        }
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        let connection = connection
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        // A close frame that cannot leave must not keep the connection.
        queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
    }

    var closeReason: String? { lock.withLock { closedCode }.map { Closed(code: $0).localizedDescription } }
    var closeCode: Int? { lock.withLock { closedCode } }
}
