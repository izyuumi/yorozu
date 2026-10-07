import SwiftUI
import AppKit
import ProjectXCore

@MainActor final class AppModel: ObservableObject {
    let runtimeMode = RuntimeMode.from(ProcessInfo.processInfo.environment)
    @Published var fixtureAcknowledged = false
    @Published var snapshot = Snapshot()
    @Published var draft = ""
    @Published var notice = "Opening local workspace…"
    @Published var ready = false
    @Published var submitting = false
    @Published var showEnrollment = false
    @Published var bootstrapSecret = ""
    @Published var connecting = false
    let nativeSelected = ProcessInfo.processInfo.environment["PROJECTX_TRANSPORT"] == "native"
    private var nativeClient: NativeGatewayClient?
    private var engine: Engine?
    private var observation: Task<Void,Never>?
    func start() {
        guard observation == nil else { return }
        observation = Task {
            do {
                let env = ProcessInfo.processInfo.environment
                // Private app state: ~/Library/Application Support/<bundle id>; rebuildable index: ~/Library/Caches/<bundle id>.
                // User-owned Markdown memory: visible ~/Yorozu/memory (owner decision). Fixtures and PROJECTX_DATA keep all in one root.
                let fm = FileManager.default; let bundleID = Bundle.main.bundleIdentifier ?? "to.yumi.yorozu"
                let explicit = env["PROJECTX_DATA"].map { URL(fileURLWithPath: $0,isDirectory: true) }
                let support = try fm.url(for: .applicationSupportDirectory,in: .userDomainMask,appropriateFor: nil,create: true).appendingPathComponent(bundleID,isDirectory: true)
                let root = explicit ?? (runtimeMode == .fixture ? support.appendingPathComponent("Fixture",isDirectory: true) : support)
                let store = try Store(root: root)
                let memory = explicit != nil || runtimeMode == .fixture ? try MemoryStore(dataRoot: root) : try MemoryStore(
                    root: fm.homeDirectoryForCurrentUser.appendingPathComponent("Yorozu/memory",isDirectory: true),
                    index: try fm.url(for: .cachesDirectory,in: .userDomainMask,appropriateFor: nil,create: true).appendingPathComponent(bundleID + "/memory-index.sqlite"))
                try await memory.rebuild()
                let harness: any Harness
                switch runtimeMode.rawValue {
                case "fixture": harness = FixtureHarness()
                case "live":
                    // Native launch is NOT an escape from an inherited exec restriction.
                    try GatewayRPC.enforceAttribution(env)
                    guard env["PROJECTX_AGENT"] == nil || env["PROJECTX_AGENT"] == "projectx" else { throw ProjectError.blocked("R1 uses only the dedicated projectx agent, never personal agents.") }
                    if nativeSelected { nativeClient = try NativeGatewayClient(target: env["PROJECTX_GATEWAY_URL"] ?? "ws://127.0.0.1:18789") }
                    var live = OpenClawHarness(workspace: root.appendingPathComponent("harness-workspaces"),agent: "projectx",secretaryModel: env["PROJECTX_SECRETARY_MODEL"] ?? "openai-pool/gpt-6-astra",workerModel: env["PROJECTX_MODEL"] ?? "openai-pool/gpt-6-sol",rpc: GatewayRPC(native: nativeClient,audit: { try await store.gatewayReceipt($0) }))
                    // R2 coding workers (Claude Code / Codex). The dev repo holds the untracked OWNER_DECISIONS.md they may read.
                    live.claudeModel = env["PROJECTX_CLAUDE_MODEL"] ?? live.claudeModel; live.codexModel = env["PROJECTX_CODEX_MODEL"] ?? live.codexModel
                    live.repo = URL(fileURLWithPath: env["PROJECTX_DEV_REPO"] ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Projects/PROJECTX").path,isDirectory: true)
                    harness = live
                default: harness = OfflineHarness()
                }
                let engine = Engine(store: store,memory: memory,harness: harness); self.engine = engine
                await engine.resume()
                notice = runtimeMode == .live ? "OpenClaw Gateway · projectx" : harness.name; ready = true
                while !Task.isCancelled { snapshot = try await engine.snapshot(); try await Task.sleep(for: .milliseconds(350)) }
            } catch is CancellationError { }
            catch { notice = error.localizedDescription; ready = false }
        }
    }
    func stop() { observation?.cancel(); bootstrapSecret = ""; if let engine { Task { await engine.shutdown() } }; if let nativeClient { Task { await nativeClient.close() } } }
    func enroll() async {
        guard let nativeClient, !connecting else { return }
        connecting = true; let secret = bootstrapSecret; bootstrapSecret = ""
        defer { connecting = false }
        do { try await nativeClient.connect(bootstrapSecret: secret.isEmpty ? nil : secret); notice = "Native Gateway connected · model response not yet verified"; showEnrollment = false }
        catch { notice = error.localizedDescription }
    }
    func send() async {
        guard let engine, !submitting, runtimeMode.permitsInput(fixtureAcknowledged: fixtureAcknowledged) else { return }
        submitting = true; defer { submitting = false }
        let text = draft
        do { try await engine.send(text); if draft == text { draft = "" }; snapshot = try await engine.snapshot() }
        catch { notice = error.localizedDescription }
    }
    /// Active or blocking work first: coding and thinking tasks can run side by side in one topic.
    func current(_ topic: Topic) -> Work? { snapshot.work.last { $0.topicID == topic.id && ($0.active || $0.state == "uncertain") } ?? snapshot.work.last { $0.topicID == topic.id } }
    func status(_ topic: Topic) -> String { current(topic)?.state ?? "idle" }
    func symbol(_ topic: Topic) -> String {
        if let work = current(topic), work.state == "amendment_pending", work.result != nil { return "exclamationmark.circle" }
        switch status(topic) { case "working","queued","amendment_pending": return "circle.dotted"
        case "done": return "checkmark.circle"
        case "failed","uncertain","cancellation_requested": return "exclamationmark.circle"
        default: return "circle" }
    }
}
struct MessageCard: View {
    let message: Message
    @State private var copied: Bool?
    var body: some View {
        VStack(alignment: .leading,spacing: 6) {
            HStack {
                Text(message.role == "user" ? "You" : "Yorozu").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: copy) {
                    Label(copied == nil ? "Copy" : copied! ? "Copied" : "Copy failed",systemImage: copied == nil ? "doc.on.doc" : copied! ? "checkmark" : "exclamationmark.triangle")
                }.buttonStyle(.borderless).font(.caption).foregroundStyle(copied == false ? Color.orange : Color.secondary)
                    .help("Copy message text").accessibilityLabel(copied == nil ? "Copy message" : copied! ? "Message copied" : "Copy failed")
            }
            // Assistant Markdown renders natively in one Text, so a drag still selects the whole message; user text stays verbatim.
            Text(message.role == "user" ? AttributedString(message.body) : AttributedString(chatMarkdown: message.body)).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading)
        }.padding(12).background(message.role == "user" ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func copy() {
        let board = NSPasteboard.general; board.clearContents()
        let ok = board.setString(message.body,forType: .string); copied = ok
        NSAccessibility.post(element: NSApp as Any,notification: .announcementRequested,userInfo: [.announcement: ok ? "Message copied" : "Copy failed",.priority: NSAccessibilityPriorityLevel.high.rawValue])
        Task { try? await Task.sleep(for: .seconds(2)); if copied == ok { copied = nil } }
    }
}
struct MainChat: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView { LazyVStack(alignment: .leading,spacing: 14) {
                    if model.snapshot.messages.isEmpty { Text("One conversation. Background thinking in topic sub-chats.").foregroundStyle(.secondary).padding(.vertical,30) }
                    ForEach(model.snapshot.messages) { MessageCard(message: $0).id($0.id) }
                }.padding() }
                .onChange(of: model.snapshot.messages.count) { _,_ in if let last = model.snapshot.messages.last { reader.scrollTo(last.id,anchor: .bottom) } }
            }
            Divider()
            HStack(alignment: .bottom) {
                TextEditor(text: $model.draft).font(.body).frame(minHeight: 60,maxHeight: 110).accessibilityLabel(model.runtimeMode == .fixture ? "Synthetic test message, no AI" : "Main conversation message").disabled(!model.runtimeMode.permitsInput(fixtureAcknowledged: model.fixtureAcknowledged))
                Button(model.runtimeMode.sendLabel) { Task { await model.send() } }.keyboardShortcut(.return,modifiers: .command).buttonStyle(.borderedProminent)
                    .disabled(!model.ready || model.submitting || !model.runtimeMode.permitsInput(fixtureAcknowledged: model.fixtureAcknowledged) || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding()
            Text("⌘ Return to send · Return for a new line").font(.caption2).foregroundStyle(.secondary).padding(.bottom,6)
        }.frame(minWidth: 380)
    }
}
struct InspectionPane: View {
    @ObservedObject var model: AppModel
    let topic: Topic
    var body: some View {
        ScrollView { LazyVStack(alignment: .leading,spacing: 12) {
                Text("Inspect only · \(model.status(topic))").font(.caption).foregroundStyle(.secondary)
                ForEach(model.snapshot.messages.filter { $0.topicID == topic.id && $0.kind == "conversation" }) { MessageCard(message: $0) }
                ForEach(model.snapshot.work.filter { $0.topicID == topic.id }) { work in
                    GroupBox { VStack(alignment: .leading,spacing: 9) {
                        Text(work.instruction).font(.headline).textSelection(.enabled)
                        Text(([work.executor.map { $0 == "codex" ? "Codex" : "Claude Code" }].compactMap { $0 } + [work.state.replacingOccurrences(of: "_",with: " ")]).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        ForEach(model.snapshot.amendments.filter { $0.taskID == work.id }) { amendment in
                            Text("Amendment \(amendment.revision) · \(amendment.state)\n\(amendment.instruction)").font(.callout).textSelection(.enabled)
                        }
                        ForEach(model.snapshot.events.filter { $0.taskID == work.id }) { event in
                            VStack(alignment: .leading) { Text(event.kind).font(.caption).foregroundStyle(.secondary)
                                Text(event.body).font(["command","output","error","diff"].contains(event.kind) ? .system(.callout,design: .monospaced) : .body).textSelection(.enabled) }
                        }
                        if let error = work.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                        if let result = work.result { Text(work.suppressed ? "Retained result (superseded)" : "Retained result").font(.caption).foregroundStyle(.secondary); Text(AttributedString(chatMarkdown: result)).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity,alignment: .leading) }
                }
            }.padding() }
            .navigationTitle(topic.label)
    }
}
/// Popup: topic sub-chats list, each pushing its inspect-only timeline.
struct SubChats: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationStack {
            List(model.snapshot.topics) { topic in
                NavigationLink { InspectionPane(model: model,topic: topic) } label: { Label(topic.label,systemImage: model.symbol(topic)) }
                    .help(model.status(topic)).accessibilityLabel("\(topic.label), \(model.status(topic))")
            }
            .overlay { if model.snapshot.topics.isEmpty { ContentUnavailableView("No sub-chats yet",systemImage: "bubble.left.and.bubble.right") } }
            .navigationTitle("Sub-chats")
        }.frame(width: 480,height: 620)
    }
}
struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showSubChats = false
    var body: some View {
        MainChat(model: model).safeAreaInset(edge: .top) { if model.runtimeMode != .live {
            VStack(alignment: .leading,spacing: 6) {
                Label(model.runtimeMode.bannerTitle,systemImage: "exclamationmark.triangle.fill").font(.headline)
                Text(model.runtimeMode.explanation).font(.callout).fixedSize(horizontal: false,vertical: true)
                if model.runtimeMode == .fixture && !model.fixtureAcknowledged {
                    Button("I understand: enable synthetic TEST input") { model.fixtureAcknowledged = true }
                        .accessibilityIdentifier("acknowledgeSyntheticFixture")
                }
            }.frame(maxWidth: .infinity,alignment: .leading).padding(12)
                .background(Color.orange.opacity(0.18)).accessibilityElement(children: .contain)
        } }
        .frame(minWidth: 560,minHeight: 480).onAppear { model.start() }
        .navigationSubtitle(model.notice)
        .toolbar {
            ToolbarItem {
                Button { showSubChats.toggle() } label: { Label("Sub-chats",systemImage: "bubble.left.and.bubble.right") }
                    .help("Topic sub-chats (inspect only)")
                    .popover(isPresented: $showSubChats,arrowEdge: .bottom) { SubChats(model: model) }
            }
            if model.snapshot.work.contains(where: { $0.active }) { ToolbarItem { ProgressView().controlSize(.small).help("Working on it") } }
            if model.nativeSelected && model.runtimeMode == .live { ToolbarItem { Button("Connect native device") { model.showEnrollment = true } } }
        }
            .sheet(isPresented: $model.showEnrollment,onDismiss: { model.bootstrapSecret = "" }) {
                VStack(alignment: .leading,spacing: 16) {
                    Text("Enroll Yorozu with the local Gateway").font(.headline)
                    Text("This is a separate app device, not a model-provider login. The Gateway is loopback only. Enter its bootstrap token/password privately here; never put it in chat. Only Yorozu's own device token and generated key are saved in Keychain. A new device approval may be required. Leave blank to reconnect an enrolled device.").fixedSize(horizontal: false,vertical: true)
                    SecureField("Gateway bootstrap secret (not saved)",text: $model.bootstrapSecret)
                    Text(model.notice).font(.caption).textSelection(.enabled)
                    HStack { Button("Cancel") { model.bootstrapSecret = ""; model.showEnrollment = false }.disabled(model.connecting)
                        Spacer(); Button(model.connecting ? "Connecting…" : "Connect") { Task { await model.enroll() } }.disabled(model.connecting) }
                }.padding(24).frame(width: 500)
            }
    }
}
final class Delegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationWillTerminate(_ notification: Notification) { MainActor.assumeIsolated { model?.stop() } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct ProjectXApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup(RuntimeMode.from(ProcessInfo.processInfo.environment).windowTitle) { ContentView(model: model).onAppear { delegate.model = model } }.defaultSize(width: 1180,height: 760)
    }
}
