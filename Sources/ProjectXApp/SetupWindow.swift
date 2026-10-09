import AppKit
import ProjectXCore
import SwiftUI

/// The setup window (#317, the approved mockup): the app icon, the title and the lead, then the seven steps as one grouped
/// list. Each row shows its state; the current one is highlighted and expands with its controls. Answers go through
/// `SetupEngine` (config.toml, which the watcher reloads, or the assisted OpenClaw write the user saw and confirmed); the
/// model pickers, integration switches and enrollment reuse Settings' own controls.
struct SetupWindow: View {
    static let id = "setup"
    /// The listed steps, in order. Welcome is the header, done the summary, and path_link an optional extra below.
    static let rows = ["harness","gateway","models","integrations","yolo","start_at_login","pair_iphone"]
    @ObservedObject var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var report: SetupReport?
    @State private var busy = false
    @State private var problem: String?
    /// The user's pick per question id until Continue; the question's default before that.
    @State private var picks: [String: String] = [:]
    /// Steps passed over this time that have no answer to record.
    @State private var passed: Set<String> = []
    @State private var confirming: OpenClawPlan?
    @State private var pairing = false
    /// The window's width and least height, the sizes this window owns: nothing proposes a size to a window.
    private enum Metrics { static let width: CGFloat = 560, minHeight: CGFloat = 620, icon: CGFloat = 64 }

