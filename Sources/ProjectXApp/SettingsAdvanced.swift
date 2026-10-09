import AppKit
import ProjectXCore
import SwiftUI

/// Settings › Storage: the memory and files folders with their sizes, measured off the main actor, and, with Advanced
/// settings on, what this install runs on.
struct StorageSettings: View {
    @ObservedObject var model: AppModel
    /// Folder → bytes on disk; a missing folder has no entry once measured.
    @State private var sizes: [URL: Int64] = [:]
    @State private var measured = false

    private var files: URL? { model.memoryFolder?.deletingLastPathComponent().appendingPathComponent("files", isDirectory: true) }

    var body: some View {
        Form {
            Section {
                row("Memory", model.memoryFolder)
                row("Files", files)
            } footer: {
                Text("Memory is plain Markdown you own; edit it with any app.").foregroundStyle(.secondary)
            }
            if model.config.general.showAdvanced { AboutInstallSection(model: model) }
        }
        .settingsForm()
        .task(id: model.memoryFolder) {
            var found: [URL: Int64] = [:]
            for folder in [model.memoryFolder, files].compactMap({ $0 }) { found[folder] = await Self.size(folder) }
            guard !Task.isCancelled else { return }
            sizes = found; measured = true
        }
    }

    @ViewBuilder private func row(_ title: LocalizedStringKey, _ folder: URL?) -> some View {
        LabeledContent {
            if let folder, let size = sizes[folder] {
                Text(size.formatted(.byteCount(style: .file)))
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            } else if measured || folder == nil {
                Text("Not created yet").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        } label: {
            Text(title)
            if let folder { Text(tildePath(folder)).textSelection(.enabled) }
        }
    }

    /// Bytes allocated under `folder`, or nil when it does not exist or the walk was cancelled. Runs off the main actor.
    @concurrent nonisolated static func size(_ folder: URL) async -> Int64? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        var total: Int64 = 0
        for case let file as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) ?? NSEnumerator() {
            if Task.isCancelled { return nil }
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Settings › Harness (only while General › Show Advanced settings is on): the main harness, its connection and the
/// Gateway enrollment, and per-role models.
struct HarnessSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var gateway = ""
    @State private var hermes = ""
    @State private var enrolled = false
    /// A harness switch waiting for the user's confirmation.
    @State private var switchTo: Config.HarnessKind?

    var body: some View {
        let config = model.config, launched = model.launched?.config.harness
        Form {
            ConfigProblems(model: model)
            Section("Harness connection") {
                let locked = model.override("harness.kind")
                Picker(selection: Binding(get: { config.harness.kind }, set: { if $0 != config.harness.kind { switchTo = $0 } })) {
                    ForEach(Config.HarnessKind.allCases, id: \.self) { Text(Self.harnessTitle($0)).tag($0) }
                } label: {
                    Text("Main harness")
                    if let note = overrideNote(locked) { note }
                    else if let launched, launched.kind != config.harness.kind { Text("Relaunch to apply.") }
                    else { Text("Answers every message and runs the workers.") }
                }.disabled(locked != nil)
                if config.harness.kind == .openclaw {
                    Picker(selection: model.setting(\.harness.transport)) {
                        Text("Native (WebSocket)").tag(Config.Transport.native)
                        Text("Command line").tag(Config.Transport.cli)
                    } label: {
                        Text("Transport")
                        if let note = overrideNote(model.override("harness.transport")) { note }
                        else if let launched, launched.transport != config.harness.transport { Text("Relaunch to apply.") }
                        else { Text("Native gets live progress and tool names. If it is unavailable, Yorozu uses the command line for that launch and says so.") }
                    }.disabled(model.override("harness.transport") != nil)
                    urlRow("Gateway URL", text: $gateway, key: "harness.gateway_url", path: \.gatewayURL, valid: Config.isLoopbackGateway(gateway),
                           expected: "Expected a loopback ws:// or wss:// address with no path, such as ws://127.0.0.1:18789.", launched: launched)
                } else {
                    urlRow("Hermes URL", text: $hermes, key: "harness.hermes_url", path: \.hermesURL, valid: Config.isLoopbackHTTP(hermes),
                           expected: "Expected a loopback http:// or https:// address with no path, such as http://127.0.0.1:8642.", launched: launched)
                    LabeledContent {
                        Button("Set Up Hermes Profiles…") { model.openSetup(at: "harness") }
                    } label: {
                        Text("Hermes profiles")
                        Text("Yorozu's own profiles, yorozu-worker and yorozu-roles. Setup shows each change before writing it; your default profile is never changed.")
                    }
                }
            }
            if config.harness.kind == .openclaw, model.runtimeMode == .live, model.nativeSelected { Section { enrollment } }
            Section {
                ModelRow(model: model, title: "Secretary", key: "models.secretary", path: \.secretary, choice: { $0.secretary })
                ModelRow(model: model, title: "Memory extraction", key: "models.extraction", path: \.extraction, choice: { $0.extraction })
                ModelRow(model: model, title: "Workers", key: "models.worker", path: \.worker, choice: { $0.worker })
                ModelRow(model: model, title: "Stronger review", key: "models.review", path: \.review, choice: { $0.review })
                ForEach((model.harness?.executors ?? []).filter { $0.runtime != nil || config.models.coding[$0.id] != nil }, id: \.id) { executor in
                    ModelRow(model: model, title: "Coding: \(executor.name)", key: "models.coding.\(executor.id)", path: \.coding[executor.id], choice: { $0.coding[executor.id] })
                }
            } header: { Text("Models") } footer: {
                Text("Allowed models come from the harness. Automatic picks again at launch and whenever settings change.").foregroundStyle(.secondary)
            }
        }
        .settingsForm()
        .onAppear { gateway = config.harness.gatewayURL; hermes = config.harness.hermesURL; enrolled = model.nativeEnrolled }
        .onChange(of: config.harness.gatewayURL) { _, new in gateway = new }
        .onChange(of: config.harness.hermesURL) { _, new in hermes = new }
        .onChange(of: model.connecting) { _, busy in if !busy { enrolled = model.nativeEnrolled } }
        .onDisappear { model.bootstrapSecret = "" }
        .alert("Switch the main harness?", isPresented: Binding(get: { switchTo != nil }, set: { if !$0 { switchTo = nil } }), presenting: switchTo) { kind in
            Button("Switch to \(Self.harnessTitle(kind))") { model.writeSettings { $0.harness.kind = kind; $0.setup.answered.removeAll { $0 == "harness" } } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your messages, memory excerpts and workers' tasks then go to this harness. The switch applies at the next launch, once running work finishes.")
        }
    }

    static func harnessTitle(_ kind: Config.HarnessKind) -> String {
        switch kind { case .openclaw: "OpenClaw"; case .hermes: "Hermes Agent" }
    }

    /// A loopback address of the harness (`key` in config.toml): applied on Return, at the next launch.
    @ViewBuilder private func urlRow(_ title: LocalizedStringKey, text: Binding<String>, key: String, path: WritableKeyPath<Config.HarnessSettings, String>, valid: Bool, expected: LocalizedStringKey, launched: Config.HarnessSettings?) -> some View {
        let locked = model.override(key), current = model.config.harness[keyPath: path]
        TextField(text: text) {
            Text(title)
            if let note = overrideNote(locked) { note }
            else if !valid { Text(expected) }
            else if let launched, launched[keyPath: path] != current { Text("Relaunch to apply.") }
            else { Text("Loopback only. Press Return to apply.") }
        }
        .monospaced()
        .disabled(locked != nil)
        .onSubmit { let next = text.wrappedValue; if valid, next != current { model.writeSettings { $0.harness[keyPath: path] = next } } }
    }

    /// Enrolls Yorozu's own device with the local Gateway for the native transport.
    @ViewBuilder private var enrollment: some View {
        LabeledContent {
            Text(enrolled ? "Enrolled" : "Not enrolled")
        } label: {
            Text("Device enrollment")
            Text("A separate app device, not a model-provider login. Enter the Gateway's bootstrap token or password here, never in chat; only Yorozu's own device token and key are saved in Keychain. The Gateway may ask you to approve the device. Leave it blank to reconnect an enrolled device.")
        }
        SecureField("Gateway bootstrap secret (not saved)", text: $model.bootstrapSecret)
        LabeledContent {
            Button(model.connecting ? "Connecting…" : enrolled ? "Re-enroll" : "Connect") { Task { await model.enroll() } }.disabled(model.connecting)
        } label: {
            if !model.enrollmentNotice.isEmpty { Text(model.enrollmentNotice).textSelection(.enabled) }
        }
    }
}

/// Settings › Advanced (only while General › Show Advanced settings is on): coding workers and integrations.
struct AdvancedSettings: View {
    @ObservedObject var model: AppModel
    /// Each coding tool's sign-in command, run by the user where the Gateway runs.
    static let logins = ["claude": "claude auth login", "codex": "codex login"]

    var body: some View {
        let config = model.config
        Form {
            ConfigProblems(model: model)
            Section {
                let locked = model.override("harness.dev_repo")
                Toggle(isOn: Binding(get: { !config.harness.devRepo.isEmpty }, set: { on in if on { chooseRepo() } else { model.writeSettings { $0.harness.devRepo = "" } } })) {
                    Text("Allow coding work")
                    Text("Coding workers change code only in this repository, each in its own worktree. Off: Yorozu says coding is off.")
                }.disabled(locked != nil)
                LabeledContent {
                    Button("Choose…", action: chooseRepo)
                } label: {
                    Text("Repository")
                    Text(config.harness.devRepo.isEmpty ? String(localized: "Not set: coding work is off.") : config.harness.devRepo).monospaced().textSelection(.enabled)
                    if let note = overrideNote(locked) { note }
                }.disabled(locked != nil)
                ForEach(config.harness.kind.adapter(config, rpc: GatewayRPC()).executors(model.settingsBox.value), id: \.executor.id) { e in
                    LabeledContent {
                        if e.path == nil { Text("Not found").foregroundStyle(.orange) } else { Text("Found") }
                        if let login = Self.logins[e.executor.id] { Button("Copy Sign-In Command") { copyToClipboard(login) } }
                    } label: {
                        Text(e.executor.name)
                        Text(e.path.map { tildePath(URL(fileURLWithPath: $0)) } ?? String(localized: "Not on PATH, ~/.local/bin or Homebrew")).monospaced().textSelection(.enabled)
                        if let login = Self.logins[e.executor.id] { Text("Sign in where the Gateway runs: `\(login)`") }
                    }
                }
            } header: { Text("Coding workers") } footer: {
                Text("Found means the tool is on this Mac. Yorozu can't tell whether it is signed in.").foregroundStyle(.secondary)
            }
            IntegrationsSection(model: model)
        }
        .settingsForm()
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if let current = model.config.harness.devRepoURL { panel.directoryURL = current }
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        // The home folder itself stays absolute: its tilde form "~" is not a path `Config` accepts.
        let url = picked.standardizedFileURL, home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let path = url.path == home.path ? url.path : tildePath(url)
        // An empty dev_base becomes the repo's current branch now; `resolvingBase` stays the fallback at run time.
        let base = (try? HarnessSettings().resolvingBase(url).codingBaseBranch) ?? ""
        model.writeSettings { $0.harness.devRepo = path; if $0.harness.devBase.isEmpty { $0.harness.devBase = base } }
    }
}

/// Settings › Storage › About this install (with Advanced settings on): what this install runs on.
struct AboutInstallSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let config = model.config
        Section {
            LabeledContent("Run mode") { Text(Self.mode(model.runtimeMode)) }
            LabeledContent("Harness") { Text(model.harnessLabel ?? config.harness.kind.rawValue) }
            LabeledContent {
                Text(config.harness.agent).monospaced()
            } label: {
                Text("Agent id")
                if let note = overrideNote(model.override("harness.agent")) { note }
            }
            if let root = model.configFile?.deletingLastPathComponent() {
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                } label: {
                    Text("Data folder")
                    Text(tildePath(root)).monospaced().textSelection(.enabled)
                }
            }
            LabeledContent {
                if let file = model.configFile { Button("Show config.toml") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
            } label: {
                Text("MCP servers")
                Text(config.effectiveMCPServers.isEmpty ? String(localized: "None") : config.effectiveMCPServers.keys.sorted().joined(separator: ", ")).monospaced()
            }
        } header: { Text("About this install") } footer: {
            Text("MCP servers are edited in config.toml or by asking in the chat.").foregroundStyle(.secondary)
        }
    }

