import Foundation

/// One setup step as it stands now (#317). `state` comes from its read-only checks and from `config.toml`
/// (`[setup] answered`), so a step whose checks pass is done without asking.
public struct SetupStep: Sendable, Equatable, Identifiable {
    /// `app`: needed, but only the running app can do it (`whereInApp` says where); seen only outside the app.
    public enum State: String, Sendable { case done, needed, app }
    public struct Question: Sendable, Equatable {
        public var id, text: String; public var choices: [String]; public var `default`: String
    }
    public var id: String, title: String, state: State
    /// The checks behind `state`, as readiness items.
    public var checks: [Readiness.Item] = []
    /// What to ask for this step; also on a done step whose answer can still change (YOLO, the harness choice).
    public var question: Question?
    /// The assisted OpenClaw write this step offers with question `openclaw_setup` (harness, models).
    public var plan: OpenClawPlan?
    /// Where in the app to finish an app-only step.
    public var whereInApp: String?
}

public struct SetupReport: Sendable {
    /// Every step in `SetupEngine.order`; welcome and done are the window's header and footer.
    public var steps: [SetupStep]
    /// The first step with something to answer; app-only steps are passed over outside the app. Nil: nothing left here.
    public var next: SetupStep? { steps.first { $0.state == .needed && $0.question != nil } }
    /// App-only steps left for the app.
    public var inApp: [SetupStep] { steps.filter { $0.state == .app } }
    /// Every check, for the done summary.
    public var readiness: Readiness { Readiness(items: steps.flatMap(\.checks)) }
}

/// The one step engine behind the setup window and `Yorozu setup` (#317). Reads are read-only; `answer` applies one answer:
/// `config.toml` through `Config.update` (atomic; the running app's watcher reloads it), the assisted OpenClaw write, or
/// the `~/.local/bin/yorozu` link. An explicit answer is the user's word for a security-relevant key (the harness, YOLO).
public struct SetupEngine: Sendable {
    public static let order = ["welcome","harness","gateway","models","integrations","yolo","start_at_login","pair_iphone","path_link","done"]
    public static let titles = ["welcome": String(localized: "Welcome"), "harness": String(localized: "Harness"), "gateway": String(localized: "Connect to the Gateway"), "models": String(localized: "Models"), "integrations": String(localized: "Computer use"), "yolo": String(localized: "YOLO"),
                                "start_at_login": String(localized: "Start at login"), "pair_iphone": String(localized: "Pair your iPhone"), "path_link": String(localized: "yorozu command"), "done": String(localized: "Done")]
    /// Steps only the running app can do, and where.
    public static let appOnly = ["gateway": String(localized: "Settings › Advanced › Harness connection"), "start_at_login": String(localized: "Settings › General › Start at login"), "pair_iphone": String(localized: "Settings › Devices › Pair iPhone")]
    /// What only the running app knows. Nil outside the app: app-only steps are then left to it.
    public struct Host: Sendable {
        public var enrolled: Bool, paired: Bool
        public init(enrolled: Bool, paired: Bool) { self.enrolled = enrolled; self.paired = paired }
    }
    public var configFile: URL, dataRoot: URL
    public var environment: [String:String]
    /// The app's Gateway client; nil builds a CLI-transport one for `harness.gateway_url`.
    public var rpc: GatewayRPC?
    public var host: Host?
    /// The app binary `path_link` points to; nil leaves that step out.
    public var executable: URL?
    public init(dataRoot: URL, environment: [String:String] = ProcessInfo.processInfo.environment, rpc: GatewayRPC? = nil, host: Host? = nil, executable: URL? = nil) {
        self.dataRoot = dataRoot; configFile = Config.url(in: dataRoot); self.environment = environment; self.rpc = rpc; self.host = host; self.executable = executable
    }
    public static let link = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/yorozu")

