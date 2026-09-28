import SwiftUI
import WatchConnectivity
import YorozuWatchLink

/// Reply to a thread from the wrist. The phone does the sending — see `WatchBridge` — so this
/// holds no pairing, no socket and no cache: what it shows, it asked the phone for just now.
@main
struct YorozuWatchApp: App {
    @State private var link = PhoneLink()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ThreadList()
                    .navigationDestination(for: WatchThread.self) { ThreadView(thread: $0) }
            }
            .environment(link)
        }
    }
}

// MARK: - Link

@MainActor
@Observable
final class PhoneLink: NSObject, WCSessionDelegate {
    enum Failure: Error { case unreachable, unreadable }

    private(set) var threads: [WatchThread] = []
    private(set) var reachable = false
    private(set) var loaded = false

    override init() {
        super.init()
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func refresh() async {
        if let fresh = try? await ask(WatchRequest(kind: .threads)).threads { threads = fresh }
        loaded = true
    }

    func messages(in thread: WatchThread) async throws -> [WatchMessage] {
        try await ask(WatchRequest(kind: .messages, host: thread.host, thread: thread.thread)).messages ?? []
    }

    /// `request` is kept by the caller across a retry, so the phone sees one id and sends once.
    func send(_ request: WatchRequest) async throws -> WatchResponse {
        try await ask(request)
    }

    private func ask(_ request: WatchRequest) async throws -> WatchResponse {
        guard WCSession.default.isReachable else { throw Failure.unreachable }
        nonisolated(unsafe) let message = try WatchLink.encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            WCSession.default.sendMessage(message) { reply in
                continuation.resume(with: Result {
                    guard let response = WatchLink.decode(WatchResponse.self, from: reply)
                    else { throw Failure.unreadable }
                    return response
                })
            } errorHandler: {
                continuation.resume(throwing: $0)
            }
        }
    }

    private func connected(_ session: WCSession) {
        reachable = session.isReachable
        Task { await refresh() }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in connected(session) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in connected(session) }
    }
}

// MARK: - Views

struct ThreadList: View {
    @Environment(PhoneLink.self) private var link
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List(link.threads) { thread in
            NavigationLink(value: thread) {
                VStack(alignment: .leading) {
                    Text(thread.title)
                        .font(.headline)
                        .fontWeight(thread.unread ? .bold : .regular)
                        .lineLimit(1)
                    if let preview = thread.preview {
                        Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let host = thread.hostLabel {
                        Text(host).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
        }
        .navigationTitle("Yorozu")
        .overlay {
            if !link.loaded {
                ProgressView()
            } else if !link.reachable, link.threads.isEmpty {
                ContentUnavailableView("iPhone not reachable", systemImage: "iphone.slash",
                                       description: Text("Keep your iPhone nearby."))
            } else if link.threads.isEmpty {
                ContentUnavailableView("No chats yet", systemImage: "iphone",
                                       description: Text("Open Yorozu on your iPhone."))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await link.refresh() } }
        }
    }
}

struct ThreadView: View {
    @Environment(PhoneLink.self) private var link
    let thread: WatchThread

    private enum Delivery { case sending, sent, queued, failed }

    @State private var messages: [WatchMessage] = []
    @State private var loaded = false
    @State private var pending: WatchRequest?
    @State private var delivery: Delivery?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading) {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if messages.isEmpty, let preview = thread.preview {
                    // The phone could not be asked: what the list already knew.
                    Text(preview)
                }
                ForEach(messages) { message in
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(message.fromUser ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: message.fromUser ? .trailing : .leading)
                        .multilineTextAlignment(message.fromUser ? .trailing : .leading)
                }
                status
            }
            .padding(.horizontal)
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle(thread.title)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                // The system's own input: dictation, Scribble or the keyboard, as the wearer
                // has it set up. Nothing here listens to a microphone.
                TextFieldLink(prompt: Text("Reply")) {
                    Label("Reply", systemImage: "mic.fill")
                } onSubmit: { text in
                    let request = WatchRequest(kind: .send, host: thread.host, thread: thread.thread, text: text)
                    Task { await send(request) }
                }
                .disabled(delivery == .sending)
            }
        }
        .task {
            messages = (try? await link.messages(in: thread)) ?? []
            loaded = true
        }
    }

    @ViewBuilder private var status: some View {
        switch delivery {
        case .sending: ProgressView().frame(maxWidth: .infinity)
        case .sent: Label("Sent", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
        case .queued:
            Label("Saved on iPhone. It sends when your Mac is reachable.", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            if let pending {
                Text(pending.text ?? "").foregroundStyle(.secondary)
                Button("Not sent. Try again") { Task { await send(pending) } }
            }
        case nil: EmptyView()
        }
    }

    private func send(_ request: WatchRequest) async {
        guard let text = request.sendableText else { return }
        pending = request
        delivery = .sending
        guard let response = try? await link.send(request), response.status != .rejected,
              response.status != .ok else {
            delivery = .failed
            return
        }
        pending = nil
        delivery = response.status == .sent ? .sent : .queued
        messages = response.messages ?? messages + [WatchMessage(id: request.id, fromUser: true, text: text)]
    }
}
