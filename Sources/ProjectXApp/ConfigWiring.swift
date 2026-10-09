import AppKit
import ProjectXCore
import ServiceManagement

/// The settings the harness and the Engine read at the start of each route, task or extraction (#312).
final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = HarnessSettings()
    var value: HarnessSettings {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// config.toml at run time: role models from the harness's metadata, live reloads, notices, keep-awake and the login item.
extension AppModel {
    /// Runtime settings from the resolved config and the last model metadata read that succeeded.
    func harnessSettings() -> HarnessSettings {
        guard let resolved else { return HarnessSettings() }
        let c = resolved.config, meta = metadata ?? ([],nil)
        let m = resolved.models(meta.allowed,primary: meta.primary)
        var s = HarnessSettings()
        s.secretaryModel = m.secretary.id ?? ""; s.extractionModel = m.extraction.id ?? ""; s.workerModel = m.worker.id ?? ""; s.reviewModel = m.review.id ?? ""
        s.mcpServers = c.effectiveMCPServers; s.integrations = c.enabledIntegrations; s.yolo = c.general.yolo; s.configFile = configFile
        s.personalKnowledge = c.routing.personalKnowledge; s.selfTopic = c.routing.selfTopic
        s.filesRoot = filesRoot
        s.workspace = dataRoot.map { c.workspace.url(dataRoot: $0,isolated: isolatedData) }; s.restrict = c.workspace.restrict
        s.codingAgents = c.effectiveCodingAgents
        if let agentHost, let exe = Bundle.main.executablePath { s.agentCLI = (exe,agentHost.socket.path) }
        return s
    }
    /// Phone pushes (#320): `[notifications]` on with destination `phones`.
    var phoneAlerts: Bool { resolved.map { $0.config.notifications.enabled && $0.config.notifications.destination == .phones } ?? false }
    /// Reads the harness's model metadata, then recomputes the settings. A failed read keeps the last good metadata.
    @discardableResult func refreshModels() -> Task<Void,Never> {
        metadataAsked = Date()
        let task = Task { [harness] in
            guard let harness else { return }
            if let read = try? await harness.models() { metadata = read }
            settingsBox.value = harnessSettings()
        }
        metadataTask = task; return task
    }
    /// Before a message: waits for the read in flight and, while no read has succeeded, asks again at most every 30 s.
    func ensureModels() async {
        await metadataTask?.value
        guard metadata == nil, metadataAsked.map({ Date().timeIntervalSince($0) >= 30 }) ?? true else { return }
        await refreshModels().value
    }
    func watchConfig() {
        guard let configFile else { return }
        let watcher = ConfigWatcher(file: configFile,seen: configText) { [weak self] result in Task { @MainActor in await self?.reload(result) } }
        self.watcher = watcher; watcher.start()
    }
    /// A Settings change: read-modify-write through `Config.update`, applied at once; the watcher then sees the same file and skips it.
    func writeSettings(_ change: (inout Config) -> Void) {
        guard let configFile else { return }
        do { let file = try Config.update(configFile) { change(&$0) }; settingsError = nil; Task { await reload(.success(file)) } }
        catch { settingsError = error.localizedDescription }
    }
    func reload(_ result: Result<Config,ConfigError>) async {
        guard let configFile, let old = resolved else { return }
        let file: Config, next: ResolvedSettings
        do { file = try result.get(); next = try ResolvedSettings(file,environment: environment) }
        catch {
            // The last valid settings stay; one notice per distinct problem.
            let problem = error as? ConfigError ?? ConfigError(file: configFile.path,reason: error.localizedDescription)
            guard problem != lastConfigError else { return }
            lastConfigError = problem
            return await postInvalid(problem,body: "Settings not applied: \(problem.localizedDescription). The last valid settings stay in force.")
        }
        if file == fileConfig, lastConfigError == nil { return } // a Settings write the watcher saw again
        lastConfigError = nil; settingsError = nil
        let changed = fileConfig.map { file.securityChanges(from: $0) } ?? []
        fileConfig = file; resolved = next
        settingsBox.value = harnessSettings() // explicit choices, YOLO, routing hints and MCP now; automatic models after the read
        refreshModels()
        if !changed.isEmpty {
            let keys = changed.joined(separator: ", ")
            _ = try? await store?.message(role: "assistant",body: "Settings changed: \(keys)",kind: "acknowledgment",notice: Notice(.settingsChanged,["keys": keys]))
        }
        if runtimeMode == .live, next.config.relay.url != old.config.relay.url { await restartRelay() }
        else if runtimeMode == .live, let relay, (resolved ?? next).config.direct != old.config.direct { await relay.setDirect((resolved ?? next).config.direct) }
        await relay?.setAlerts(phoneAlerts)
        // After the awaits a newer reload may have run: apply the settings in force now, not this reload's.
        applySystem((resolved ?? next).config.general)
        if runtimeMode == .live, launched?.config.harness.kind == .hermes { recheck() } // the Hermes profiles may be out of date now
        if let launched {
            let h = (resolved ?? next).config.harness, l = launched.config.harness
            let pending = [("harness.kind",h.kind != l.kind),("harness.agent",h.agent != l.agent),("harness.transport",h.transport != l.transport),("harness.gateway_url",h.gatewayURL != l.gatewayURL),("harness.hermes_url",h.hermesURL != l.hermesURL)].filter(\.1).map(\.0)
            if !pending.isEmpty {
                let keys = pending.joined(separator: ", ")
                status = pending.contains("harness.kind") && working ? String(localized: "Relaunch Yorozu to apply: \(keys) (the harness switch waits until running work finishes)") : String(localized: "Relaunch Yorozu to apply: \(keys)")
            }
        }
    }
    /// A `config_invalid` failure notice naming the file, the line when known, the key and the reason.
    func postInvalid(_ problem: ConfigError, body: String) async {
        var params = ["file": problem.file,"reason": problem.reason]; params["line"] = problem.line.map(String.init); params["key"] = problem.key
        _ = try? await store?.message(role: "assistant",body: body,kind: "failure",notice: Notice(.configInvalid,params))
    }
    /// Keep-awake and the login item. Fixture and PROJECTX_DATA runs never touch the login item, nor does any run while
    /// another bundle with this bundle id (v1) is installed: `SMAppService.mainApp` could act on that bundle's item.
    /// Only an item this app registered itself (the marker file in the data root) is ever unregistered.
    func applySystem(_ general: Config.General) {
        if general.keepMacAwake, awake == nil { awake = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled,reason: "Keep Mac awake (Yorozu setting)") }
        else if !general.keepMacAwake, let activity = awake { ProcessInfo.processInfo.endActivity(activity); awake = nil }
        NSApp.appearance = switch general.appearance { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
        loginItemBlocker = nil
        guard runtimeMode != .fixture, environment["PROJECTX_DATA"] == nil, let marker = configFile?.deletingLastPathComponent().appendingPathComponent("login-item-registered") else {
            loginItemBlocker = String(localized: "Test fixture and PROJECTX_DATA runs leave the login item alone."); return
        }
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        if let id = Bundle.main.bundleIdentifier, let other = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).first(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path != me }) {
            loginItemBlocker = String(localized: "Off while another Yorozu with the same bundle id is installed (\(other.path)): macOS could act on that app's login item.")
            if general.startAtLogin { status = String(localized: "Start at login is off while another Yorozu with the same id is installed") }; return
        }
        let service = SMAppService.mainApp, fm = FileManager.default
        defer { loginItemStatus = service.status }
        do {
            switch (general.startAtLogin,service.status) {
            case (true,.notRegistered),(true,.notFound): try service.register(); fm.createFile(atPath: marker.path,contents: nil)
            case (false,.enabled),(false,.requiresApproval): if fm.fileExists(atPath: marker.path) { try service.unregister(); try? fm.removeItem(at: marker) }
            default: break
            }
            if general.startAtLogin, service.status == .requiresApproval { status = String(localized: "Start at login needs approval in System Settings › General › Login Items") }
        } catch { status = String(localized: "Start at login: \(error.localizedDescription)") }
    }
    /// The login item's status again, for Settings: approval in System Settings happens outside Yorozu.
    func refreshLoginItem() { if loginItemBlocker == nil, loginItemStatus != nil { loginItemStatus = SMAppService.mainApp.status } }
}
extension Task where Success == Void, Failure == Never {
    /// Waits for the task for at most `limit`; the task itself keeps running.
    func value(upTo limit: Duration) async {
        let (done,finish) = AsyncStream.makeStream(of: Void.self)
        Task<Void,Never> { await self.value; finish.finish() }
        let timer = Task<Void,Never> { try? await Task<Never,Never>.sleep(for: limit); finish.finish() }
        for await _ in done {}
        timer.cancel()
    }
}
