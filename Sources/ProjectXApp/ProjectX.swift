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
    /// The main harness in use ("OpenClaw Gateway · projectx", "Hermes Agent 0.21.6"); nil outside live mode.
    @Published var harnessLabel: String?
    /// What is wrong with the harness (not ready, untested version, a held switch); a send does not clear it.
    @Published var harnessNotice: String?
    /// Set at launch when a harness switch waits for running work (open question 9).
    var switchNotice: String?
    /// Feedback for the enrollment form in Settings.
    @Published var enrollmentNotice = ""
    @Published var ready = false
    @Published var submitting = false
    @Published var bootstrapSecret = ""
    @Published var connecting = false
    /// `[harness] transport = "cli"` keeps the CLI transport; "native" selects the WebSocket client. Fixed for this launch.
    @Published private(set) var nativeSelected = false
    private var nativeClient: NativeGatewayClient?
    private var engine: Engine?
    private var observation: Task<Void,Never>?
    /// Assistant Markdown parsed once per message id; message bodies never change after insert.
    private var parsed: [String: AttributedString] = [:]
    /// The phone's way in (iOS 0.6.0): live mode only, and nil when it could not start.
    private(set) var relay: RelayHost?
    private var bridge: EngineBridge?
    /// The snapshot the relay last heard about; nil makes the poll loop publish to a new relay.
    private var relayed: Snapshot?
    @Published var relayStatus = RelayStatus()
    // config.toml (#312), applied in ConfigWiring.swift.
    let environment = ProcessInfo.processInfo.environment
    let settingsBox = SettingsBox()
    var configFile: URL?
    var resolved: ResolvedSettings?
    /// Resolved at launch: transport, Gateway URL, agent and harness kind apply only from the next launch.
    var launched: ResolvedSettings?
    var fileConfig: Config?
    var watcher: ConfigWatcher?
    var store: Store?
    var harness: (any Harness)?
    var devicesFile: URL?
    var lastConfigError: ConfigError?
    var metadata: (allowed: [ModelInfo], primary: String?)?
    var metadataTask: Task<Void,Never>?
    /// When the model metadata was last asked for; with no metadata yet, a message asks again at most every 30 s.
    var metadataAsked: Date?
    /// The launch text of config.toml, so the watcher reports an edit made during launch.
    var configText: Data?
    private var relayRestart: Task<Void,Never>?
    /// The next start of a relay host that failed to start.
    private var relayRetry: Task<Void,Never>?
    var awake: NSObjectProtocol?
    var working: Bool { snapshot.work.contains { $0.active } }
    func start() {
        guard observation == nil else { return }
        observation = Task {
            do {
                let env = environment
                // Private app state: ~/Library/Application Support/<bundle id>; rebuildable index: ~/Library/Caches/<bundle id>.
                // User-owned Markdown memory: visible ~/Yorozu/memory (owner decision). Fixtures and PROJECTX_DATA keep all in one root.
                let fm = FileManager.default; let bundleID = Bundle.main.bundleIdentifier ?? "to.yumi.yorozu"
                let explicit = env["PROJECTX_DATA"].map { URL(fileURLWithPath: $0,isDirectory: true) }
                let support = try fm.url(for: .applicationSupportDirectory,in: .userDomainMask,appropriateFor: nil,create: true).appendingPathComponent(bundleID,isDirectory: true)
                let root = explicit ?? (runtimeMode == .fixture ? support.appendingPathComponent("Fixture",isDirectory: true) : support)
                // An unreadable or invalid file runs this launch on the code defaults plus the environment and is left as it is;
                // the watcher still starts, so fixing the file applies.
                let configFile = Config.url(in: root); var text: Data?, file = Config()
                do { let data = try Config.read(configFile); text = data; file = try Config.parse(String(decoding: data,as: UTF8.self),file: configFile) }
                catch { lastConfigError = error as? ConfigError ?? ConfigError(file: configFile.path,reason: error.localizedDescription) }
                let resolved = try ResolvedSettings(file,environment: env)
                self.configFile = configFile; configText = text; fileConfig = file; self.resolved = resolved; launched = resolved
                let store = try Store(root: root); self.store = store
                if let problem = lastConfigError { await postInvalid(problem,body: "Settings not applied: \(problem.localizedDescription). Yorozu runs on its default settings until the file is fixed.") }
                let memory = explicit != nil || runtimeMode == .fixture ? try MemoryStore(dataRoot: root) : try MemoryStore(
                    root: fm.homeDirectoryForCurrentUser.appendingPathComponent("Yorozu/memory",isDirectory: true),
                    index: try fm.url(for: .cachesDirectory,in: .userDomainMask,appropriateFor: nil,create: true).appendingPathComponent(bundleID + "/memory-index.sqlite"))
                try await memory.rebuild()
                // Bad note files are skipped, not fatal; say which, once per launch.
                let skipped = await memory.skipped
                if !skipped.isEmpty { let files = skipped.prefix(10).joined(separator: ", "); _ = try await store.message(role: "assistant",body: "Memory skipped \(skipped.count) oversized or unreadable note file(s): " + files,kind: "failure",notice: Notice(.memorySkipped,["count": "\(skipped.count)","files": files])) }
                let box = settingsBox; box.value = harnessSettings()
                let harness: any Harness
                switch runtimeMode {
                case .fixture: harness = FixtureHarness()
                case .live: harness = try await liveHarness(resolved,root: root,store: store)
                case .offline: harness = OfflineHarness()
                }
                // Queued work resumes with the automatic models, unless the first metadata read takes more than 10 s.
                self.harness = harness; await refreshModels().value(upTo: .seconds(10))
                let engine = Engine(store: store,memory: memory,harness: harness,settings: { box.value }); self.engine = engine
                await engine.resume()
                // Keys and device counters live as long as each other, so the device file stays in the support root whatever PROJECTX_DATA says.
                devicesFile = support.appendingPathComponent("relay-devices.json")
                if runtimeMode == .live { await startRelay(engine,url: resolved.config.relay.url) }
                status = nil; ready = true
                Task { await checkHarness() }
                applySystem(resolved.config.general)
                watchConfig()
                // Polls keep reading, but the UI and the relay hear only about a changed snapshot. A failed read says so
                // in the status line and backs off (0.7 s doubling to 30 s) until one succeeds.
                var failures = 0, notice: String?
                while !Task.isCancelled {
                    do {
                        let next = try await engine.snapshot()
                        if notice != nil { if status == notice { status = nil }; notice = nil; failures = 0 }
                        if next != snapshot { snapshot = next }
                        if next != relayed, let relay, let bridge { relayed = next; await bridge.publish(next,to: relay) }
                    } catch {
                        failures += 1; notice = "Couldn't read the chat, retrying: \(error.localizedDescription)"; status = notice
                    }
                    try await Task.sleep(for: .milliseconds(failures == 0 ? 350 : min(350 << min(failures,7),30_000)))
                }
            } catch is CancellationError { }
            catch { status = error.localizedDescription; ready = false }
        }
    }
    /// The main harness from `[harness] kind` (`PROJECTX_HARNESS` overrides it), after that adapter's launch guard.
    /// Open question 9: a switch waits while work is active or uncertain, so that work stays on the harness it started on.
    private func liveHarness(_ resolved: ResolvedSettings,root: URL,store: Store) async throws -> any Harness {
        let h = resolved.config.harness, box = settingsBox
        let previous = try await store.lastHarness().flatMap(Config.HarnessKind.init(rawValue:)) ?? .openclaw
        var kind = h.kind
        if kind != previous, try await store.snapshot().work.contains(where: { !$0.suppressed && ($0.active || $0.state == "uncertain") }) {
            kind = previous
            switchNotice = "Still on \(previous.rawValue): work started there is running. Relaunch Yorozu once it finishes to switch to \(h.kind.rawValue)."
        }
        let harness: any Harness
        switch kind {
        case .openclaw:
            // Native launch is NOT an escape from an inherited exec restriction.
            try GatewayRPC.enforceAttribution(environment)
            guard h.agent == "projectx" else { throw ProjectError.blocked("\(resolved.environment["harness.agent"] ?? "[harness] agent in config.toml") is \"\(h.agent)\"; this build runs only on the dedicated projectx agent, never personal agents. Set it to \"projectx\".") }
            nativeSelected = h.transport == .native
            let native = nativeSelected ? await connectNative(h.gatewayURL) : nil
            harness = OpenClawHarness(workspace: root.appendingPathComponent("harness-workspaces"),agent: h.agent,rpc: GatewayRPC(native: native,audit: { try await store.requestReceipt($0) },target: h.gatewayURL),settings: { box.value })
            harnessLabel = "OpenClaw Gateway · " + h.agent
        case .hermes:
            // Not ready still launches: messages are saved and the status line says what to fix (`checkHarness`).
            harness = try HermesHarness(url: h.hermesURL,audit: { try await store.requestReceipt($0) },settings: { box.value })
            harnessLabel = "Hermes Agent"
        }
        try await store.recordHarness(harness.id)
        return harness
    }
    /// The harness's readiness for the status line: Hermes's read-only check (problems, then an untested-version
    /// warning), plus a held harness switch. Runs at launch and before each message while something is wrong.
    func checkHarness() async {
        var notes = [switchNotice].compactMap { $0 }
        if let hermes = harness as? HermesHarness {
            let r = await hermes.readiness()
            harnessLabel = "Hermes Agent" + (r.version.map { " " + $0 } ?? "")
            notes += r.ready ? r.warnings : ["Hermes is not ready: " + r.problems.joined(separator: " ")]
        }
        harnessNotice = notes.isEmpty ? nil : notes.joined(separator: " ")
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
    /// A relay that cannot start (Keychain, unreadable device file) leaves the Mac app running, says why in the pair sheet,
    /// and tries again every 30 s on the relay URL in force then.
    func startRelay(_ engine: Engine,url: String) async {
        guard let devicesFile else { return }
        relayRetry?.cancel(); relayRetry = nil
        do {
            let bridge = EngineBridge(engine: engine,mode: runtimeMode) { [weak self] in await self?.ensureModels() }
            let host = try RelayHost(backend: bridge,relayURL: url,devicesFile: devicesFile)
            self.bridge = bridge; relay = host; relayed = nil
            Task { for await status in host.status where relay === host { relayStatus = status } }
            await host.start()
        } catch {
            relayStatus.state = error.localizedDescription
            relayRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, relay == nil, let url = resolved?.config.relay.url else { return }
                await startRelay(engine,url: url)
            }
        }
    }
    /// A new relay URL: the old host stops and a fresh one dials the new relay with the same keys and devices.
    /// Restarts run one after another, each dialing the relay URL in force once the old host has stopped, so quick edits leave one relay.
    func restartRelay() async {
        let previous = relayRestart
        let task = Task {
            await previous?.value
            guard let engine else { return }
            relayRetry?.cancel()
            let old = relay; relay = nil; bridge = nil
            await old?.stop()
            guard let url = resolved?.config.relay.url else { return }
            await startRelay(engine,url: url)
        }
        relayRestart = task; await task.value
    }
    func stop() { observation?.cancel(); relayRetry?.cancel(); watcher?.stop(); bootstrapSecret = ""; if let engine { Task { await engine.shutdown() } }; if let nativeClient { Task { await nativeClient.close() } }; if let relay { Task { await relay.stop() } } }
    func enroll() async {
        guard let nativeClient, !connecting else { return }
        connecting = true; let secret = bootstrapSecret; bootstrapSecret = ""
        defer { connecting = false }
        do {
            try await nativeClient.connect(bootstrapSecret: secret.isEmpty ? nil : secret)
            // The harness took its transport at launch, so a fallback launch keeps the CLI until the next one.
            enrollmentNotice = nativeNotice == nil ? "Native Gateway connected · model response not yet verified" : "Native Gateway connected · Yorozu uses it from the next launch"
            // A fallback launch stays on the CLI: say so, and don't keep an unused client redialing.
            if nativeNotice != nil { nativeNotice = "Native Gateway enrolled · quit and reopen Yorozu to use it"; await nativeClient.close() }
        } catch { enrollmentNotice = error.localizedDescription }
    }
    func send() async {
        guard let engine, !submitting, runtimeMode.permitsInput(fixtureAcknowledged: fixtureAcknowledged) else { return }
        submitting = true; defer { submitting = false }
        let text = draft
        if harnessNotice != nil { Task { await checkHarness() } }
        await ensureModels()
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
                if let label = model.harnessLabel { Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
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
            if let notice = model.harnessNotice {
                Text(notice).font(.callout).foregroundStyle(.orange).lineLimit(2).truncationMode(.tail).help(notice)
                    .textSelection(.enabled).padding(.horizontal).padding(.vertical,6)
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
