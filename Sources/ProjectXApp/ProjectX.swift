import SwiftUI
import AppKit
import ProjectXCore

@MainActor final class AppModel: ObservableObject {
    let runtimeMode = RuntimeMode.from(ProcessInfo.processInfo.environment)
    @Published var fixtureAcknowledged = false
    @Published var snapshot = Snapshot()
    @Published var draft = ""
    /// The popover's one-line status: startup progress or the last error, cleared by the next success.
    @Published var status: String? = "Opening local workspace…"
    /// Set when the native transport was selected but this launch fell back to the CLI.
    @Published var nativeNotice: String?
    @Published var nativeNoticeDetail = ""
    /// Feedback for the enrollment form in Settings.
    @Published var enrollmentNotice = ""
    @Published var ready = false
    @Published var submitting = false
    @Published var bootstrapSecret = ""
    @Published var connecting = false
    /// `PROJECTX_TRANSPORT=cli` keeps the CLI transport; anything else selects the native WebSocket client.
    let nativeSelected = ProcessInfo.processInfo.environment["PROJECTX_TRANSPORT"] != "cli"
    private var nativeClient: NativeGatewayClient?
    private var engine: Engine?
    private var observation: Task<Void,Never>?
    /// Assistant Markdown parsed once per message id; message bodies never change after insert.
    private var parsed: [String: AttributedString] = [:]
    /// The phone's way in (iOS 0.6.0): live mode only, and nil when it could not start.
    private(set) var relay: RelayHost?
    private var bridge: EngineBridge?
    @Published var relayStatus = RelayStatus()
    var working: Bool { snapshot.work.contains { $0.active } }
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
                // Bad note files are skipped, not fatal; say which, once per launch.
                let skipped = await memory.skipped
                if !skipped.isEmpty { let files = skipped.prefix(10).joined(separator: ", "); _ = try await store.message(role: "assistant",body: "Memory skipped \(skipped.count) oversized or unreadable note file(s): " + files,kind: "failure",notice: Notice(.memorySkipped,["count": "\(skipped.count)","files": files])) }
                let harness: any Harness
                switch runtimeMode.rawValue {
                case "fixture": harness = FixtureHarness()
                case "live":
                    // Native launch is NOT an escape from an inherited exec restriction.
                    try GatewayRPC.enforceAttribution(env)
                    guard env["PROJECTX_AGENT"] == nil || env["PROJECTX_AGENT"] == "projectx" else { throw ProjectError.blocked("R1 uses only the dedicated projectx agent, never personal agents.") }
                    let native = nativeSelected ? await connectNative(env["PROJECTX_GATEWAY_URL"] ?? "ws://127.0.0.1:18789") : nil
                    var live = OpenClawHarness(workspace: root.appendingPathComponent("harness-workspaces"),agent: "projectx",secretaryModel: env["PROJECTX_SECRETARY_MODEL"] ?? "openai-pool/gpt-6-astra",workerModel: env["PROJECTX_MODEL"] ?? "openai-pool/gpt-6-sol",reviewModel: env["PROJECTX_REVIEW_MODEL"] ?? "openai-pool/gpt-6-sol",rpc: GatewayRPC(native: native,audit: { try await store.gatewayReceipt($0) }))
                    // R2 coding workers (Claude Code / Codex). The dev repo holds the OWNER_DECISIONS.md they may read.
                    live.claudeModel = env["PROJECTX_CLAUDE_MODEL"] ?? live.claudeModel; live.codexModel = env["PROJECTX_CODEX_MODEL"] ?? live.codexModel
                    live.repo = URL(fileURLWithPath: env["PROJECTX_DEV_REPO"] ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Projects/PROJECTX").path,isDirectory: true)
                    live.mcpList = root.appendingPathComponent("mcp-servers.json")
                    harness = live
                default: harness = OfflineHarness()
                }
                let engine = Engine(store: store,memory: memory,harness: harness); self.engine = engine
                await engine.resume()
                // Keys and device counters live as long as each other, so the device file stays in the support root whatever PROJECTX_DATA says.
                if runtimeMode == .live { await startRelay(engine,url: env["PROJECTX_RELAY_URL"] ?? "wss://relay.yumi.to",devices: support.appendingPathComponent("relay-devices.json")) }
                status = nil; ready = true
                // Polls keep reading, but the UI and the relay hear only about a changed snapshot.
                var relayed: Snapshot?
                while !Task.isCancelled {
                    let next = try await engine.snapshot()
                    if next != snapshot { snapshot = next }
                    if next != relayed, let relay, let bridge { relayed = next; await bridge.publish(next,to: relay) }
                    try await Task.sleep(for: .milliseconds(350))
                }
            } catch is CancellationError { }
            catch { status = error.localizedDescription; ready = false }
        }
    }
    /// The native client when its stored device token connects; otherwise nil, so this launch uses the CLI and says so.
    private func connectNative(_ target: String) async -> NativeGatewayClient? {
        do {
            let client = try NativeGatewayClient(target: target); nativeClient = client
            // Unenrolled: connecting would store a fresh key and fail. Unreachable: give up after 3 s, not the 15 s handshake.
            guard client.isEnrolled else { throw ProjectError.blocked("This Mac is not enrolled with the Gateway yet.") }
            do { try await client.connect(timeout: .seconds(3)) } catch { await client.close(); throw error }
            return client
        } catch {
            nativeNotice = "Native Gateway not connected · using the CLI this launch"; nativeNoticeDetail = error.localizedDescription
            return nil
        }
    }
    /// A relay that cannot start (Keychain, unreadable device file) leaves the Mac app running and says why in the pair sheet.
    private func startRelay(_ engine: Engine,url: String,devices: URL) async {
        do {
            let bridge = EngineBridge(engine: engine,mode: runtimeMode)
            let host = try RelayHost(backend: bridge,relayURL: url,devicesFile: devices)
            self.bridge = bridge; relay = host
            Task { for await status in host.status { relayStatus = status } }
            await host.start()
        } catch { relayStatus.state = error.localizedDescription }
    }
    func stop() { observation?.cancel(); bootstrapSecret = ""; if let engine { Task { await engine.shutdown() } }; if let nativeClient { Task { await nativeClient.close() } }; if let relay { Task { await relay.stop() } } }
    func enroll() async {
        guard let nativeClient, !connecting else { return }
        connecting = true; let secret = bootstrapSecret; bootstrapSecret = ""
        defer { connecting = false }
        do {
            try await nativeClient.connect(bootstrapSecret: secret.isEmpty ? nil : secret)
            // The harness took its transport at launch, so a fallback launch keeps the CLI until the next one.
            enrollmentNotice = nativeNotice == nil ? "Native Gateway connected · model response not yet verified" : "Native Gateway connected · Yorozu uses it from the next launch"
            nativeNotice = nil
        } catch { enrollmentNotice = error.localizedDescription }
    }
    func send() async {
        guard let engine, !submitting, runtimeMode.permitsInput(fixtureAcknowledged: fixtureAcknowledged) else { return }
        submitting = true; defer { submitting = false }
        let text = draft
        do { try await engine.send(text); if draft == text { draft = "" }; status = nil; snapshot = try await engine.snapshot() }
        catch { status = error.localizedDescription }
    }
    /// User text stays verbatim; assistant Markdown is parsed on first display only.
    func text(_ message: Message) -> AttributedString {
        if message.role == "user" { return AttributedString(message.body) }
        if let hit = parsed[message.id] { return hit }
        let value = AttributedString(chatMarkdown: message.body); parsed[message.id] = value; return value
    }
}
struct MessageCard: View {
    let message: Message
    let text: AttributedString
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
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading)
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
                    ForEach(model.snapshot.messages) { MessageCard(message: $0,text: model.text($0)).id($0.id) }
                }.padding() }
                .onChange(of: model.snapshot.messages.count) { _,_ in if let last = model.snapshot.messages.last { reader.scrollTo(last.id,anchor: .bottom) } }
            }
            Divider()
            HStack(alignment: .bottom) {
                // A fifth of the popover's height, so the timeline keeps the rest.
                TextEditor(text: $model.draft).font(.body).containerRelativeFrame(.vertical) { height,_ in height / 5 }.accessibilityLabel(model.runtimeMode == .fixture ? "Synthetic test message, no AI" : "Main conversation message").disabled(!model.runtimeMode.permitsInput(fixtureAcknowledged: model.fixtureAcknowledged))
                Button(model.runtimeMode.sendLabel) { Task { await model.send() } }.keyboardShortcut(.return,modifiers: .command).buttonStyle(.borderedProminent)
                    .disabled(!model.ready || model.submitting || !model.runtimeMode.permitsInput(fixtureAcknowledged: model.fixtureAcknowledged) || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding()
            Text("⌘ Return to send · Return for a new line").font(.caption2).foregroundStyle(.secondary).padding(.bottom,6)
        }
    }
}
/// The popover's content: header menu, mode banner, notices, then the main chat. It fills whatever the popover gives it.
struct PopoverContent: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void
    var body: some View {
        VStack(alignment: .leading,spacing: 0) {
            HStack {
                Text(model.runtimeMode.windowTitle).font(.headline)
                Spacer()
                if model.working { ProgressView().controlSize(.small).help("Working on it") }
                Menu {
                    Button("Settings…",action: openSettings).keyboardShortcut(",")
                    Divider()
                    Button("Quit Yorozu") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Yorozu menu")
            }.padding(.horizontal).padding(.vertical,8)
            Divider()
            if model.runtimeMode != .live {
                VStack(alignment: .leading,spacing: 6) {
                    Label(model.runtimeMode.bannerTitle,systemImage: "exclamationmark.triangle.fill").font(.headline)
                    Text(model.runtimeMode.explanation).font(.callout).fixedSize(horizontal: false,vertical: true)
                    if model.runtimeMode == .fixture && !model.fixtureAcknowledged {
                        Button("I understand: enable synthetic TEST input") { model.fixtureAcknowledged = true }
                            .accessibilityIdentifier("acknowledgeSyntheticFixture")
                    }
                }.frame(maxWidth: .infinity,alignment: .leading).padding(12)
                    .background(Color.orange.opacity(0.18)).accessibilityElement(children: .contain)
            }
            if let notice = model.nativeNotice {
                HStack {
                    Text(notice).lineLimit(1).truncationMode(.tail).help(model.nativeNoticeDetail)
                    Spacer()
                    Button("Connect…",action: openSettings).buttonStyle(.link)
                }.font(.callout).padding(.horizontal).padding(.vertical,6)
            }
            if let status = model.status {
                Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(status)
                    .textSelection(.enabled).padding(.horizontal).padding(.vertical,6)
            }
            MainChat(model: model)
        }
    }
}
@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var host: MenuBarHost?
    func applicationDidFinishLaunching(_ notification: Notification) { host = MenuBarHost(model: model); model.start() }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    /// A menu-bar host: closing Settings leaves the engine, relay and model running until Quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main struct ProjectXApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    var body: some Scene {
        Settings { SettingsView(model: delegate.model) }
    }
}
