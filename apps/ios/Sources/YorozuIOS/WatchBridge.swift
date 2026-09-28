import UIKit
import WatchConnectivity
import YorozuShared
import YorozuWatchLink

/// The phone's end of the watch link: answers what the watch asks, and offers nothing unasked.
///
/// The watch is not a paired device. It holds no Mac's key and never reaches the relay; a reply
/// dictated on it is sent by this phone, through the same outbox as one typed here. The link is
/// WatchConnectivity's, encrypted by the system between the two devices — see ``WatchLink``.
final class WatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchBridge()

    private static let threadLimit = 20
    private static let messageLimit = 6
    private static let messageLength = 700

    /// Requests already acted on, by id: a redelivered `send` is answered, not sent twice.
    // ponytail: in memory, so a relaunch between two deliveries of one request forgets it.
    // Persist beside the outbox if a duplicate reply is ever seen.
    @MainActor private var handled: [String: WatchResponse.Status] = [:]

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Another watch was switched to.
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        let request = WatchLink.decode(WatchRequest.self, from: message)
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            // Woken in the background for this: hold on until the answer has gone back.
            let task = UIApplication.shared.beginBackgroundTask()
            defer { UIApplication.shared.endBackgroundTask(task) }
            guard let request else { return reply([:]) }
            reply((try? WatchLink.encode(await self.answer(request))) ?? [:])
        }
    }

    @MainActor private func answer(_ request: WatchRequest) async -> WatchResponse {
        if request.kind == .threads { return WatchResponse(status: .ok, threads: threads()) }
        guard let model = Session.shared.hosts.session(for: request.host)?.model,
              model.threads.contains(where: { $0.id == request.thread && !$0.archived })
        else { return WatchResponse(status: .rejected) }
        switch request.kind {
        case .threads:
            return WatchResponse(status: .rejected)
        case .messages:
            return WatchResponse(status: .ok, messages: messages(in: request.thread, of: model))
        case .send:
            guard let text = request.sendableText else { return WatchResponse(status: .rejected) }
            if let status = handled[request.id] { return WatchResponse(status: status) }
            if handled.count > 100 { handled.removeAll() }
            handled[request.id] = .queued
            let status: WatchResponse.Status = switch await model.sendFromBackground(text, in: request.thread) {
            case .sent: .sent
            case .queued: .queued
            case .rejected: .rejected
            }
            handled[request.id] = status == .rejected ? nil : status
            return WatchResponse(status: status, messages: messages(in: request.thread, of: model))
        }
    }

    /// The end of the conversation, which is what a reply is a reply to. Long messages keep
    /// their opening: a watch is for the gist, the phone for the document.
    @MainActor private func messages(in thread: String, of model: ChatModel) -> [WatchMessage] {
        (model.events[thread] ?? []).compactMap { event -> WatchMessage? in
            guard case .message(let message) = event.payload, !message.text.isEmpty else { return nil }
            return WatchMessage(id: event.id, fromUser: message.role == .user,
                                text: String(message.text.prefix(Self.messageLength)))
        }.suffix(Self.messageLimit)
    }

    /// The list the phone itself draws, cut to what a wrist can scroll: no drafts, which have
    /// nothing to reply to, and no archive.
    @MainActor private func threads() -> [WatchThread] {
        let hosts = Session.shared.hosts
        return hosts.threads
            .filter { !$0.thread.archived && hosts.model(for: $0.id)?.isDraft($0.id.threadID) == false }
            .prefix(Self.threadLimit)
            .map {
                WatchThread(host: $0.id.hostID, thread: $0.id.threadID, title: $0.thread.displayTitle,
                            preview: $0.thread.lastMessage, hostLabel: hosts.hasMultipleHosts ? $0.hostLabel : nil,
                            unread: $0.thread.isUnread)
            }
    }
}
