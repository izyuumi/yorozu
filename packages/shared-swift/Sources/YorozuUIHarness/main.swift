/// SwiftUI screenshots and timing. No app bundle, account or network.
/// Layout fixtures briefly host native windows so AppKit lists actually draw.
/// swift run --package-path packages/shared-swift YorozuUIHarness /tmp/yorozu-ui --screenshots-only
/// Add --round-two for adversarial questions, messages, agent states, folders and search.
/// --send-freeze measures native Mac Send stalls; --verify-send checks the 250 ms budget.
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
    func send(_ event: YorozuEvent) {
        guard CommandLine.arguments.contains("--channel-model"), case .threadModelsRequest = event.payload else { return }
        continuation?.yield(.event(YorozuEvent(id: "catalog", threadId: event.threadId, ts: event.ts, agentId: "main",
            payload: .threadModels(ThreadModelsData(requestId: event.id, models: [
                ChannelModelOption(id: "openclaw/fast", label: "Fast model", available: true),
                ChannelModelOption(id: "openclaw/offline", label: "Offline model", available: false, unavailableReason: "Provider offline"),
            ])))))
    }
    func close() { continuation?.finish() }
    func deliver(_ event: YorozuEvent) { continuation?.yield(.event(event)) }
}

@main struct Harness {
    @MainActor static func render<V: View>(_ scene: V, name: String, width: Double, height: Double? = nil, dark: Bool, output: URL) async throws {
        let host = NSHostingView(rootView: scene.frame(width: width).background(dark ? Color.black : Color.white).environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height ?? host.fittingSize.height))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        if height == nil { host.frame = CGRect(origin: .zero, size: host.fittingSize) }
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "UIHarness", code: 6) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "UIHarness", code: 7) }
        try png.write(to: output.appendingPathComponent("\(name).png"))
        print("REVIEW_DIAGNOSTIC \(name) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }

    @MainActor static func main() {
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print(error); exit(1) }
        }
        NSApplication.shared.run()
    }

    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/yorozu-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--secretary-activity") {
            let transport = HarnessTransport()
            let model = ChatModel(transport: transport)
            model.start()
            while !model.ownerOnline { await Task.yield() }
            let id = SecretaryUI.threadID
            let thread = ThreadSummary(id: id, title: "Yorozu", archived: false, lastActivity: 0, agent: .codex)
            func event(_ name: String, _ payload: YorozuEvent.Payload) -> YorozuEvent {
                YorozuEvent(id: name, threadId: id, ts: Int(Date().timeIntervalSince1970 * 1000), agentId: "main", payload: payload)
            }
            await transport.deliver(event("threads", .threadList(ThreadListData(threads: [thread]))))
            while !model.listed { await Task.yield() }
            let previous = UserDefaults.standard.object(forKey: SecretaryUI.technicalDetailsKey)
            defer {
                if let previous { UserDefaults.standard.set(previous, forKey: SecretaryUI.technicalDetailsKey) }
                else { UserDefaults.standard.removeObject(forKey: SecretaryUI.technicalDetailsKey) }
                model.close()
            }
            UserDefaults.standard.set(false, forKey: SecretaryUI.technicalDetailsKey)
            var events = [
                event("request", .message(MessageData(role: .user, text: "Check the draft and save a copy.", completionId: "fixture:request:final"))),
                event("milestone", .message(MessageData(role: .agent, text: "I’ve checked the draft. I’m saving a copy now."))),
                event("command", .toolCall(ToolCallData(callId: "command", name: "commandExecution", args: ["command": .string("COMMAND_DETAIL_MARKER")]))),
            ]
            func show(_ name: String, running: Bool, japanese: Bool = false) async throws {
                var currentThread = thread
                currentThread.activeEventId = running ? events.last(where: {
                    if case .message(let message) = $0.payload { return message.role == .user }
                    return false
                })?.id : nil
                currentThread.turnState = name == "unconfirmed" ? .stoppedUnconfirmed : running ? .running : .idle
                await transport.deliver(event("threads", .threadList(ThreadListData(threads: [currentThread]))))
                await transport.deliver(event(UUID().uuidString, .syncDelta(SyncDeltaData(events: events, threadId: id, workingThreadIds: running ? [id] : []))))
                try await Task.sleep(for: .milliseconds(100))
                try await render(NavigationStack {
                    SecretaryChatView(model: model, onHistory: {})
                }.environment(\.locale, Locale(identifier: japanese ? "ja" : "en")),
                    name: "secretary-\(name)", width: 880, height: 650, dark: false, output: output)
            }
            try await show("working", running: true)
            UserDefaults.standard.set(true, forKey: SecretaryUI.technicalDetailsKey)
            try await show("details", running: true)
            UserDefaults.standard.set(false, forKey: SecretaryUI.technicalDetailsKey)
            events += [event("approval", .approvalCard(ApprovalCardData(actionId: "approve", actionClass: "run", target: "Save outside the granted folder")))]
            try await show("approval", running: true)
            events.removeLast()
            events += [event("result", .toolResult(ToolResultData(callId: "command", ok: false, output: "OUTPUT_DETAIL_MARKER"))),
                event("final", .message(MessageData(role: .agent, text: "I couldn’t save the copy. Choose another folder to try again.", done: true, failed: true)))]
            await transport.deliver(event("approval-resolved", .approvalStatus(ApprovalStatusData(requestId: "fixture", actionId: "approve", status: .noLongerNeeded))))
            try await show("error", running: false)
            try await show("error-ja", running: false, japanese: true)
            events += [event("result", .toolResult(ToolResultData(callId: "command", ok: true, output: "OUTPUT_DETAIL_MARKER"))),
                event("final", .message(MessageData(role: .agent, text: "Saved the copy in your chosen folder.", done: true)))]
            try await show("completed", running: false)
            events += [event("second-request", .message(MessageData(role: .user, text: "Check another copy."))),
                event("second-command", .toolCall(ToolCallData(callId: "second-command", name: "commandExecution", args: [:]))),
                event("stop", .stopStatus(StopStatusData(targetEventId: "second-request", requestId: "stop-request", status: .unconfirmed)))]
            try await show("unconfirmed", running: true)
            // A later host-owned running turn must not inherit the old stop's missing cue.
            events += [event("third-request", .message(MessageData(role: .user, text: "Continue after recovery."))),
                event("third-command", .toolCall(ToolCallData(callId: "third-command", name: "commandExecution", args: [:])))]
            try await show("running-after-old-stop", running: true)
            return
        }
        if CommandLine.arguments.contains("--send-freeze") {
            let cache = ThreadCache(directory: output.appendingPathComponent("send-cache"), key: SymmetricKey(size: .bits256))
            let thread = ThreadSummary(id: "send-fixture", title: "Synthetic send", archived: false, lastActivity: 1)
            let count = Int(ProcessInfo.processInfo.environment["YOROZU_SEND_HISTORY_COUNT"] ?? "1000") ?? 1000
            cache.save(threads: [thread])
            cache.save(events: (0..<count).map { index in
                YorozuEvent(id: "history-\(index)", threadId: thread.id, ts: index, agentId: "main",
                    payload: .message(MessageData(role: index.isMultiple(of: 2) ? .user : .agent,
                        text: "Synthetic history \(index). " + String(repeating: "日本語の文章。 ", count: 20), done: true)))
            }, threadId: thread.id)
            let transport = HarnessTransport()
            let model = ChatModel(transport: transport, cache: cache, device: "mac")
            model.start()
            let host = NSHostingView(rootView: NavigationStack { ChatView(model: model, thread: thread) })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 720),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Yorozu synthetic send investigation"
            window.contentView = host
            window.orderFrontRegardless()
            var maxGap: Duration = .zero
            let heartbeat = Task { @MainActor in
                var last = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                    let now = ContinuousClock.now
                    maxGap = max(maxGap, last.duration(to: now))
                    last = now
                }
            }
            try await Task.sleep(for: .seconds(2))
            var report = "Synthetic Mac view: \(count) history messages\n"
            var worstGap: Duration = .zero
            for index in 0..<5 {
                model.drafts[thread.id] = "Synthetic send \(index)"
                try await Task.sleep(for: .milliseconds(100))
                maxGap = .zero
                let start = ContinuousClock.now
                // Exercise the shipping model with the native ChatView mounted. This measures
                // submission and ensuing rendering; it does not inject a button or Return event.
                model.send(in: thread)
                let submitted = start.duration(to: .now)
                try await Task.sleep(for: .milliseconds(500))
                worstGap = max(worstGap, maxGap)
                report += "send \(index): submission=\(submitted), UI heartbeat max gap=\(maxGap)\n"
            }
            heartbeat.cancel()
            await model.shutdown()
            window.orderOut(nil)
            print(report)
            try report.write(to: output.appendingPathComponent("send-timing.txt"), atomically: true, encoding: .utf8)
            let restored = ChatModel(transport: HarnessTransport(), cache: cache, device: "mac")
            guard restored.outbox.filter({ $0.event.payload.kind == .message }).count == 5,
                  restored.drafts[thread.id]?.isEmpty == true else {
                throw NSError(domain: "SendHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic sends were not preserved in the offline outbox"])
            }
            if CommandLine.arguments.contains("--verify-send"), worstGap >= .milliseconds(250) {
                throw NSError(domain: "SendHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mac Send blocked the UI for \(worstGap)"])
            }
            return
        }
        if CommandLine.arguments.contains("--channel-model") {
            NSApplication.shared.setActivationPolicy(.regular)
            let transport = HarnessTransport()
            let model = ChatModel(transport: transport)
            model.start()
            while !model.ownerOnline { await Task.yield() }
            await transport.deliver(YorozuEvent(id: "capability", threadId: "", ts: 0, agentId: "main",
                payload: .modelList(ModelListData(models: [], channelCapabilities: ["model-select-v1"]))))
            while !model.channelModelSelection { await Task.yield() }
            model.newDraft()
            let host = NSHostingView(rootView: ChannelDraftScene(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "OpenClaw model picker"
            window.contentView = host
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            try await Task.sleep(for: .seconds(300))
            window.orderOut(nil)
            model.close()
            return
        }
        if CommandLine.arguments.contains("--turn-folding") {
            let now = Int(Date().timeIntervalSince1970 * 1000)
            let prompt = YorozuEvent(id: "ask", threadId: "fold", ts: now - 40_000, agentId: "phone",
                payload: .message(MessageData(role: .user, text: "Review the change")))
            let thought = YorozuEvent(id: "thought", threadId: "fold", ts: now - 5_000, agentId: "main",
                payload: .thought(ThoughtData(text: "Checking the implementation against the existing tests.")))
            let reply = YorozuEvent(id: "reply", threadId: "fold", ts: now, agentId: "main",
                payload: .message(MessageData(role: .agent, text: "Reviewed.", done: true)))
            let stop = YorozuEvent(id: "stop", threadId: "fold", ts: now, agentId: "main",
                payload: .stopStatus(StopStatusData(targetEventId: "ask", requestId: "request", status: .stopped)))
            let examples = [
                chatRows(from: [prompt, thought], generating: true, activeEventId: "ask"),
                chatRows(from: [prompt, thought, reply]),
                chatRows(from: [prompt, thought, reply, stop]),
            ]
            for width in [320.0, 900.0] {
                for dark in [false, true] {
                    let scene = VStack(alignment: .leading, spacing: 16) {
                        ForEach(examples.indices, id: \.self) { index in
                            ForEach(examples[index]) { row in
                                if case .work(let work) = row { WorkRowView(work: work) }
                            }
                        }
                    }.padding()
                    try await render(scene, name: "turn-folding-\(Int(width))-\(dark ? "dark" : "light")",
                        width: width, dark: dark, output: output)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--round-two") {
            let option = "Choose the complete vegetarian dinner plan for the entire family, including substitutions, allergies, and shopping instructions. OPTION_END_MARKER"
            let question = QuestionCardData(questionId: "long-question", question: "Which complete dinner plan should we prepare for the family this weekend? QUESTION_END_MARKER", options: [option, "Keep the existing plan"], allowOther: true)
            for width in [320.0, 640.0] {
                for dark in [false, true] {
                    let suffix = "\(Int(width))-\(dark ? "dark" : "light")"
                    try await render(QuestionCardView(card: question) { print("QUESTION_ANSWER \($0)") }.padding(16), name: "question-pending-\(suffix)", width: width, dark: dark, output: output)
                    let progress = ProgressCardData(cardId: "progress", title: "Prepare the complete dinner plan", steps: ProgressStep.State.allCases.map { ProgressStep(label: "Review every requirement and preserve the full instructions for this \($0.rawValue) step. STEP_END_MARKER", state: $0) })
                    try await render(ProgressCardView(card: progress, activity: "Checking every ingredient and preparation step").padding(16), name: "progress-\(suffix)", width: width, dark: dark, output: output)
                    try await render(QuestionCardView(card: question, answered: true, chosen: option) { _ in }.padding(16), name: "question-answered-\(suffix)", width: width, dark: dark, output: output)
                    let text = "Review this result before continuing.\n\n```shell\necho \(String(repeating: "long-command-", count: 14))CODE_END_MARKER\n```\n\n| Choice | Detail |\n| --- | --- |\n| Vegetarian | \(String(repeating: "Shopping detail ", count: 10))TABLE_END_MARKER |"
                    try await render(MessageBubble(id: "message-actions", data: MessageData(role: .agent, text: text, done: true), onRetry: {}, onDelete: {}).padding(16), name: "message-actions-\(suffix)", width: width, dark: dark, output: output)
                    try await render(MessageBubble(id: "user-failed", data: MessageData(role: .user, text: "Please keep this unsent request until the Mac reconnects."), status: .failed, onDelete: {}, onResend: {}).padding(16), name: "message-failed-\(suffix)", width: width, dark: dark, output: output)
                    try await render(RuleEditorView(rule: ApprovalRule(id: "rule", actionClass: "send-message", decision: .always, scope: ["recipient": ApprovalRuleField(mode: .exact, value: "family@example.com")]), title: "Always allow", onSave: { _ in }, onCancel: {}), name: "rule-editor-\(suffix)", width: width, height: 640, dark: dark, output: output)
                }
            }
            for dark in [false, true] {
                try await render(RuleEditorView(rule: ApprovalRule(id: "invalid-rule", actionClass: "send-message", decision: .always), title: "Always allow", onSave: { _ in }, onCancel: {}), name: "rule-invalid-380-\(dark ? "dark" : "light")", width: 380, height: 420, dark: dark, output: output)
            }
            let emptyTransport = HarnessTransport()
            let emptyModel = ChatModel(transport: emptyTransport)
            emptyModel.start()
            while !emptyModel.ownerOnline { await Task.yield() }
            for agent in [ThreadAgent.codex, .claudeCode, .yorozu] {
                let thread = emptyModel.newDraft(agent: agent, cwd: agent == .yorozu ? nil : "/Users/example/Projects/資料 and a project with a long directory name")
                for width in [280.0, 640.0] {
                    for dark in [false, true] {
                        try await render(ChatView(model: emptyModel, thread: thread), name: "empty-\(agent.rawValue)-\(Int(width))-\(dark ? "dark" : "light")", width: width, height: 420, dark: dark, output: output)
                    }
                }
            }
            emptyModel.close()
            NewThreadShowcase.agent = .codex
            for status in [ProjectListStatus.loading, .ready, .offline, .failed] {
                for dark in [false, true] {
                    try await render(NewThreadPicker(projects: [], status: status, onRefresh: {}) { _, _ in }, name: "picker-\(status)-380-\(dark ? "dark" : "light")", width: 380, height: 480, dark: dark, output: output)
                }
            }
            for dark in [false, true] {
                try await render(NewThreadPicker(projects: [ProjectFolder(path: "/Users/example/Projects/資料 and a project with a long directory name/selected-project", name: "selected-project")], status: .ready, onRefresh: {}) { _, _ in }, name: "picker-longpath-380-\(dark ? "dark" : "light")", width: 380, height: 480, dark: dark, output: output)
            }
            NewThreadShowcase.agent = nil
            let searchThreads = [
                ThreadSummary(id: "metadata", title: "Implement settings", archived: false, lastActivity: Date().timeIntervalSince1970 * 1000, agent: .claudeCode, cwd: "/Users/example/Projects/app"),
                ThreadSummary(id: "archived", title: "Archived lunar review", archived: true, lastActivity: 0, agent: .codex)
            ]
            for query in ["Claude", "lunar"] {
                ThreadListShowcase.query = query
                for dark in [false, true] {
                    try await render(ThreadSidebar(threads: searchThreads, selection: .constant(nil), onCreate: { _, _ in }, onRename: { _, _ in }, onArchive: { _, _ in }), name: "search-\(query)-320-\(dark ? "dark" : "light")", width: 320, height: 420, dark: dark, output: output)
                }
            }
            ThreadListShowcase.query = ""
            return
        }
        let card = ApprovalCardData(actionId: "approval", actionClass: "Bash", target: "swift test --package-path packages/shared-swift", nativeAgent: .claudeCode)
        for width in [390.0, 900.0] {
            for dark in [false, true] {
                let scene = VStack(alignment: .leading, spacing: 16) {
                    Text("Native agent bridge").font(.title2)
                    UpdateStatusView(status: UpdateStatusData(phase: .countdown, version: "1.0",
                        deadline: (Date().timeIntervalSince1970 + 10) * 1000)) {}
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

private struct ChannelDraftScene: View {
    let model: ChatModel
    var body: some View {
        if let thread = model.draft {
            NavigationStack { ChatView(model: model, thread: thread) }
        }
    }
}