    var body: some View {
        let current = current
        VStack(spacing: 0) {
            Form {
                Section {
                    if report == nil { ProgressView().frame(maxWidth: .infinity) }
                    ForEach(Self.rows.compactMap { step($0) }, id: \.id) { s in
                        row(s, current: s.id == current?.id)
                        if s.id == current?.id { controls(s) }
                    }
                } header: { header }
                if let link = step("path_link"), link.state == .needed { pathLink }
                if let report, current == nil { summary(report.readiness) }
                if let problem {
                    Section { Label { Text(problem).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) } }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer(current)
        }
        .frame(width: Metrics.width)
        .frame(minHeight: Metrics.minHeight)
        .task { await refresh() }
        .onChange(of: model.setupRequests) { _, _ in Task { await refresh() } }
        .onChange(of: model.config) { _, _ in Task { await refresh() } } // an answer from `Yorozu setup`, or a Settings change
        .onDisappear { model.setupStep = nil; model.bootstrapSecret = "" }
        .sheet(isPresented: $pairing, onDismiss: { Task { await refresh() } }) { PairPhoneView(model: model) }
        .alert("Change Yorozu's agent entry in OpenClaw?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { plan in
            Button("Apply Changes") { apply(plan) }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(plan.changes.map(\.line).joined(separator: "\n"))
        }
    }

    /// The step a Fix… or a click asked for, else the first one not done.
    private var current: SetupStep? {
        guard report != nil else { return nil }
        if let id = model.setupStep, Self.rows.contains(id), let s = step(id) { return s }
        return Self.rows.lazy.compactMap { step($0) }.first { $0.state != .done && !passed.contains($0.id) }
    }
    private func step(_ id: String) -> SetupStep? { report?.steps.first { $0.id == id } }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: Metrics.icon, height: Metrics.icon).accessibilityHidden(true)
            Text("Set up Yorozu").font(.title2.weight(.semibold)).foregroundStyle(.primary)
            Text("A few checks before the first message. Anything already in place is skipped.").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.bottom, 12).textCase(nil)
    }

    private func row(_ s: SetupStep, current: Bool) -> some View {
        let optional = s.id == "integrations"
        let note = s.checks.first { $0.severity != .ok } ?? (s.state == .done ? s.checks.first : nil)
        let link = s.checks.lazy.compactMap { Self.link($0.fix) }.first
        return HStack(alignment: .top, spacing: 10) {
            StepGlyph(kind: current ? .current : s.state == .done ? .done : optional ? .optional : .todo)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(s.id)).fontWeight(current ? .semibold : .regular)
                if let note { Text(verbatim: note.title).font(.caption).foregroundStyle(.secondary) }
                if let link { Link(link.title, destination: link.url).font(.caption) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if s.state == .done, !current { Text("Done").foregroundStyle(.secondary) } else if optional { Text("Optional").foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.setupStep = s.id }
        .listRowBackground(current ? Color.accentColor.opacity(0.08) : nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    @ViewBuilder private func controls(_ s: SetupStep) -> some View {
        switch s.id {
        case "harness":
            checks(s.checks)
            if let q = s.question, q.id == "harness", !q.choices.contains("check") {
                Picker("Main harness", selection: pick(q)) {
                    ForEach(q.choices, id: \.self) { Text(Config.HarnessKind(rawValue: $0).map(AdvancedSettings.harnessTitle) ?? $0).tag($0) }
                }
            }
            plan(s)
            if s.state == .app, let place = s.whereInApp { Text(verbatim: place).foregroundStyle(.secondary) }
        case "gateway":
            Text("Yorozu talks to the Gateway directly once this Mac is enrolled, with live progress and tool names. Until then it uses the openclaw command line.").foregroundStyle(.secondary)
            if model.runtimeMode == .live, model.nativeSelected {
                SecureField(text: $model.bootstrapSecret) {
                    Text("Gateway bootstrap secret")
                    Text("Used once to enroll this Mac. Not saved and never sent to a model.")
                }
                LabeledContent {
                    Button(model.connecting ? "Connecting…" : "Connect") { Task { await model.enroll(); await refresh() } }.disabled(model.connecting)
                } label: {
                    if !model.enrollmentNotice.isEmpty { Text(model.enrollmentNotice).textSelection(.enabled) }
                }
            } else {
                Text("Enrolling needs a live run on the native transport (Settings › Advanced).").foregroundStyle(.secondary)
            }
            LabeledContent {
                Button("Copy") { copyToClipboard("openclaw devices list") }
            } label: {
                Text("Approve this Mac in OpenClaw")
                Text("OpenClaw may ask you to approve the new device: list pending devices with `openclaw devices list`, then approve Yorozu's.")
            }
        case "models":
            checks(s.checks)
            ModelRow(model: model, title: "Secretary", key: "models.secretary", path: \.secretary, choice: { $0.secretary })
            ModelRow(model: model, title: "Memory extraction", key: "models.extraction", path: \.extraction, choice: { $0.extraction })
            ModelRow(model: model, title: "Workers", key: "models.worker", path: \.worker, choice: { $0.worker })
            ModelRow(model: model, title: "Stronger review", key: "models.review", path: \.review, choice: { $0.review })
            plan(s)
        case "integrations":
            IntegrationRows(model: model)
        case "yolo":
            Toggle(isOn: toggle(s.question)) {
                Text("YOLO mode")
                Text("Off by default, which is safer. When on, workers take the outward-facing steps you ask for (sending, posting, buying, deleting) without asking first. Change it any time in Settings › General.")
            }
        case "start_at_login":
            // Off and disabled while this run leaves the login item alone, as in Settings › General.
            Toggle(isOn: model.loginItemBlocker == nil ? toggle(s.question) : .constant(false)) {
                Text("Start at login")
                Text("On by default, so paired phones and scheduled jobs can reach Yorozu after a restart.")
                if let blocker = model.loginItemBlocker { Text(blocker) }
            }.disabled(model.loginItemBlocker != nil)
        case "pair_iphone":
            LabeledContent {
                Button("Pair iPhone…") { pairing = true }.disabled(model.relay == nil)
            } label: {
                Text("No paired phones yet.")
                Text(model.runtimeMode == .live ? "Scan the code with the iPhone Camera. You can also pair later in Settings › Devices." : "Pairing works in live mode only.")
            }
        default: EmptyView()
        }
    }

    /// Readiness items with their raw detail and fix: a copy button with the command, a link, or the step to go to.
    @ViewBuilder private func checks(_ items: [Readiness.Item]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            LabeledContent {
                switch item.fix {
                case .copy(let title, let command)?: Button(title) { copyToClipboard(command) }.help(command)
                case .open(let title, let url)?: Link(title, destination: url)
                case .step(let id)? where id != current?.id: Button("Go to Step") { model.setupStep = id }
                default: EmptyView()
                }
            } label: {
                Label {
                    Text(verbatim: item.title)
                } icon: {
                    switch item.severity {
                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("OK")
                    case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Needs attention")
                    case .blocking: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Blocking")
                    }
                }
                if case .copy(_, let command)? = item.fix { Text(verbatim: command).monospaced().textSelection(.enabled) }
                if item.severity != .ok, !item.detail.isEmpty { Text(verbatim: item.detail).monospaced().lineLimit(4).textSelection(.enabled) }
            }
        }
    }

    /// The assisted OpenClaw write the step offers, as a diff of every path it changes.
    @ViewBuilder private func plan(_ s: SetupStep) -> some View {
        if let plan = s.plan, s.question?.id == "openclaw_setup" {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.needsConfirmation ? "Yorozu's agent entry in OpenClaw differs from what Yorozu expects. Continue asks before changing it:" : "Continue writes only Yorozu's own entries into OpenClaw's config:")
                ForEach(Array(plan.changes.enumerated()), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: change.path).fontWeight(.medium)
                        if let old = change.old { Text(verbatim: "− " + old).foregroundStyle(.red) }
                        if let new = change.new { Text(verbatim: "+ " + new).foregroundStyle(.green) }
                    }.font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
                }
                Text("Nothing else in OpenClaw's config changes.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var pathLink: some View {
        Section {
            LabeledContent {
                Button("Add") { answer("path_link", "yes") }
                Button("Not Now") { answer("path_link", "no") }
            } label: {
                Text("yorozu command (optional)")
                Text("Adds ~/.local/bin/yorozu, so Terminal and agents can run `yorozu setup`.")
            }
        }
    }

    private func summary(_ r: Readiness) -> some View {
        Section("Done") {
            LabeledContent {
                Text(r.summary)
            } label: {
                HStack(spacing: 6) { ReadinessDot(state: r.state); Text("Status") }
            }
            checks(r.items.filter { $0.severity != .ok })
        }
    }

    private func footer(_ current: SetupStep?) -> some View {
        HStack {
            if let current, let i = Self.rows.firstIndex(of: current.id) { Text("Step \(i + 1) of \(Self.rows.count)").foregroundStyle(.secondary) }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let current { Button("Skip for Now") { skip(current) }.disabled(busy) }
            Button(current == nil ? "Done" : "Continue") { proceed(current) }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || report == nil || current.map { $0.state != .done && ["gateway", "pair_iphone"].contains($0.id) } == true)
        }
        .padding()
    }

    // MARK: Actions

    private func refresh() async { _ = await run { try await $0.evaluate() } }

    /// Runs one engine call; false (with the reason shown) when it threw.
    private func run(_ op: (SetupEngine) async throws -> SetupReport) async -> Bool {
        guard let engine = model.setupEngine() else { return false }
        busy = true; defer { busy = false }
        do { report = try await op(engine); problem = nil; return true } catch { problem = error.localizedDescription; return false }
    }

    private func answer(_ id: String, _ value: String) {
        Task { if await run({ try await $0.answer(id, value) }) { model.setupStep = nil; model.recheck() } }
    }

    private func apply(_ plan: OpenClawPlan) {
        Task { if await run({ try await $0.applyAssisted(plan) }) { model.setupStep = nil; model.recheck() } }
    }

    /// Continue: the step's answer (the pick, the assisted write, or "check" to look again); Done finishes setup.
    private func proceed(_ s: SetupStep?) {
        guard let s else {
            do { try model.setupEngine()?.finish(); dismissWindow(id: Self.id) } catch { problem = error.localizedDescription }
            return
        }
        guard let q = s.question else { if s.state == .done { model.setupStep = nil } else { Task { await refresh() } }; return }
        if q.id == "start_at_login", model.loginItemBlocker != nil { model.setupStep = nil; passed.insert(s.id); return } // nothing to record
        if q.id == "openclaw_setup", let plan = s.plan { plan.needsConfirmation ? (confirming = plan) : apply(plan); return }
        if q.choices.contains("check") { return answer(q.id, "check") }
        if q.id.hasPrefix("integrations.") { return answer(q.id, model.config.integrations[String(q.id.dropFirst(13))]?.enabled == false ? "off" : "on") }
        answer(q.id, ["gateway": "connected", "pair_iphone": "paired"][q.id] ?? picks[q.id] ?? q.default)
    }

    /// Skip for Now: records a skip where the step has one, keeps the current value of a switch, else passes the step over.
    private func skip(_ s: SetupStep) {
        model.setupStep = nil
        guard s.state != .done, let q = s.question, !(q.id == "start_at_login" && model.loginItemBlocker != nil) else { passed.insert(s.id); return }
        if q.choices.contains("skip") { answer(q.id, "skip") }
        else if ["yolo", "start_at_login"].contains(q.id) || q.id.hasPrefix("integrations.") { answer(q.id, q.default) }
        else { passed.insert(s.id) }
    }

    private func pick(_ q: SetupStep.Question) -> Binding<String> {
        Binding(get: { picks[q.id] ?? q.default }, set: { picks[q.id] = $0 })
    }
    private func toggle(_ q: SetupStep.Question?) -> Binding<Bool> {
        Binding(get: { q.map { picks[$0.id] ?? $0.default } == "on" }, set: { on in if let q { picks[q.id] = on ? "on" : "off" } })
    }

    static func title(_ id: String) -> LocalizedStringKey {
        switch id {
        case "harness": "Harness"
        case "gateway": "Connect to the Gateway"
        case "models": "Models"
        case "integrations": "Computer use (CuaDriver)"
        case "yolo": "YOLO mode"
        case "start_at_login": "Start at login"
        case "pair_iphone": "Pair your iPhone"
        default: LocalizedStringKey(id)
        }
    }
    private static func link(_ fix: Readiness.Item.Fix?) -> (title: String, url: URL)? {
        if case .open(let title, let url)? = fix { (title, url) } else { nil }
    }
}

/// A setup row's state: done (green check), current (ring and dot), to do (ring), optional (dashed ring).
struct StepGlyph: View {
    enum Kind { case done, current, todo, optional }
    let kind: Kind
    private static let side: CGFloat = 16, line: CGFloat = 1.5, dot: CGFloat = 6
    private var label: LocalizedStringKey { switch kind { case .done: "Done"; case .current: "Current step"; case .todo: "To do"; case .optional: "Optional" } }
    var body: some View {
        ZStack {
            switch kind {
            case .done: Image(systemName: "checkmark.circle.fill").resizable().foregroundStyle(.green)
            case .current:
                Circle().strokeBorder(Color.accentColor, lineWidth: Self.line)
                Circle().fill(Color.accentColor).frame(width: Self.dot, height: Self.dot)
            case .todo: Circle().strokeBorder(.tertiary, lineWidth: Self.line)
            case .optional: Circle().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: Self.line, dash: [2, 2]))
            }
        }
        .frame(width: Self.side, height: Self.side)
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}