    static func mode(_ mode: RuntimeMode) -> String {
        switch mode {
        case .live: String(localized: "Live")
        case .fixture: String(localized: "Test fixture")
        case .offline: String(localized: "Offline")
        }
    }
}

/// Settings › Advanced › Integrations: each integration's switch, its checks (run while this shows and on "Check again",
/// never otherwise) and, after a check that is not OK, its fixes. Built-in titles come from the string catalog.
struct IntegrationsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            IntegrationRows(model: model)
        } header: { Text("Integrations") } footer: {
            Text("Checks run only while Settings is open or when you click Check again. Yorozu never grants permissions itself: run the copied command in Terminal.").foregroundStyle(.secondary)
        }
    }
}

/// The integrations' rows, shared by Settings › Advanced and the setup window's Computer use step: checks run when the
/// rows appear and on "Check again".
struct IntegrationRows: View {
    @ObservedObject var model: AppModel
    @State private var results: [String: [CheckResult]] = [:]
    @State private var checking = false

    var body: some View {
        let list = model.config.integrations.values.sorted { $0.name < $1.name }
        ForEach(list, id: \.name) { item in
            Toggle(LocalizedStringKey(item.title), isOn: Binding(get: { item.enabled }, set: { on in model.writeSettings { $0.integrations[item.name]?.enabled = on } }))
            ForEach(Array((results[item.name] ?? []).enumerated()), id: \.offset) { _, result in
                LabeledContent {
                    switch result.status {
                    case .ok: Label("OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .warning: Label("Needs attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case .failed: Label("Not working", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                } label: {
                    Text(LocalizedStringKey(result.title))
                    Text(verbatim: result.detail).monospaced().lineLimit(4).textSelection(.enabled)
                }
            }
            if results[item.name]?.contains(where: { $0.status != .ok }) == true {
                ForEach(Array(item.fixes.enumerated()), id: \.offset) { _, fix in
                    switch fix {
                    case .copy(let title, let command):
                        LabeledContent { Button(LocalizedStringKey(title)) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string) } } label: { Text(verbatim: command).monospaced().textSelection(.enabled) }
                    case .open(let title, let url):
                        LabeledContent { Button(LocalizedStringKey(title)) { NSWorkspace.shared.open(url) } } label: { Text(verbatim: url.absoluteString).textSelection(.enabled) }
                    }
                }
            }
        }
        LabeledContent {
            Button(checking ? "Checking…" : "Check again") { Task { await check(list) } }.disabled(checking)
        } label: { EmptyView() }
        .task { await check(list) }
    }

    private func check(_ list: [Integration]) async {
        checking = true; defer { checking = false }
        var found: [String: [CheckResult]] = [:]
        for item in list { found[item.name] = await item.runChecks() }
        results = found
    }
}

/// One role's model: "Automatic (<model>, <reason>)" or one of the harness's allowed models. Choosing Automatic removes
/// the key from `[models]`; an explicit choice the harness does not allow is still used, with a warning.
struct ModelRow: View {
    @ObservedObject var model: AppModel
    let title: LocalizedStringKey
    let key: String
    let path: WritableKeyPath<Config.Models, String?>
    let choice: (ModelChoices) -> ModelChoice?

