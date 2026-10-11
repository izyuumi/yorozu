import AppKit
import ProjectXCore
import SwiftUI

/// Settings › General › This Mac: host Yorozu here, or use another Mac's as a client device does (owner, 2026-10-11, as in
/// v1). The role is read at launch, so a change relaunches the app.
struct RoleSection: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Section("This Mac") {
            Picker(selection: Binding(get: { model.config.general.role }, set: { role in
                guard role != model.config.general.role else { return }
                model.writeSettings { $0.general.role = role }
                model.relaunch()
            })) {
                Text("Host Yorozu here").tag(Config.Role.host)
                Text("Connect to another Mac").tag(Config.Role.client)
            } label: {
                Text("Role")
                Text(model.config.general.role == .host
                     ? "Agents run on this Mac, and your other devices connect to it."
                     : "This Mac uses Yorozu on your host Mac, as an iPhone does. Agents run there.")
            }
            Text("Yorozu restarts to apply a change.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Settings › Host, in the client role: the host this Mac uses, pairing with its code, and Repair and Remove.
struct HostSettings: View {
    @ObservedObject var model: AppModel
    @State private var code = ""
    @State private var problem: String?
    @State private var repairing = false
    @State private var removing = false

    var body: some View {
        Form {
            if let client = model.client {
                // `linked` is observed; the pairing itself is not, and turns true in the same step.
                if (client.linked || client.hasPairing) && !repairing {
                    Section("Host") {
                        LabeledContent("Name",value: client.hostName ?? String(localized: "Unknown"))
                        LabeledContent("Status",value: client.shownStatus.label)
                        if let fingerprint = client.fingerprint {
                            LabeledContent("Host key") { Text(fingerprint).monospaced().textSelection(.enabled) }
                        }
                        if let pairedAt = client.pairedAt {
                            LabeledContent("Paired since") { Text(pairedAt,format: .dateTime.year().month().day()) }
                        }
                        if let failure = client.updateRequired ?? client.failure { Text(failure).foregroundStyle(.secondary) }
                    }
                    Section {
                        Button("Pair again…") { repairing = true }
                        Button("Remove host",role: .destructive) { removing = true }
                    }
                } else {
                    Section {
                        TextField("Pairing code",text: $code,prompt: Text("Paste the host's pairing code"))
                        Button("Pair") {
                            problem = client.pair(with: code.trimmingCharacters(in: .whitespacesAndNewlines))
                        }.disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if repairing { Button("Cancel") { repairing = false; code = "" } }
                        if let problem { Text(problem).foregroundStyle(ChatPalette.warning) }
                    } header: {
                        Text("Pair with your host")
                    } footer: {
                        Text("On the host Mac, open Settings › Devices › Pair a Client Device, copy its code and paste it here.")
                    }
                }
            }
        }
        .settingsForm()
        .alert(
            model.client?.pendingPairing?.repair == true ? String(localized: "Already connected") : String(localized: "Add host?"),
            isPresented: Binding(get: { model.client?.pendingPairing != nil }, set: { if !$0 { model.client?.pendingPairing = nil } }),
            presenting: model.client?.pendingPairing
        ) { pending in
            Button("Connect") {
                Task { await model.client?.confirm(pending); code = ""; repairing = false; problem = nil }
            }
            Button("Cancel",role: .cancel) { model.client?.pendingPairing = nil }
        } message: { pending in
            Text("Check that the host key matches the one the host shows: \(pending.fingerprint)")
        }
        .confirmationDialog("Remove host?",isPresented: $removing,titleVisibility: .visible) {
            Button("Remove host",role: .destructive) { Task { await model.client?.remove() } }
        }
    }
}

extension AppModel {
    /// Quits and opens this same app again (a role change applies at launch).
    /// The new instance opens only once this one has exited and let go of its data folder.
    func relaunch() {
        let wait = Process()
        wait.executableURL = URL(fileURLWithPath: "/bin/sh")
        wait.arguments = ["-c","while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open -n \"$0\"",Bundle.main.bundlePath]
        try? wait.run()
        NSApp.terminate(nil)
    }
}
