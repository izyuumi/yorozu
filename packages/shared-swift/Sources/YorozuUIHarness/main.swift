/// SwiftUI screenshots and timing. No app bundle, account or network.
/// Layout fixtures briefly host native windows so AppKit lists actually draw.
/// swift run --package-path packages/shared-swift YorozuUIHarness /tmp/yorozu-ui
import AppKit
import CryptoKit
import Foundation
import SwiftUI
import YorozuShared

actor HarnessTransport: ChatTransport {
    private var continuation: AsyncStream<TransportUpdate>.Continuation?
    func connect() -> AsyncStream<TransportUpdate> {
        let (stream, continuation) = AsyncStream<TransportUpdate>.makeStream()
        self.continuation = continuation
        continuation.yield(.state(.paired))
        continuation.yield(.ownerOnline(true))
        return stream
    }
    func send(_ event: YorozuEvent) {}
    func close() { continuation?.finish() }
    func deliver(_ event: YorozuEvent) { continuation?.yield(.event(event)) }
}

@main struct Harness {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/yorozu-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let card = ApprovalCardData(actionId: "approval", actionClass: "Bash", target: "swift test --package-path packages/shared-swift", nativeAgent: .claudeCode)
        for width in [390.0, 900.0] {
            for dark in [false, true] {
                let scene = VStack(alignment: .leading, spacing: 16) {
                    Text("Native agent bridge").font(.title2)
                    ApprovalCardView(card: card) { _, _ in }
                    QuestionCardView(card: QuestionCardData(questionId: "question", question: "Which test should run next?", options: ["Shared Swift tests", "Runtime tests"], allowOther: true)) { _ in }
                    WorkRowView(work: TurnWork(startEventId: "work", entries: [], startedAt: 0, lastAt: 2000, running: false))
                    Text("Turn interrupted").font(.headline)
                    HStack { Button("Continue") {}; Button("Dismiss") {} }.buttonStyle(.bordered)
                }
                .padding(20)
                .frame(width: width, alignment: .leading)
                .background(dark ? Color.black : Color.white)
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: scene)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = CGRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw NSError(domain: "UIHarness", code: 1)
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "UIHarness", code: 2)
                }
                try png.write(to: output.appendingPathComponent("native-\(Int(width))-\(dark ? "dark" : "light").png"))
                print("SCREEN native-\(Int(width))-\(dark ? "dark" : "light") \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            }
        }

        // Adversarial approval fixtures: the end markers must remain reachable before deciding.
        let longAction = (1...12).map { "echo action line \($0): verify the requested destination before running" }.joined(separator: "\n") + "\nACTION_END_MARKER"
        let longContent = (1...9).map { "Message paragraph \($0): Please review the complete proposed message before sending." }.joined(separator: "\n") + "\nCONTENT_END_MARKER"
        let approval = ApprovalCardData(
            actionId: "long-approval", actionClass: "run-command", target: longAction,
            scope: ApprovalScope(contentSummary: longContent),
            items: (1...6).map { BatchItem(label: "Destination \($0)", detail: String(repeating: "Review the full item detail before approving. ", count: 4) + "ITEM_\($0)_END_MARKER") },
            nativeAgent: .claudeCode
        )
        for expanded in [false, true] {
            ChatShowcase.expanded = expanded
            for width in [320.0, 390.0, 900.0] {
                for dark in [false, true] {
                    let scene = ApprovalCardView(card: approval) { _, _ in }
                        .padding(20)
                        .frame(width: width, alignment: .leading)
                        .background(dark ? Color.black : Color.white)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: scene)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = CGRect(origin: .zero, size: host.fittingSize)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    window.orderFrontRegardless()
                    defer { window.orderOut(nil) }
                    host.layoutSubtreeIfNeeded()
                    // Allow SwiftUI measurement preferences and onAppear updates to settle.
                    try await Task.sleep(for: .milliseconds(100))
                    host.frame = CGRect(origin: .zero, size: host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        throw NSError(domain: "UIHarness", code: 3)
                    }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "UIHarness", code: 4)
                    }
                    let name = "approval-\(expanded ? "expanded" : "collapsed")-\(Int(width))-\(dark ? "dark" : "light")"
                    try png.write(to: output.appendingPathComponent("\(name).png"))
                    print("APPROVAL_DIAGNOSTIC \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")

                }
            }
        }
        ChatShowcase.expanded = false
        let layoutTransport = HarnessTransport()
        let layoutModel = ChatModel(transport: layoutTransport)
        layoutModel.start()
        while !layoutModel.ownerOnline { await Task.yield() }
        let layoutThread = ThreadSummary(id: "layout", title: "Weeknight dinners and the complete family shopping list", archived: false,
            lastActivity: Date().timeIntervalSince1970 * 1000, lastMessage: "Review the dinner plan and shopping list before ordering.",
            model: "harness/long-model", effort: .high)
        await layoutTransport.deliver(YorozuEvent(id: "models", threadId: "", ts: 0, agentId: "main", payload: .modelList(ModelListData(models: [
            ModelOption(id: "harness/long-model", label: "Deliberately long reasoning model display name", providerLabel: "Validation provider")
        ]))))
        layoutModel.drafts[layoutThread.id] = "Please revise the dinner plan to include vegetarian options."
        await layoutTransport.deliver(YorozuEvent(id: "greeting", threadId: layoutThread.id, ts: 1, agentId: "main", payload: .message(MessageData(role: .agent, text: "The dinner plan is ready to review.", done: true))))
        for stress in [false, true] {
            if stress {
                layoutModel.previewActivity(in: layoutThread.id)
                layoutModel.drafts[layoutThread.id] = (1...6).map { "Draft line \($0): please retain every detail." }.joined(separator: "\n")
                layoutModel.attachments[layoutThread.id] = [MessageAttachment(name: "Dinner plan notes.txt", mime: "text/plain", data: Data("Vegetarian dinner options".utf8).base64EncodedString())]
                await layoutTransport.deliver(YorozuEvent(id: "running", threadId: layoutThread.id, ts: 2, agentId: "main", payload: .message(MessageData(role: .user, text: "Please continue revising the plan."))))
            }
            for width in (stress ? [640.0] : [640.0, 900.0, 1200.0]) {
                for dark in [false, true] {
                    let scene = NavigationSplitView {
                        ThreadSidebar(threads: [layoutThread], selection: .constant(layoutThread.id), onCreate: { _, _ in }, onRename: { _, _ in }, onArchive: { _, _ in })
                            .navigationSplitViewColumnWidth(min: LayoutMetrics.sidebarMinWidth, ideal: stress ? 400 : LayoutMetrics.sidebarIdealWidth, max: LayoutMetrics.sidebarMaxWidth)
                    } detail: {
                        ChatView(model: layoutModel, thread: layoutThread)
                    }
                    .frame(width: width, height: stress ? 420 : 720)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: scene)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = CGRect(origin: .zero, size: CGSize(width: width, height: stress ? 420 : 720))
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    window.orderFrontRegardless()
                    defer { window.orderOut(nil) }
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds),
                          let png = { host.cacheDisplay(in: host.bounds, to: bitmap); return bitmap.representation(using: .png, properties: [:]) }() else {
                        throw NSError(domain: "UIHarness", code: 5)
                    }
                    let name = "layout-\(stress ? "stress" : "ordinary")-\(Int(width))-\(dark ? "dark" : "light")"
                    try png.write(to: output.appendingPathComponent("\(name).png"))
                    print("LAYOUT_DIAGNOSTIC \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
                }
            }
        }
        layoutModel.close()
        if CommandLine.arguments.contains("--screenshots-only") { return }

        let cacheDir = output.appendingPathComponent("temporary-cache")
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let transport = HarnessTransport()
        let model = ChatModel(transport: transport, cache: ThreadCache(directory: cacheDir, key: SymmetricKey(size: .bits256)))
        model.start()
        while !model.ownerOnline { try await Task.sleep(for: .milliseconds(1)) }
        let profile = CommandLine.arguments.contains("--profile")
        let iterations = profile ? 300 : 20
        var times: [Double] = []
        for iteration in 0..<iterations {
            let page = (0..<200).map { i in YorozuEvent(id: "event-\(i)", threadId: "benchmark", ts: i, agentId: "main",
                payload: .toolResult(ToolResultData(callId: "call-\(i)", ok: true, output: String(repeating: "x", count: 4096) + "\(iteration)"))) }
            let revision = model.syncRevision
            let start = ContinuousClock.now
            await transport.deliver(YorozuEvent(id: "sync-\(iteration)", threadId: "", ts: iteration, agentId: "main", payload: .syncDelta(SyncDeltaData(events: page))))
            while model.syncRevision == revision { await Task.yield() }
            let elapsed = start.duration(to: .now).components
            times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            await model.flushCache()
        }
        times.sort()
        let report = "sync page 200x4KB: n=\(iterations), median=\(times[times.count/2])ms, p95=\(times[Int(Double(times.count-1)*0.95)])ms, max=\(times.last!)ms\n"
        print(report)
        try report.write(to: output.appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8)
        model.close()
    }
}
