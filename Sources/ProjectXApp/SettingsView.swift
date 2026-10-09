import AppKit
import ProjectXCore
import SwiftUI

/// The `Settings` scene (⌘, and Settings… in the menus): native grouped forms over `config.toml` (#312). Advanced shows
/// only while General › Show Advanced settings is on.
struct SettingsView: View {
    enum Tab: Hashable { case general, devices, connection, storage, advanced }
    @ObservedObject var model: AppModel
    @State private var tab = Tab.general
    /// The window's width, the one size this pane owns: nothing proposes a width to a Settings window.
    private let width: CGFloat = 560
    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            DevicesSettings(model: model).tabItem { Label("Devices", systemImage: "iphone") }.tag(Tab.devices)
            ConnectionSettings(model: model) { model.writeSettings { $0.general.showAdvanced = true }; tab = .advanced }
                .tabItem { Label("Connection", systemImage: "network") }.tag(Tab.connection)
            StorageSettings(model: model).tabItem { Label("Storage", systemImage: "internaldrive") }.tag(Tab.storage)
            if model.config.general.showAdvanced {
                AdvancedSettings(model: model).tabItem { Label("Advanced", systemImage: "gearshape.2") }.tag(Tab.advanced)
            }
        }
        .frame(width: width)
        .onChange(of: model.config.general.showAdvanced) { _, on in if !on, tab == .advanced { tab = .general } }
    }
}

/// Settings reads the resolved values (environment overrides included) and writes the file through `writeSettings`.
extension AppModel {
    var config: Config { resolved?.config ?? Config() }
    /// Writes one file value; the row shows the resolved value.
    func setting<V>(_ path: WritableKeyPath<Config,V>) -> Binding<V> {
        Binding(get: { self.config[keyPath: path] }, set: { value in self.writeSettings { $0[keyPath: path] = value } })
    }
    /// The environment variable that sets `key` for this run, if any.
    func override(_ key: String) -> String? { resolved?.environment[key] }
}

/// "Set by `PROJECTX_…`": the subtitle of a row the environment overrides, which is then disabled.
func overrideNote(_ variable: String?) -> Text? { variable.map { Text("Set by `\($0)`") } }

/// A path as `~/…`.
func tildePath(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

/// A Settings write that failed, or a `config.toml` that does not load; first in a tab's form.
struct ConfigProblems: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let problem = model.settingsError ?? model.lastConfigError?.localizedDescription {
            Section {
                Label { Text(problem).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let file = model.configFile { Button("Show config.toml in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) } }
            }
        }
    }
}