    var body: some View {
        let explicit = model.config.models[keyPath: path], allowed = model.metadata?.allowed ?? []
        let locked = model.override(key), auto = automatic
        let disallowed = explicit.map { id in !allowed.isEmpty && !allowed.contains { $0.id == id } } ?? false
        Picker(selection: Binding(get: { explicit }, set: { id in let path = path; model.writeSettings { $0.models[keyPath: path] = id } })) {
            Text(Self.automaticLabel(auto)).tag(String?.none)
            Divider()
            ForEach(allowed, id: \.id) { info in
                Text(info.price == nil ? String(localized: "\(info.id) · price unknown") : info.id).tag(String?.some(info.id))
            }
            if let explicit, !allowed.contains(where: { $0.id == explicit }) { Text(explicit).tag(String?.some(explicit)) }
        } label: {
            Text(title)
            if let note = overrideNote(locked) { note }
            else if disallowed { Text("Not among the harness's allowed models. Yorozu still uses it.").foregroundStyle(.orange) }
        }
        .disabled(locked != nil)
    }

    static func automaticLabel(_ auto: ModelChoice?) -> String {
        guard let auto else { return String(localized: "Automatic") }
        return auto.id.map { String(localized: "Automatic (\($0), \(auto.reason))") } ?? String(localized: "Automatic (\(auto.reason))")
    }
    /// What Automatic would pick for this role, with every other explicit choice kept.
    private var automatic: ModelChoice? {
        var models = model.config.models; models[keyPath: path] = nil
        let meta = model.metadata ?? ([], nil)
        return choice(ModelDefaults.resolve(meta.allowed, primary: meta.primary, explicit: models, runtimes: model.executorRuntimes))
    }
}
