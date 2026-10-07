import SwiftUI
import AppKit
import ProjectXCore

@MainActor final class AppModel: ObservableObject {
    let runtimeMode = RuntimeMode.from(ProcessInfo.processInfo.environment)
    @Published var fixtureAcknowledged = false
    @Published var snapshot = Snapshot()
    @Published var selected: String?
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
                let root = env["PROJECTX_DATA"].map { URL(fileURLWithPath: $0,isDirectory: true) } ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(env["PROJECTX_MODE"] == "fixture" ? "PROJECTX-fixture-data" : "PROJECTX-data",isDirectory: true)
                let store = try Store(root: root)
                let memory = try MemoryStore(dataRoot: root)
                try await memory.rebuild()
                let harness: any Harness
                switch runtimeMode.rawValue {
                case "fixture": harness = FixtureHarness()
                case "live":
                    // Native launch is NOT an escape from an inherited exec restriction.
                    try GatewayRPC.enforceAttribution(env)
                    guard env["PROJECTX_AGENT"] == nil || env["PROJECTX_AGENT"] == "projectx" else { throw ProjectError.blocked("R1 uses only the dedicated projectx agent, never personal agents.") }
                    if nativeSelected { nativeClient = try NativeGatewayClient(target: env["PROJECTX_GATEWAY_URL"] ?? "ws://127.0.0.1:18789") }
                    harness = OpenClawHarness(workspace: root.appendingPathComponent("harness-workspaces"),agent: "projectx",secretaryModel: env["PROJECTX_SECRETARY_MODEL"] ?? "openai-pool/gpt-6-astra",workerModel: env["PROJECTX_MODEL"] ?? "openai-pool/gpt-6-sol",rpc: GatewayRPC(native: nativeClient,audit: { try await store.gatewayReceipt($0) }))
                default: harness = OfflineHarness()
                }
                let engine = Engine(store: store,memory: memory,harness: harness); self.engine = engine
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
    func status(_ topic: Topic) -> String { snapshot.work.last { $0.topicID == topic.id }?.state ?? "idle" }
    func symbol(_ topic: Topic) -> String {
        if let work = snapshot.work.last(where: { $0.topicID == topic.id }), work.state == "amendment_pending", work.result != nil { return "exclamationmark.circle" }
        switch status(topic) { case "working","queued","amendment_pending": return "circle.dotted"
        case "done": return "checkmark.circle"
        case "failed","uncertain","cancellation_requested": return "exclamationmark.circle"
        default: return "circle" }
    }
}
struct MessageCard: View {
    let message: Message
    var body: some View {
        VStack(alignment: .leading,spacing: 6) {
            Text(message.role == "user" ? "You" : "PROJECTX").font(.caption).foregroundStyle(.secondary)
            Text(message.body).textSelection(.enabled).frame(maxWidth: .infinity,alignment: .leading)
        }.padding(12).background(message.role == "user" ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
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
                Button(model.runtimeMode.sendLabel) { Task { await model.send() } }.keyboardShortcut(.return,modifiers: .command)
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
        VStack(alignment: .leading,spacing: 0) {
            HStack { VStack(alignment: .leading) { Text(topic.label).font(.headline); Text("Inspect only · \(model.status(topic))").font(.caption).foregroundStyle(.secondary) }; Spacer()
                Button { model.selected = nil } label: { Image(systemName: "xmark") }.help("Close inspection")
            }.padding()
            Divider()
            ScrollView { LazyVStack(alignment: .leading,spacing: 12) {
                ForEach(model.snapshot.messages.filter { $0.topicID == topic.id && $0.kind == "conversation" }) { MessageCard(message: $0) }
                ForEach(model.snapshot.work.filter { $0.topicID == topic.id }) { work in
                    VStack(alignment: .leading,spacing: 9) {
                        Text(work.instruction).font(.headline).textSelection(.enabled)
                        Text(work.state.replacingOccurrences(of: "_",with: " ")).font(.caption).foregroundStyle(.secondary)
                        ForEach(model.snapshot.amendments.filter { $0.taskID == work.id }) { amendment in
                            Text("Amendment \(amendment.revision) · \(amendment.state)\n\(amendment.instruction)").font(.callout).textSelection(.enabled)
                        }
                        ForEach(model.snapshot.events.filter { $0.taskID == work.id }) { event in
                            VStack(alignment: .leading) { Text(event.kind).font(.caption).foregroundStyle(.secondary); Text(event.body).textSelection(.enabled) }
                        }
                        if let error = work.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                        if let result = work.result { Text(work.suppressed ? "Retained result (superseded)" : "Retained result").font(.caption).foregroundStyle(.secondary); Text(result).textSelection(.enabled) }
                    }.padding(10).background(Color.secondary.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }.padding() }
        }.frame(minWidth: 260,idealWidth: 340,maxWidth: 520)
    }
}
struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var sidebar = true
    var body: some View {
        VStack(spacing: 0) {
            HStack { Button { sidebar.toggle() } label: { Image(systemName: "sidebar.left") }.help("Toggle topic sub-chats")
                Text("PROJECTX").font(.headline); Spacer()
                if model.nativeSelected && model.runtimeMode == .live { Button("Connect native device") { model.showEnrollment = true } }
                Text(model.notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(12)
            VStack(alignment: .leading,spacing: 6) {
                Label(model.runtimeMode.bannerTitle,systemImage: "exclamationmark.triangle.fill").font(.headline)
                Text(model.runtimeMode.explanation).font(.callout).fixedSize(horizontal: false,vertical: true)
                if model.runtimeMode == .fixture && !model.fixtureAcknowledged {
                    Button("I understand: enable synthetic TEST input") { model.fixtureAcknowledged = true }
                        .accessibilityIdentifier("acknowledgeSyntheticFixture")
                }
            }.frame(maxWidth: .infinity,alignment: .leading).padding(12)
                .background(Color.orange.opacity(0.18)).accessibilityElement(children: .contain)
            Divider()
            HSplitView {
                if sidebar { VStack(alignment: .leading,spacing: 0) {
                    Text("Sub-chats").font(.headline).padding()
                    List(model.snapshot.topics) { topic in
                        Button { model.selected = topic.id } label: { HStack { Image(systemName: model.symbol(topic)); Text(topic.label); Spacer() }.contentShape(Rectangle()) }.buttonStyle(.plain).help(model.status(topic)).accessibilityLabel("\(topic.label), \(model.status(topic))")
                    }
                }.frame(minWidth: 160,idealWidth: 210,maxWidth: 290) }
                MainChat(model: model)
                if let selected = model.selected, let topic = model.snapshot.topics.first(where: { $0.id == selected }) { InspectionPane(model: model,topic: topic) }
            }
        }.frame(minWidth: 780,minHeight: 500).onAppear { model.start() }
            .sheet(isPresented: $model.showEnrollment,onDismiss: { model.bootstrapSecret = "" }) {
                VStack(alignment: .leading,spacing: 16) {
                    Text("Enroll PROJECTX with the local Gateway").font(.headline)
                    Text("This is a separate app device, not a model-provider login. The Gateway is loopback only. Enter its bootstrap token/password privately here; never put it in chat. Only PROJECTX's own device token and generated key are saved in Keychain. A new device approval may be required. Leave blank to reconnect an enrolled device.").fixedSize(horizontal: false,vertical: true)
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
