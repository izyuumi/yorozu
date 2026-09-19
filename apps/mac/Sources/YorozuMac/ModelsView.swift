import Foundation
import SwiftUI

/// Models settings: which knowledge source auto-assign reads, a button that runs it now and
/// shows the diff it wrote, and the cron that repeats it. Every one of them is a subcommand
/// of the sidecar the app already spawns. See docs/spec-v1.html section 2.
enum ModelSettings {
    static let modeKey = "YOROZU_ASSIGN_MODE"
    static let cronKey = "YOROZU_ASSIGN_CRON"

    static let catalog = "catalog"
    static let research = "research"

    /// The cron goes into a `/bin/sh -c` command line, so it is reduced to the characters a
    /// 5-field expression is made of before it ever gets there.
    static func sanitize(_ cron: String) -> String {
        cron.filter { "0123456789*/,- ".contains($0) }
    }
}

@MainActor
final class AutoAssign: ObservableObject {
    /// Non-nil while the diff sheet is up. Empty runs still show, saying nothing changed.
    @Published var diff: String?
    @Published private(set) var running = false

    func assign(mode: String) {
        guard !running else { return }
        running = true
        Task { [weak self] in
            let output = await Self.run("assign \(mode == ModelSettings.research ? ModelSettings.research : ModelSettings.catalog)")
            self?.diff = output.isEmpty ? "No changes: every agent already has the model for it." : output
            self?.running = false
        }
    }

    func revert() {
        Task { [weak self] in
            _ = await Self.run("assign-revert")
            self?.diff = nil
        }
    }

    func schedule(_ cron: String, mode: String) {
        let expression = ModelSettings.sanitize(cron)
        Task { _ = await Self.run("assign-cron '\(expression)' \(mode)") }
    }

    private static func run(_ arguments: String) async -> String {
        await Task.detached {
            String(data: RuntimeCommand.output(arguments) ?? Data(), encoding: .utf8) ?? ""
        }.value
    }
}

struct ModelsView: View {
    @AppStorage(ModelSettings.modeKey) private var mode = ModelSettings.catalog
    @AppStorage(ModelSettings.cronKey) private var cron = ""
    @StateObject private var assign = AutoAssign()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Knowledge source", selection: $mode) {
                Text("GitHub catalog").tag(ModelSettings.catalog)
                Text("Research prices on the web").tag(ModelSettings.research)
            }
            .labelsHidden()

            Button(assign.running ? "Assigning…" : "Assign now") { assign.assign(mode: mode) }
                .disabled(assign.running)

            TextField("0 4 * * 1", text: $cron)
                .onSubmit { assign.schedule(cron, mode: mode) }
            Text("Cron to repeat the assignment. Empty unschedules it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .sheet(isPresented: Binding(
            get: { assign.diff != nil },
            set: { if !$0 { assign.diff = nil } }
        )) {
            diffSheet(assign.diff ?? "")
        }
    }

    /// The run is already written to disk: Revert is what undoes it, not dismissing this.
    @ViewBuilder
    private func diffSheet(_ diff: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Auto-assign").font(.headline)
            ScrollView {
                Text(diff)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 460, height: 300)
            HStack {
                Button("Revert") { assign.revert() }
                Spacer()
                Button("Done") { assign.diff = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onExitCommand { assign.diff = nil }
    }
}
