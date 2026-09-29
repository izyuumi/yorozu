#if os(macOS)
import AppKit
import SwiftUI
import Testing

@testable import YorozuShared

private actor OpeningTransport: ChatTransport {
    private let (updates, continuation) = AsyncStream<TransportUpdate>.makeStream()
    func connect() -> AsyncStream<TransportUpdate> { updates }
    func send(_ event: YorozuEvent) {}
    func close() { continuation.finish() }
    func deliver(_ event: YorozuEvent) { continuation.yield(.event(event)) }
}

/// Repeated ordinary opens settle at newest in the real scroll container.
@Test @MainActor func ordinaryThreadOpeningShowsNewestInMacScrollView() async throws {
    let transport = OpeningTransport()
    let model = ChatModel(transport: transport)
    model.start()
    let threads = [model.newDraft(), model.newDraft()]
    for thread in threads {
        model.previewChat(in: thread.id)
    }
    let host = NSHostingView(rootView: AnyView(ChatView(model: model, thread: threads[0])))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil); model.close() }

    func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    func timeline() throws -> NSScrollView {
        host.layoutSubtreeIfNeeded()
        return try #require(scrollViews(in: host).first {
            ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height
        })
    }
    func expectNewest(_ context: String) async throws {
        for _ in 0..<3 {
            let scroll = try timeline()
            let height = try #require(scroll.documentView?.bounds.height)
            #expect(height - scroll.documentVisibleRect.maxY <= 40,
                    "Newest message is offscreen after \(context)")
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    for thread in threads + threads {
        host.rootView = AnyView(ChatView(model: model, thread: thread))
        // Let SwiftUI's asynchronous layout finish.
        try await Task.sleep(for: .milliseconds(500))
        try await expectNewest("thread switch")
    }

    let thread = threads[1]
    let now = Int(Date().timeIntervalSince1970 * 1000)
    for index in 0..<30 {
        await transport.deliver(YorozuEvent(id: "replayed-\(index)", threadId: thread.id,
            ts: now + index, agentId: "main", payload: .message(MessageData(
                role: index.isMultiple(of: 2) ? .user : .agent,
                text: "Replayed message \(index)\n\n**Markdown** with another paragraph.", done: true))))
    }
    try await Task.sleep(for: .milliseconds(500))
    try await expectNewest("replay")

    func growReply(_ paragraphs: Int) async {
        await transport.deliver(YorozuEvent(id: "streamed", threadId: thread.id,
            ts: now + 100 + paragraphs, agentId: "main", payload: .message(MessageData(
                role: .agent, text: String(repeating: "Growing **Markdown** reply.\n\n", count: paragraphs)))))
    }
    for paragraphs in [1, 8, 20] {
        await growReply(paragraphs)
        try await Task.sleep(for: .milliseconds(200))
        try await expectNewest("streaming \(paragraphs) paragraphs")
    }

    let url = try #require(URL(string: "https://scroll-test.invalid"))
    LinkPreviewStore.shared.preload(LinkPreview(title: "Preview", host: "scroll-test.invalid"), for: url)
    await transport.deliver(YorozuEvent(id: "media", threadId: thread.id, ts: now + 200,
        agentId: "main", payload: .message(MessageData(role: .agent, text: url.absoluteString))))
    try await Task.sleep(for: .milliseconds(200))
    try await expectNewest("link arrival")
    let heightBeforeMedia = try #require(timeline().documentView?.bounds.height)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: 0, y: 0)
    let pixel = try #require(bitmap.representation(using: .png, properties: [:]))
    let attachment = try #require(MessageAttachment(name: "image.png", mime: "image/png", bytes: pixel))
    await transport.deliver(YorozuEvent(id: "media", threadId: thread.id, ts: now + 201,
        agentId: "main", payload: .message(MessageData(role: .agent, text: url.absoluteString, done: true,
            attachments: [attachment]))))
    LinkPreviewStore.shared.preload(LinkPreview(
        title: "The loaded link preview has a longer title that wraps onto another line",
        host: "scroll-test.invalid"), for: url)
    try await Task.sleep(for: .milliseconds(300))
    #expect(try #require(timeline().documentView?.bounds.height) > heightBeforeMedia)
    try await expectNewest("media growth")

    // Exact navigation still owns its destination, including while later content grows.
    host.rootView = AnyView(ChatView(model: model, thread: thread, resumeRequest: UUID(),
        notificationEventRef: YorozuCrypto.threadRef("showcase-ask")))
    try await Task.sleep(for: .milliseconds(500))
    #expect(try timeline().documentVisibleRect.minY < 40)
    await growReply(30)
    try await Task.sleep(for: .milliseconds(200))
    #expect(try timeline().documentVisibleRect.minY < 40)

    host.rootView = AnyView(ChatView(model: model, thread: thread)
        .environment(\.threadSearchRequest, ThreadSearchRequest(threadId: thread.id,
            query: "Kitanoya", eventId: "showcase-ask")))
    try await Task.sleep(for: .milliseconds(500))
    #expect(try timeline().documentVisibleRect.minY < 40)
}
#endif
