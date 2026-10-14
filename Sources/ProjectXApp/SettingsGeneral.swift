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
            RoleSection(model: model)
            Section("Startup") {
                if !model.isClient { LabeledContent {
                    Button("Run Setup Again…") { model.openSetup() }
                } label: {
                    HStack(spacing: 6) {
                        ReadinessDot(state: model.readiness?.state)
                        if let r = model.readiness { Text(r.state == .ready ? String(localized: "Setup: Ready") : r.summary) } else { Text("Setup: checking…") }
                    }
                } }
                Toggle(isOn: Binding(get: { general.startAtLogin && model.loginItemBlocker == nil }, set: { on in model.writeSettings { $0.general.startAtLogin = on } })) {
                    Text("Start at login")
                    if let blocker = model.loginItemBlocker { Text(blocker) }
                    else if general.startAtLogin, model.loginItemStatus == .requiresApproval { Text("Waiting for your approval in System Settings › General › Login Items.") }
                }.disabled(model.loginItemBlocker != nil)
                if model.loginItemBlocker == nil, general.startAtLogin, model.loginItemStatus == .requiresApproval {
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if !model.isClient {
                    Toggle(isOn: model.setting(\.general.keepMacAwake)) {
                        Text("Keep the host awake")
                        Text("Workers and client devices need the host awake. A closed lid still sleeps.")
                    }
                }
            }
            if Updates.shared.available {
                Section("Updates") {
                    Toggle(isOn: Binding(get: { Updates.shared.beta }, set: { Updates.shared.beta = $0 })) {
                        Text("Get beta updates")
                        Text("Updates install on their own once no task is running.")
                    }
                    Button("Check for Updates…") { Updates.shared.check() }
                }
            }
            Section("Notifications") {
                Toggle(isOn: model.setting(\.notifications.enabled)) {
                    Text("Show notifications")
                    Text("For results, failures and questions. Nothing is shown while you are reading the latest message.")
                }
                // Where the host posts them; a client only shows its own.
                if !model.isClient {
                    Picker(selection: model.setting(\.notifications.destination)) {
                        Text("This host").tag(Config.Destination.mac)
                        Text("Phones").tag(Config.Destination.phones)
                    } label: {
                        Text("Notify on")
                        if model.config.notifications.destination == .phones { Text("Each client device must allow notifications from Yorozu.") }
                    }.disabled(!model.config.notifications.enabled)
                }
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
            if !model.isClient { Section("Workers") {
                Toggle(isOn: model.setting(\.general.yolo)) {
                    Text("YOLO mode")
                    Text("Workers take outward-facing steps you asked for, and use risky computer-use tools, without asking first. Always held: settings changes and anything you did not ask for still need your word; no secrets; Yorozu never takes focus or touches other agents' sessions.")
                }
            } }
            Section("Appearance") {
                Picker("Appearance", selection: model.setting(\.general.appearance)) {
                    Text("System").tag(Config.Appearance.system)
                    Text("Light").tag(Config.Appearance.light)
                    Text("Dark").tag(Config.Appearance.dark)
                }
                if !model.isClient { Toggle("Show Advanced settings", isOn: model.setting(\.general.showAdvanced)) }
            }
        }
        .settingsForm()
        .onAppear { shortcut = general.globalShortcut; model.refreshLoginItem() }
        .onChange(of: general.globalShortcut) { _, spec in shortcut = spec }
    }
}

/// Settings › Chats (#405, split from General so no tab passes a 1080-point screen): the host-wide Main chat with its
/// own entry point, and on a client Mac the unsent reminder.
struct ChatsSettings: View {
    @ObservedObject var model: AppModel
    @State private var reminderMinutes = LocalNotices.reminderMinutes

    var body: some View {
        let pending = model.client?.mainChatPending
        Form {
            ConfigProblems(model: model)
            // Host-wide: one setting all client devices share; a client Mac changes it on the host and shows its answer.
            Section {
                Toggle(isOn: Binding(get: { pending ?? model.mainChat },set: { model.setMainChat($0) })) {
                    HStack(spacing: 6) {
                        Text("Main chat")
                        if pending != nil { ProgressView().controlSize(.small).accessibilityLabel("Applying on the host") }
                    }
                    Text("One conversation where the secretary files work into chats across topics. Off: every chat stands on its own, and the menu-bar icon opens Quick Chat. Its history stays either way.")
                }.disabled(model.isClient && (model.client?.state != .paired || model.client?.hostSettingsSupported != true || pending != nil))
                if model.mainChat {
                    Button("Open Main chat") { model.chatFocus = ChatFocus(thread: nil,message: nil); model.openChatWindow?() }
                }
                if let error = model.client?.mainChatError { Text(error).foregroundStyle(ChatPalette.warning) }
            } header: { Text("Main chat") }
            if model.isClient {
                Section("Unsent messages") {
                    Picker(selection: Binding(get: { LocalNotices.reminderMinutes },set: { model.client?.setReminder(minutes: $0); reminderMinutes = $0 })) {
                        ForEach(LocalNotices.reminderChoices,id: \.self) { m in
                            Text(m == 0 ? String(localized: "Off") : Duration.seconds(m * 60).formatted(.units(allowed: [.hours,.minutes],width: .wide))).tag(m)
                        }
                    } label: {
                        Text("Reminder")
                        Text("A notification when a message hasn't reached the host this long after you sent it.")
                    }.id(reminderMinutes)
                }
            }
        }
        .settingsForm()
    }
}
