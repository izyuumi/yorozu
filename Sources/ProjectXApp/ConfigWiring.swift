import Foundation
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
        let c = resolved.config, meta = metadata ?? ([],nil), m = resolved.models(meta.allowed,primary: meta.primary)
        var s = HarnessSettings()
        s.secretaryModel = m.secretary.id ?? ""; s.extractionModel = m.extraction.id ?? ""; s.workerModel = m.worker.id ?? ""; s.reviewModel = m.review.id ?? ""
        s.codingModels = m.coding.compactMapValues(\.id)
        s.mcpServers = c.mcpServers; s.yolo = c.general.yolo; s.devRepo = c.harness.devRepoURL; s.configFile = configFile
        s.personalKnowledge = c.routing.personalKnowledge; s.selfTopic = c.routing.selfTopic
        return s
    }
    /// Reads the harness's model metadata, then recomputes the settings. A failed read keeps the last good metadata.
    @discardableResult func refreshModels() -> Task<Void,Never> {
        let task = Task { [harness] in
            guard let harness else { return }
            if let read = try? await harness.models() { metadata = read }
            settingsBox.value = harnessSettings()
        }
        metadataTask = task; return task
    }
    /// Before a message: waits for the launch read and, when it failed, retries it once.
    func ensureModels() async {
        await metadataTask?.value
        guard metadata == nil, !metadataRetried else { return }
        metadataRetried = true; await refreshModels().value
    }
    func watchConfig() {
        guard let configFile else { return }
        let watcher = ConfigWatcher(file: configFile,current: fileConfig) { [weak self] result in Task { @MainActor in await self?.reload(result) } }
        self.watcher = watcher; watcher.start()
    }
    private func reload(_ result: Result<Config,ConfigError>) async {
        guard let configFile, let old = resolved else { return }
        let file: Config, next: ResolvedSettings
        do { file = try result.get(); next = try ResolvedSettings(file,environment: environment) }
        catch {
            // The last valid settings stay; one notice per distinct problem.
            let problem = error as? ConfigError ?? ConfigError(file: configFile.path,reason: error.localizedDescription)
            guard problem != lastConfigError else { return }
            lastConfigError = problem
            var params = ["file": problem.file,"reason": problem.reason]; params["line"] = problem.line.map(String.init); params["key"] = problem.key
            _ = try? await store?.message(role: "assistant",body: "Settings not applied: \(problem.localizedDescription). The last valid settings stay in force.",kind: "failure",notice: Notice(.configInvalid,params))
            return
        }
        lastConfigError = nil
        let changed = fileConfig.map { file.securityChanges(from: $0) } ?? []
        fileConfig = file; resolved = next
        settingsBox.value = harnessSettings() // explicit choices, YOLO, routing hints and MCP now; automatic models after the read
        refreshModels()
        if !changed.isEmpty {
            let keys = changed.joined(separator: ", ")
            _ = try? await store?.message(role: "assistant",body: "Settings changed: \(keys)",kind: "acknowledgment",notice: Notice(.settingsChanged,["keys": keys]))
        }
        if runtimeMode == .live, next.config.relay.url != old.config.relay.url { await restartRelay(next.config.relay.url) }
        applySystem(next.config.general)
        if let launched {
            let h = next.config.harness, l = launched.config.harness
            let pending = [("harness.kind",h.kind != l.kind),("harness.agent",h.agent != l.agent),("harness.transport",h.transport != l.transport),("harness.gateway_url",h.gatewayURL != l.gatewayURL)].filter(\.1).map(\.0)
            if !pending.isEmpty { status = "Relaunch Yorozu to apply: " + pending.joined(separator: ", ") }
        }
    }
    /// Keep-awake and the login item. Fixture and PROJECTX_DATA runs never touch the login item.
    func applySystem(_ general: Config.General) {
        if general.keepMacAwake, awake == nil { awake = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled,reason: "Keep Mac awake (Yorozu setting)") }
        else if !general.keepMacAwake, let activity = awake { ProcessInfo.processInfo.endActivity(activity); awake = nil }
        guard runtimeMode != .fixture, environment["PROJECTX_DATA"] == nil else { return }
        let service = SMAppService.mainApp
        do {
            switch (general.startAtLogin,service.status) {
            case (true,.notRegistered),(true,.notFound): try service.register()
            case (false,.enabled),(false,.requiresApproval): try service.unregister()
            default: break
            }
            if general.startAtLogin, service.status == .requiresApproval { status = "Start at login needs approval in System Settings › General › Login Items" }
        } catch { status = "Start at login: \(error.localizedDescription)" }
    }
}
