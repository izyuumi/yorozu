import SwiftUI

/// One host-owned switch. The warning is on every off-to-on transition, on every device.
public struct TerminalAccessSettings: View {
    public let model: ChatModel
    @State private var confirming = false
    @State private var turningOn = false

    public init(model: ChatModel) { self.model = model }

    public var body: some View {
        // The live typed status reply proves support, including hosts predating peer-info.
        // Older hosts never answer this probe, so do not offer them an inert toggle.
        if model.terminalEpoch?.isEmpty == false { terminalSection }
    }

    private var terminalSection: some View {
        Section {
            Toggle("Terminal access", isOn: Binding(
                get: { model.terminalEnabled },
                set: { enabled in
                    turningOn = enabled
                    if enabled || !model.terminalSessions.isEmpty { confirming = true }
                    else { model.terminal(.disable) }
                }
            ))
            .disabled(!model.canDeliver)
        } header: {
            Text("Advanced developer settings")
        } footer: {
            Text("Paired devices can run shell commands as the host Mac user while terminal access is on.")
        }
        .alert(turningOn ? "Enable terminal access?" : "Turn off terminal access?", isPresented: $confirming) {
            if turningOn {
                Button("Enable terminal access") { model.terminal(.enable) }
            } else {
                Button("Close sessions and turn off", role: .destructive) { model.terminal(.disable) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if turningOn {
                Text("Every paired device, including devices paired before this feature, can run arbitrary commands as the host Mac user. Only enable this if you trust every paired device.")
            } else {
                Text("All open terminal sessions and their running jobs will end immediately.")
            }
        }
    }
}