    /// Every step's state, checks and question. Runs the read-only checks: harness detection, Gateway `health`, the OpenClaw
    /// inspection and the enabled integrations' checks. Creates `config.toml` with the defaults when it is missing.
    public func evaluate() async throws -> SetupReport {
        let file = try Config.load(configFile), resolved = try ResolvedSettings(file,environment: environment), c = resolved.config
        let answered = Set(file.setup.answered), finished = file.setup.done
        let rpc = rpc ?? GatewayRPC(target: c.harness.gatewayURL)
        func step(_ id: String, _ state: SetupStep.State, checks: [Readiness.Item] = [], _ question: SetupStep.Question? = nil) -> SetupStep {
            var s = SetupStep(id: id,title: Self.titles[id]!,state: state,checks: checks,question: question)
            if state != .done, host == nil, let place = Self.appOnly[id] { s.state = .app; s.whereInApp = place; s.question = nil }
            return s
        }
        func retry(_ id: String) -> SetupStep.Question { .init(id: id,text: "Fix the items above, then check again, or skip this step for now.",choices: ["check","skip"],default: "check") }
        func passed(_ items: [Readiness.Item]) -> Bool { items.allSatisfy { $0.severity == .ok } }
        var steps: [SetupStep] = []

        steps.append(step("welcome",answered.contains("welcome") || finished ? .done : .needed,
                          .init(id: "welcome",text: "Yorozu checks this Mac and asks a few questions. It never installs software or signs in for you. Start setup?",choices: ["start"],default: "start")))

        // Harness: the main one's detection; for OpenClaw also Yorozu's entry and the assisted write.
        let main = c.harness.kind.adapter(c.harness,rpc: rpc), detection = await main.detect()
        let installed = Config.HarnessKind.allCases.filter { $0 == c.harness.kind ? detection.installed : $0.adapter(c.harness,rpc: rpc).installed }
        let openclaw = main as? OpenClawSetup, gatewayChecks = openclaw != nil && detection.installed
        var inspection: OpenClawInspection?, inspectionError: Readiness.Item?
        if gatewayChecks, OpenClawSetup.gatewayAllowed, detection.reachable == true, !detection.items.contains(where: { $0.id == "openclaw.personal" }) {
            do { inspection = try await openclaw!.inspect(resolved,dataRoot: dataRoot) }
            catch { inspectionError = Readiness.Item(id: "openclaw.config",title: PlainError.describe(error)?.title ?? String(localized: "OpenClaw's config couldn't be read"),detail: error.localizedDescription,severity: .warning,fix: .step("harness")) }
        }
        let plan = inspection?.plan, entryPlan = plan?.changes.contains { !$0.path.hasSuffix(".modelPolicy.allow") } == true
        let harnessChecks = detection.items + (inspection?.entry ?? []) + [inspection?.blocked,inspectionError].compactMap { $0 }
        let choose = SetupStep.Question(id: "harness",text: "Which harness should Yorozu use?",choices: installed.map(\.rawValue),default: installed.contains(c.harness.kind) ? c.harness.kind.rawValue : installed.first?.rawValue ?? "")
        var harness: SetupStep
        if detection.installed, passed(harnessChecks), !entryPlan || answered.contains("harness") {
            harness = step("harness",.done,checks: harnessChecks,installed.count > 1 ? choose : nil)
        } else if answered.contains("harness") {
            harness = step("harness",.done,checks: harnessChecks)
        } else if !detection.installed, !installed.isEmpty {
            harness = step("harness",.needed,checks: harnessChecks,choose)
        } else if gatewayChecks, !OpenClawSetup.gatewayAllowed {
            harness = step("harness",.app,checks: harnessChecks); harness.whereInApp = String(localized: "Open Yorozu from Finder and finish setup there")
        } else if let plan, entryPlan {
            harness = step("harness",.needed,checks: harnessChecks,assist(plan)); harness.plan = plan
        } else {
            harness = step("harness",.needed,checks: harnessChecks,retry("harness"))
        }
        steps.append(harness)

        // Native transport enrollment (app-only), for OpenClaw on the native transport.
        if c.harness.kind != .openclaw || c.harness.transport != .native || host?.enrolled == true || answered.contains("gateway") {
            steps.append(step("gateway",.done,checks: host?.enrolled == true ? [Readiness.Item(id: "openclaw.native",title: String(localized: "This Mac is connected to the Gateway directly"),severity: .ok)] : []))
        } else {
            steps.append(step("gateway",.needed,checks: host == nil ? [] : [Readiness.Item(id: "openclaw.native",title: String(localized: "This Mac isn't enrolled with the Gateway yet"),detail: "Yorozu uses the openclaw CLI until it is. OpenClaw asks you to approve this Mac's device: openclaw devices list.",severity: .warning,fix: .step("gateway"))],
                              .init(id: "gateway",text: "Connect Yorozu to the Gateway directly? OpenClaw then asks you to approve this Mac's device (openclaw devices list).",choices: ["connected","skip"],default: "connected")))
        }

        // Models: usable per models.list (OpenClaw); Hermes's are its own profiles' (#318), so detection stands in.
        var models: SetupStep
        if let inspection {
            let checks = inspection.models + inspection.auth
            let allow = plan?.changes.contains { $0.path.hasSuffix(".modelPolicy.allow") } == true
            if passed(checks) || answered.contains("models") { models = step("models",.done,checks: checks) }
            else if allow, harness.question?.id != "openclaw_setup" { models = step("models",.needed,checks: checks,assist(plan!)); models.plan = plan }
            else { models = step("models",.needed,checks: checks,retry("models")) }
        } else if harness.state == .app {
            models = step("models",.app); models.whereInApp = harness.whereInApp
        } else {
            let ok = c.harness.kind == .hermes ? passed(detection.items) : false
            models = step("models",ok || answered.contains("models") ? .done : .needed,checks: ok ? [] : [Readiness.Item(id: "models",title: String(localized: "Models are checked once the harness answers"),severity: .warning,fix: .step("harness"))],retry("models"))
        }
        steps.append(models)

        // Integrations: each enabled one's checks; a problem asks to keep it on or turn it off.
        var integrationChecks: [Readiness.Item] = [], ask: SetupStep.Question?
        for i in c.integrations.values.sorted(by: { $0.name < $1.name }) {
            let key = "integrations.\(i.name)"
            guard i.enabled else { integrationChecks.append(Readiness.Item(id: key,title: String(localized: "\(String(localized: String.LocalizationValue(i.title))) is off"),severity: .ok)); continue }
            let results = await i.runChecks(), fix = i.fixes.first.map(Readiness.Item.Fix.init)
            integrationChecks += results.enumerated().map { n,r in
                let t = String(localized: String.LocalizationValue(r.title))
                return Readiness.Item(id: "\(key).\(n)",title: r.status == .ok ? t : r.status == .warning ? String(localized: "\(t): needs attention") : String(localized: "\(t): not found"),detail: r.detail,
                                      severity: r.status == .ok ? .ok : .warning,fix: r.status == .ok ? nil : fix)
            }
            if ask == nil, !answered.contains(key), results.contains(where: { $0.status != .ok }) {
                ask = .init(id: key,text: "\(i.title) needs the items above. Keep it on (fix them later) or turn it off?",choices: ["on","off"],default: results.first.map { $0.status == .failed } == true ? "off" : "on")
            }
        }
        steps.append(step("integrations",ask == nil ? .done : .needed,checks: integrationChecks,ask))

        steps.append(step("yolo",answered.contains("yolo") ? .done : .needed,
                          .init(id: "yolo",text: "Turn on YOLO mode? Workers then take the outward-facing steps you ask for (sending, posting, buying, deleting) without asking first. Off is safer; change it any time in Settings › General.",choices: ["off","on"],default: c.general.yolo ? "on" : "off")))
        steps.append(step("start_at_login",answered.contains("start_at_login") ? .done : .needed,
                          .init(id: "start_at_login",text: "Open Yorozu when you log in? It's on by default.",choices: ["on","off"],default: c.general.startAtLogin ? "on" : "off")))
        steps.append(step("pair_iphone",answered.contains("pair_iphone") || host?.paired == true ? .done : .needed,
                          .init(id: "pair_iphone",text: "Pair your iPhone: scan the code in Settings › Devices with the iPhone's Camera, or skip for now.",choices: ["paired","skip"],default: "skip")))
        let linked = executable.map { (try? FileManager.default.destinationOfSymbolicLink(atPath: Self.link.path)) == $0.path } ?? true
        steps.append(step("path_link",linked || answered.contains("path_link") ? .done : .needed,
                          .init(id: "path_link",text: "Add a `yorozu` command at ~/.local/bin/yorozu, so Terminal and agents can run `yorozu setup`?",choices: ["no","yes"],default: "no")))
        steps.append(step("done",steps.allSatisfy { $0.state == .done } ? .done : .needed))
        return SetupReport(steps: steps)
    }

