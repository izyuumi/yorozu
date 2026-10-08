import SwiftUI

/// The `Settings` scene (⌘, and Settings… in the menus): a shell for Pair iPhone and native enrollment until #312 builds its tabs.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// The window's width, the one size this pane owns: nothing proposes a width to a Settings window.
    private let width: CGFloat = 500
    var body: some View {
        Group {
            if model.runtimeMode == .live {
                TabView {
                    PairPhoneView(model: model).tabItem { Label("iPhone", systemImage: "iphone") }
                    if model.nativeSelected { EnrollmentView(model: model).tabItem { Label("Gateway", systemImage: "network") } }
                }
            } else {
                Text("Pairing and the Gateway are available in live mode only.").foregroundStyle(.secondary).padding()
            }
        }.frame(width: width)
    }
}

/// Enrolls Yorozu's own device with the local Gateway for the native transport.
struct EnrollmentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enroll Yorozu with the local Gateway").font(.headline)
            Text("This is a separate app device, not a model-provider login. The Gateway is loopback only. Enter its bootstrap token/password privately here; never put it in chat. Only Yorozu's own device token and generated key are saved in Keychain. A new device approval may be required. Leave blank to reconnect an enrolled device.").fixedSize(horizontal: false, vertical: true)
            SecureField("Gateway bootstrap secret (not saved)", text: $model.bootstrapSecret)
            Text(model.enrollmentNotice).font(.caption).textSelection(.enabled)
            HStack { Spacer(); Button(model.connecting ? "Connecting…" : "Connect") { Task { await model.enroll() } }.disabled(model.connecting) }
        }
        .padding(24)
        .onDisappear { model.bootstrapSecret = "" }
    }
}
