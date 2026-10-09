import ProjectXCore
import ServiceManagement
import SwiftUI

/// Settings › General: startup, notifications, keyboard, workers and appearance.
struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @State private var shortcut = ""
    @State private var shortcutProblem: String?
    private static let shortcutPreset = "option+space"

    var body: some View {
        let general = model.config.general
        Form {
            ConfigProblems(model: model)
            Section("Startup") {
                LabeledContent {
                    Button("Run Setup Again…") { model.openSetup() }
                } label: {
                    HStack(spacing: 6) {
                        ReadinessDot(state: model.readiness?.state)
                        if let r = model.readiness { Text(r.state == .ready ? String(localized: "Setup: Ready") : r.summary) } else { Text("Setup: checking…") }
                    }
                }
                Toggle(isOn: Binding(get: { general.startAtLogin && model.loginItemBlocker == nil }, set: { on in model.writeSettings { $0.general.startAtLogin = on } })) {
                    Text("Start at login")
                    if let blocker = model.loginItemBlocker { Text(blocker) }
                    else if general.startAtLogin, model.loginItemStatus == .requiresApproval { Text("Waiting for your approval in System Settings › General › Login Items.") }
                }.disabled(model.loginItemBlocker != nil)
                if model.loginItemBlocker == nil, general.startAtLogin, model.loginItemStatus == .requiresApproval {
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                Toggle(isOn: model.setting(\.general.keepMacAwake)) {
                    Text("Keep the host awake")
                    Text("Workers and client devices need the host awake. A closed lid still sleeps.")
                }
            }
            Section("Notifications") {
                Toggle(isOn: model.setting(\.notifications.enabled)) {
                    Text("Show notifications")
                    Text("For results, failures and questions. Nothing is shown while you are reading the latest message.")
                }
                Picker(selection: model.setting(\.notifications.destination)) {
                    Text("This host").tag(Config.Destination.mac)
                    Text("Phones").tag(Config.Destination.phones)
                } label: {
                    Text("Notify on")
                    if model.config.notifications.destination == .phones { Text("Each client device must allow notifications from Yorozu.") }
                }.disabled(!model.config.notifications.enabled)
            }
            Section("Keyboard") {
                Toggle(isOn: Binding(get: { !general.globalShortcut.isEmpty }, set: { on in
                    shortcutProblem = nil; shortcut = on ? Self.shortcutPreset : ""
                    model.writeSettings { $0.general.globalShortcut = shortcut }
                })) {
                    Text("Global shortcut")
                    Text("Opens Yorozu from any app.")
                }
                if !general.globalShortcut.isEmpty {
                    TextField(text: $shortcut) {
                        Text("Shortcut")
                        if let problem = shortcutProblem ?? model.shortcutProblem { Text(problem) } else { Text("Modifiers and a key, such as option+space or cmd+shift+y. Press Return to apply.") }
                    }
                    .onSubmit {
                        let spec = shortcut.trimmingCharacters(in: .whitespaces)
                        guard GlobalShortcut.parse(spec) != nil else { shortcutProblem = String(localized: "Not a shortcut Yorozu understands: \(spec)"); return }
                        shortcutProblem = nil; model.writeSettings { $0.general.globalShortcut = spec }
                    }
                }
                Toggle(isOn: Binding(get: { general.sendKey == .cmdEnter }, set: { on in model.writeSettings { $0.general.sendKey = on ? .cmdEnter : .smart } })) {
                    Text("⌘Enter to send")
                    Text("Off: Enter sends a one-line message; once a draft has more lines, Enter adds a line and ⌘Enter sends. On: Enter always adds a line.")
                }
            }
            Section("Workers") {
                Toggle(isOn: model.setting(\.general.yolo)) {
                    Text("YOLO mode")
                    Text("Workers take outward-facing steps you asked for, and use risky computer-use tools, without asking first. Always held: settings changes and anything you did not ask for still need your word; no secrets; Yorozu never takes focus or touches other agents' sessions.")
                }
            }
            Section("Appearance") {
                Picker("Appearance", selection: model.setting(\.general.appearance)) {
                    Text("System").tag(Config.Appearance.system)
                    Text("Light").tag(Config.Appearance.light)
                    Text("Dark").tag(Config.Appearance.dark)
                }
                Toggle("Show Advanced settings", isOn: model.setting(\.general.showAdvanced))
            }
        }
        .settingsForm()
        .onAppear { shortcut = general.globalShortcut; model.refreshLoginItem() }
        .onChange(of: general.globalShortcut) { _, spec in shortcut = spec }
    }
}