    /// Applying names the plan it was shown: `apply:<plan digest>`.
    func assist(_ plan: OpenClawPlan) -> SetupStep.Question {
        let apply = "apply:" + plan.digest
        return plan.needsConfirmation
            ? .init(id: "openclaw_setup",text: "Yorozu's agent entry in OpenClaw differs from what Yorozu expects. Apply the changes listed? Nothing else in OpenClaw's config changes.",choices: [apply,"skip"],default: "skip")
            : .init(id: "openclaw_setup",text: "Write Yorozu's own entries into OpenClaw's config, as listed: its agent, its allowed models and its yorozu-* MCP servers? Nothing else changes.",choices: [apply,"skip"],default: apply)
    }

    /// Applies one answer, then evaluates again, and finishes setup when every step is done. Throws for an id with no question
    /// now, a value outside its choices, an app-only step outside the app, or an `apply:<digest>` of another plan than the
    /// current one. `skip` (and any answer but `check` and `apply`) records the step as answered.
    @discardableResult public func answer(_ id: String, _ value: String) async throws -> SetupReport {
        let report = try await evaluate()
        if host == nil, let step = report.steps.first(where: { $0.id == id && $0.state == .app }) {
            throw ProjectError.blocked("Finish this in the Yorozu app: \(step.whereInApp ?? "the setup window").")
        }
        guard let step = report.steps.first(where: { $0.question?.id == id }), let question = step.question else { throw ProjectError.invalid("Nothing to answer for \"\(id)\" now. Known steps: " + Self.order.joined(separator: ", ") + ".") }
        if id == "openclaw_setup", value.hasPrefix("apply"), !question.choices.contains(value) {
            throw ProjectError.conflict("These aren't the changes Yorozu would make now. Run `yorozu setup --json` again, review the changes, and answer with its apply:<plan_digest>.")
        }
        guard question.choices.contains(value) else { throw ProjectError.invalid("\"\(value)\" isn't an answer to \(id); choose one of: " + question.choices.joined(separator: ", ") + ".") }
        let next: SetupReport
        if id == "openclaw_setup", value.hasPrefix("apply"), let plan = step.plan { next = try await applyAssisted(plan) }
        else if value == "check" { next = report }
        else {
            if id == "path_link", value == "yes", let executable { try Self.makeLink(to: executable) }
            try Config.update(configFile) { c in
                defer { // choosing a harness is not skipping its checks
                    let mark = id == "openclaw_setup" ? step.id : id
                    if !(id == "harness" && value != "skip"), !c.setup.answered.contains(mark) { c.setup.answered.append(mark) }
                }
                switch id {
                case "harness" where value != "skip": c.harness.kind = Config.HarnessKind(rawValue: value)!
                case "yolo": c.general.yolo = value == "on"
                case "start_at_login": c.general.startAtLogin = value == "on"
                case _ where id.hasPrefix("integrations."): c.integrations[String(id.dropFirst(13))]?.enabled = value == "on"
                default: break
                }
            }
            next = try await evaluate()
        }
        if next.steps.last?.state == .done { try finish() }
        return next
    }

