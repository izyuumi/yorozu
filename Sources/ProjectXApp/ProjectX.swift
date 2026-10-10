import SwiftUI
import AppKit
import ProjectXCore
import ServiceManagement
import YorozuWire

@MainActor final class AppModel: ObservableObject {
    let runtimeMode = RuntimeMode.from(ProcessInfo.processInfo.environment)
    @Published var fixtureAcknowledged = false
    @Published var snapshot = Snapshot()
    /// The secretary is deciding how to handle a message (`Engine.routing`): the timeline shows the thinking bubble.
    @Published var routing = false
    /// The main thread's read cursor (`Store.readCursor`), moved here or by a phone's `read_state`.
    @Published var readCursor: String?
    @Published var draft = ""
    /// The message Reply quoted above the composer; the next send names it as `replyTo`.
    @Published var replyingTo: Message?
    /// The composer's files (#316), sent with the draft; `fileNotice` says why one was refused.
    @Published var files: [DraftFile] = []
    @Published var fileNotice: String?
    /// The popover's one-line status: startup progress or the last error, cleared by the next success.
    @Published var status: String? = String(localized: "Opening local workspace…") { didSet { statusDetail = nil } }
    /// The raw error behind a plain `status` (`showError`), as its tooltip.
    @Published var statusDetail: String?
    /// Set when the native transport was selected but this launch fell back to the CLI.
    @Published var nativeNotice: String?
    @Published var nativeNoticeDetail = ""
    /// The main harness in use ("OpenClaw Gateway · projectx", "Hermes Agent"); nil outside live mode.
    @Published var harnessLabel: String?
    /// The Mac's readiness (#317, SetupWiring.swift): the main harness's detection and Gateway `health`, a held switch and
    /// the file store; nil until the first check. A send does not clear it; a recheck does.
    @Published var readiness: Readiness?
    /// The setup window's step to show (a Fix… target); nil shows the first step not done.
    @Published var setupStep: String?
    /// Bumped to open the setup window; MenuBarHost's tracker holds `openWindow`.
    @Published var setupRequests = 0
    /// The Gateway client the live OpenClaw harness uses, for readiness and setup; nil otherwise.
    var gatewayRPC: GatewayRPC?
    var recheckTask: Task<Void,Never>?
    /// A recheck asked for while one ran: it runs once more when that one ends.
    var recheckAgain = false
    /// The newest failure row seen by the poll; a newer one triggers a recheck.
    var lastFailureID: String?
    /// Set at launch when a harness switch waits for running work (open question 9).
    var switchNotice: String?
    /// Why the file store (#316) could not open (a root inside a git checkout), raw: attachments are off this launch.
    var filesNotice: String?
    /// The file store's root, for `HarnessSettings.filesRoot`; nil without a store.
    var filesRoot: URL?
    /// The data root and whether it is isolated (`PROJECTX_DATA` or fixture mode), for the workspace default (#351).
    var dataRoot: URL?, isolatedData = false
    /// Runs coding agents for workers (#351), on `<data root>/agents.sock`; nil when it could not start.
    var agentHost: CodingAgentHost?
    /// Feedback for the enrollment form in Settings.
    @Published var enrollmentNotice = ""
    @Published var ready = false
    @Published var submitting = false
    @Published var bootstrapSecret = ""
    @Published var connecting = false
    /// `[harness] transport = "cli"` keeps the CLI transport; "native" selects the WebSocket client. Fixed for this launch.
    @Published private(set) var nativeSelected = false
    private var nativeClient: NativeGatewayClient?
    private(set) var engine: Engine?
    private var observation: Task<Void,Never>?
    /// The phone's way in (iOS 0.7): live mode only, and nil when it could not start.
    private(set) var relay: RelayHost?
    private var bridge: EngineBridge?
    @Published var relayStatus = RelayStatus()
    /// What paired phones show as the Mac's readiness (#317), kept across relay restarts; set with `publishReadiness`.
    private var phoneReadiness: ReadinessData?
    // Popover hooks, wired by MenuBarHost to AttentionCenter.
    /// Set by the host to bring a message into view; the timeline scrolls to it and clears it.
    @Published var focusMessageID: String?
    /// Set by the host from `popoverWillShow`/`popoverDidClose`; seen reports go out only while it is true.
    @Published var popoverShown = false
    /// The newest message the reader has seen at the bottom of the open popover.
    var onSeen: ((String) -> Void)?
    /// The open popover reached or left the newest message.
    var onBottomChanged: ((Bool) -> Void)?
    // config.toml (#312), applied in ConfigWiring.swift.
    let environment = ProcessInfo.processInfo.environment
    let settingsBox = SettingsBox()
    var configFile: URL?
    @Published var resolved: ResolvedSettings?
    /// Resolved at launch: transport, Gateway URL, agent and harness kind apply only from the next launch.
    var launched: ResolvedSettings?
    var fileConfig: Config?
    var watcher: ConfigWatcher?
    var store: Store?
    var harness: (any Harness)?
    var devicesFile: URL?
    @Published var lastConfigError: ConfigError?
    @Published var metadata: (allowed: [ModelInfo], primary: String?)?
    /// The last Settings write that failed, shown in Settings until the next one succeeds.
    @Published var settingsError: String?
    /// The Settings window's tab, so the popover's Connect… can open Harness.
    @Published var settingsTab = SettingsView.Tab.general
    /// The pair sheet in Settings › Devices, which the menu-bar menu's Pair a Client Device… also opens.
    @Published var pairingSheet = false
    /// Why `[general] global_shortcut` is not registered (unrecognized, or in use by another app); nil when it is or it is off.
    @Published var shortcutProblem: String?
    /// The login item as Settings shows it: its real status, or why this run leaves it alone.
    @Published var loginItemStatus: SMAppService.Status?
    @Published var loginItemBlocker: String?
    /// The Markdown memory folder in use, for Settings › Storage.
    var memoryFolder: URL?
    var metadataTask: Task<Void,Never>?
    /// When the model metadata was last asked for; with no metadata yet, a message asks again at most every 30 s.
    var metadataAsked: Date?
    /// The launch text of config.toml, so the watcher reports an edit made during launch.
    var configText: Data?
    private var relayRestart: Task<Void,Never>?
    /// The next start of a relay host that failed to start.
    private var relayRetry: Task<Void,Never>?
    var awake: NSObjectProtocol?
    // Jobs (#319), in JobsWiring.swift.
    var jobRunner: ScriptRunner?
    var jobScheduler: JobScheduler?
    var jobsWatcher: JobsWatcher?
    var jobsConsumer: Task<Void,Never>?
    var jobObservers: [(NotificationCenter, NSObjectProtocol)] = []
    var lastJobsError: ConfigError?
    /// The last valid job set, once the Engine and the scheduler hold it: Settings › Jobs refreshes on it.
    @Published var jobSpecs: [JobSpec] = []
    /// Topics bound to jobs, deleted ones included: their work never turns on the working indicator (open question 10).
    @Published var jobTopics = Set<String>()
    var working: Bool { snapshot.work.contains { $0.active && !jobTopics.contains($0.topicID) } }
    /// The main chat: everything but the messages that stay in a job's sub-chat.
    var timeline: [Message] { snapshot.messages.filter(\.onMainTimeline) }
    func start() {
        guard observation == nil else { return }
        observation = Task {
            do {
                let env = environment
                // Private app state: ~/Library/Application Support/<bundle id>; rebuildable index: ~/Library/Caches/<bundle id>.
                // User-owned Markdown memory: visible ~/Yorozu/memory (owner decision). Fixtures and PROJECTX_DATA keep all in one root.
                let fm = FileManager.default; let bundleID = Bundle.main.bundleIdentifier ?? "to.yumi.yorozu"
                let (root,support,isExplicit) = try Config.dataRoot(env,bundleID: bundleID), explicit = isExplicit ? root : nil
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
                memoryFolder = await memory.root
                try await memory.rebuild()
                // Bad note files are skipped, not fatal; say which, once per launch.
                let skipped = await memory.skipped
                if !skipped.isEmpty { let files = skipped.prefix(10).joined(separator: ", "); _ = try await store.message(role: "assistant",body: "Memory skipped \(skipped.count) oversized or unreadable note file(s): " + files,kind: "failure",notice: Notice(.memorySkipped,["count": "\(skipped.count)","files": files])) }
                // Visible attachments (#316): ~/Yorozu/files; fixtures and PROJECTX_DATA keep them in <data root>/files.
                var files: FileStore?
                do {
                    files = try FileStore(root: explicit != nil || runtimeMode == .fixture ? root.appendingPathComponent("files",isDirectory: true)
                                                                                            : fm.homeDirectoryForCurrentUser.appendingPathComponent("Yorozu/files",isDirectory: true),dataRoot: root)
                } catch { filesNotice = error.localizedDescription }
                filesRoot = files?.root
                dataRoot = root; isolatedData = explicit != nil || runtimeMode == .fixture
                // The workspace (#351) exists before any worker starts: Hermes's profile uses it as its terminal folder.
                if let w = harnessSettings().workspace { try? fm.createDirectory(at: w,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700]) }
                let box = settingsBox; box.value = harnessSettings()
                let harness: any Harness
                switch runtimeMode {
                case .fixture: harness = FixtureHarness(agent: resolved.config.harness.agent)
                case .live: harness = try await liveHarness(resolved,root: root,store: store)
                case .offline: harness = OfflineHarness(agent: resolved.config.harness.agent)
                }
                // Queued work resumes with the automatic models, unless the first metadata read takes more than 10 s.
                self.harness = harness; await refreshModels().value(upTo: .seconds(10))
                let engine = Engine(store: store,memory: memory,harness: harness,files: files,settings: { box.value }); self.engine = engine
                if runtimeMode != .offline {
                    let host = CodingAgentHost(socket: root.appendingPathComponent("agents.sock"),settings: { box.value },folder: { try await engine.agentFolder(task: $0) },alive: { await engine.agentTaskRunning($0) },emit: { try await engine.agentEvent($0) })
                    do { try host.start(); agentHost = host; box.value = harnessSettings() } catch { NSLog("Yorozu: coding agents are off this launch: %@",error.localizedDescription) }
                }
                await engine.resume()
                await startJobs(engine,root: root,scripts: explicit != nil || runtimeMode == .fixture ? root.appendingPathComponent("jobs",isDirectory: true) : fm.homeDirectoryForCurrentUser.appendingPathComponent("Yorozu/jobs",isDirectory: true))
                // Keys and device counters live as long as each other, so the device file stays in the support root whatever PROJECTX_DATA says.
                devicesFile = support.appendingPathComponent("relay-devices.json")
                if runtimeMode == .live { await startRelay(engine,url: resolved.config.relay.url) }
                status = nil; ready = true
                recheck()
                if !file.setup.done, lastConfigError == nil { openSetup() }
                applySystem(resolved.config.general)
                watchConfig()
                // Polls keep reading, but the UI hears only about a changed snapshot. The bridge hears every poll: it checks
                // the change sequence and the working and routing flags itself (read cursors and routing are not in the snapshot). A failed read says so
                // in the status line and backs off (0.7 s doubling to 30 s) until one succeeds.
                var failures = 0, notice: String?
                while !Task.isCancelled {
                    do {
                        let next = try await engine.snapshot()
                        if notice != nil { if status == notice { status = nil }; notice = nil; failures = 0 }
                        if next != snapshot { snapshot = next; noteFailures(next); let topics = Set(((try? await store.jobRecords()) ?? []).map(\.topicID)); if topics != jobTopics { jobTopics = topics } }
                        let routing = await engine.routing; if routing != self.routing { self.routing = routing }
                        let cursor = try await store.readCursor(thread: "main"); if cursor != readCursor { readCursor = cursor }
                        if let relay, let bridge { await bridge.publish(next,to: relay) }
                    } catch {
                        failures += 1; notice = String(localized: "Couldn't read the chat, retrying: \(error.localizedDescription)"); status = notice
                    }
                    try await Task.sleep(for: .milliseconds(failures == 0 ? 350 : min(350 << min(failures,7),30_000)))
                }
            } catch is CancellationError { }
            catch { showError(error); ready = false }
        }
    }
    /// `error` in the status line: a known setup cause in plain words with the raw text as the tooltip, else the raw text.
    func showError(_ error: Error) {
        let plain = PlainError.describe(error)
        status = plain.map { NoticeText.plain(cause: $0.cause,subject: $0.subject) ?? $0.title } ?? error.localizedDescription
        statusDetail = plain?.detail
    }
    /// The main harness from `[harness] kind` (`PROJECTX_HARNESS` overrides it), after that adapter's launch guard.
    /// Open question 9: a switch waits while work is active or uncertain, so that work stays on the harness it started on.
    private func liveHarness(_ resolved: ResolvedSettings,root: URL,store: Store) async throws -> any Harness {
        let h = resolved.config.harness, box = settingsBox
        let previous = try await store.lastHarness().flatMap(Config.HarnessKind.init(rawValue:)) ?? .openclaw
        var kind = h.kind
        if kind != previous, try await store.snapshot().work.contains(where: { $0.active || $0.state == "uncertain" }) { // suppressed too, until its stop is confirmed
            kind = previous
            switchNotice = String(localized: "Still on \(previous.rawValue): work started there is running. Relaunch Yorozu once it finishes to switch to \(h.kind.rawValue).")
        }
        let harness: any Harness
        switch kind {
        case .openclaw:
            // Native launch is NOT an escape from an inherited exec restriction.
            try GatewayRPC.enforceAttribution(environment)
            // Workers never run on the user's personal agent; an entry marked default is caught by readiness and setup.
            guard !OpenClawSetup.personal(h.agent,config: nil) else { throw ProjectError.blocked(OpenClawSetup.personalAgent) }
            nativeSelected = h.transport == .native
            let native = nativeSelected ? await connectNative(h.gatewayURL) : nil
            let rpc = GatewayRPC(native: native,audit: { try await store.requestReceipt($0) },target: h.gatewayURL); gatewayRPC = rpc
            harness = OpenClawHarness(workspace: root.appendingPathComponent("harness-workspaces"),agent: h.agent,rpc: rpc,settings: { box.value })
            harnessLabel = "OpenClaw Gateway · " + h.agent
        case .hermes:
            // Not ready still launches: messages are saved and the status line says what to fix (`recheck`).
            harness = try HermesHarness(url: h.hermesURL,agent: h.agent,audit: { try await store.requestReceipt($0) },settings: { box.value })
            harnessLabel = "Hermes Agent"
        }
        try await store.recordHarness(harness.id)
        return harness
    }
    /// The native client when its stored device token connects; otherwise nil, so this launch uses the CLI and says so.
    private func connectNative(_ target: String) async -> NativeGatewayClient? {
        do {
            let client = try NativeGatewayClient(target: target); nativeClient = client
            // Unenrolled: connecting would store a fresh key and fail. Unreachable: give up after 3 s, not the 15 s handshake.
            guard client.isEnrolled else { throw ProjectError.blocked(String(localized: "This Mac is not enrolled with the Gateway yet.")) }
            do { try await client.connect(timeout: .seconds(3)) } catch { await client.close(); throw error }
            return client
        } catch {
            nativeNotice = String(localized: "Native Gateway not connected · using the CLI this launch"); nativeNoticeDetail = error.localizedDescription
            return nil
        }
    }
    /// A relay that cannot start (Keychain, unreadable device file) leaves the Mac app running, says why in the pair sheet,
    /// and tries again every 30 s on the relay URL in force then.
    func startRelay(_ engine: Engine,url: String) async {
        guard let devicesFile else { return }
        relayRetry?.cancel(); relayRetry = nil
        do {
            let bridge = EngineBridge(engine: engine,mode: runtimeMode,scheduler: jobScheduler) { [weak self] in await self?.ensureModels() }
            let host = try RelayHost(backend: bridge,relayURL: url,devicesFile: devicesFile,direct: resolved?.config.direct ?? Config().direct,alerts: phoneAlerts)
            self.bridge = bridge; relay = host
            Task { for await status in host.status where relay === host { relayStatus = status } }
            if let phoneReadiness { await host.publishReadiness(phoneReadiness) }
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
    /// The Mac readiness model (#317) calls this on every change (`ReadinessData(readiness)`); phones get it now and after each handshake.
    func publishReadiness(_ readiness: ReadinessData) async {
        phoneReadiness = readiness
        await relay?.publishReadiness(readiness)
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
    func stop() { observation?.cancel(); stopJobs(); agentHost?.stop(); relayRetry?.cancel(); watcher?.stop(); bootstrapSecret = ""; if let engine { Task { await engine.shutdown() } }; if let nativeClient { Task { await nativeClient.close() } }; if let relay { Task { await relay.stop() } } }
    /// This Mac holds a Gateway device token (Keychain), for Settings › Advanced.
    var nativeEnrolled: Bool { nativeClient?.isEnrolled ?? false }
    func enroll() async {
        guard let nativeClient, !connecting else { return }
        connecting = true; let secret = bootstrapSecret; bootstrapSecret = ""
        defer { connecting = false }
        do {
            try await nativeClient.connect(bootstrapSecret: secret.isEmpty ? nil : secret)
            // The harness took its transport at launch, so a fallback launch keeps the CLI until the next one.
            enrollmentNotice = nativeNotice == nil ? String(localized: "Native Gateway connected · model response not yet verified") : String(localized: "Native Gateway connected · Yorozu uses it from the next launch")
            // A fallback launch stays on the CLI: say so, and don't keep an unused client redialing.
            if nativeNotice != nil { nativeNotice = String(localized: "Native Gateway enrolled · quit and reopen Yorozu to use it"); await nativeClient.close() }
        } catch { enrollmentNotice = error.localizedDescription }
    }
    func send() async {
        guard let engine, !submitting, runtimeMode.permitsInput(fixtureAcknowledged: fixtureAcknowledged) else { return }
        submitting = true; defer { submitting = false }
        let text = draft, sent = files, reply = replyingTo?.id
        if readiness.map({ $0.state != .ready }) ?? false { recheck() }
        await ensureModels()
        // Downscaling reads and re-encodes images, so it runs off the main actor; its scratch copies go once the Engine has
        // copied them into the file store (or failed).
        let prepared: (pending: [PendingFile], scratch: [URL])
        do { prepared = try await Task.detached { try DraftFile.prepare(sent) }.value; fileNotice = nil }
        catch { fileNotice = error.localizedDescription; return }
        defer { prepared.scratch.forEach(DraftFile.discard) }
        do {
            try await engine.send(text,attachments: prepared.pending,replyTo: reply)
            if draft == text { draft = "" }
            if replyingTo?.id == reply { replyingTo = nil }
            let ids = Set(sent.map(\.id)); files.removeAll { ids.contains($0.id) }
            sent.filter(\.temporary).forEach { DraftFile.discard($0.url) }
            status = nil; snapshot = try await engine.snapshot()
        }
        catch { showError(error); recheck() }
    }
    /// Where a stored attachment is now, or nil when it is gone (deleted in Finder).
    func attachmentURL(_ file: Attachment) async -> URL? {
        guard let url = await engine?.attachmentURL(file.id), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    /// The popover showed this message at its bottom: the main read cursor moves to it (forward only, in the Store); the
    /// poll picks it up into `readCursor`, and the relay's next publish sends it to phones as `read_state`.
    func markRead(_ id: String) {
        guard id != readCursor, let store else { return }
        Task { _ = try? await store.markRead(thread: "main", message: id) }
    }
    /// Chat search for the popover's ⌘F bar; the caller keeps only main-timeline message hits (open question 10).
    func search(_ query: String,limit: Int,offset: Int = 0) async throws -> (hits: [SearchHit], total: Int) {
        guard let engine else { return ([],0) }
        return try await engine.search(query,limit: limit,offset: offset)
    }
    /// `[general] send_key`, read at each key press so a config edit applies at once.
    var sendKey: Config.SendKey { resolved?.config.general.sendKey ?? .cmdEnter }
}
@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var host: MenuBarHost?
    func applicationDidFinishLaunching(_ notification: Notification) { host = MenuBarHost(model: model); model.start() }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    /// A menu-bar host: closing Settings leaves the engine, relay and model running until Quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
/// Started by `Main` unless the binary runs as `Yorozu setup …` (SetupCLI.swift).
struct ProjectXApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    var body: some Scene {
        // Suppressed too: with the setup window suppressed, SwiftUI would otherwise open Settings at launch.
        Settings { SettingsView(model: delegate.model) }
            .defaultLaunchBehavior(.suppressed)
        // Opened only by `AppModel.openSetup`: at a launch before setup is done, by Run Setup Again… and by Fix….
        // The sub-chats (Activities.swift), opened from the popover.
        Window("Activities", id: ActivitiesView.id) { ActivitiesView(model: delegate.model) }
            .defaultLaunchBehavior(.suppressed)
        Window("Set up Yorozu", id: SetupWindow.id) { SetupWindow(model: delegate.model) }
            .windowResizability(.contentSize)
            .defaultLaunchBehavior(.suppressed)
    }
}
extension ReadinessData {
    /// Core's readiness for phones: the overall state, the count and each item's title, severity and fix hint.
    init(_ r: Readiness) {
        let state: State = switch r.state { case .ready: .ready; case .attention: .attention; case .blocked: .blocked }
        self.init(state: state,count: r.count,items: r.items.map { Item(id: $0.id,title: $0.title,severity: Item.Severity(rawValue: $0.severity.rawValue)!,fix: $0.fix?.hint) })
    }
}