    /// The assisted OpenClaw write for `plan` as the user saw it (a step's `plan`), confirmed by their click; refused when
    /// OpenClaw's config changed since. Then evaluates again: a second run with nothing missing writes nothing.
    @discardableResult public func applyAssisted(_ plan: OpenClawPlan) async throws -> SetupReport {
        let resolved = try ResolvedSettings(try Config.load(configFile),environment: environment), h = resolved.config.harness
        try await OpenClawSetup(agent: h.agent,rpc: rpc ?? GatewayRPC(target: h.gatewayURL)).apply(plan,settings: resolved,dataRoot: dataRoot,confirmed: true)
        return try await evaluate()
    }

    /// Marks setup finished (`[setup] done = true`), so the app stops opening the setup window at launch.
    public func finish() throws { try Config.update(configFile) { $0.setup.done = true } }

    /// `~/.local/bin/yorozu` → the app binary; an existing file that isn't that link is left alone.
    static func makeLink(to executable: URL) throws {
        let fm = FileManager.default
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) { if existing == executable.path { return } }
        if fm.fileExists(atPath: link.path) || (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil { throw ProjectError.invalid("\(link.path) already exists; remove it first, then answer again.") }
        try fm.createDirectory(at: link.deletingLastPathComponent(),withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path,withDestinationPath: executable.path)
    }
}
