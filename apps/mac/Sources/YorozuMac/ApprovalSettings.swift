import Foundation
import SwiftUI

/// The two floor settings from onboarding, in `<state dir>/approval.json` — the same file the
/// runtime keeps its learned rules in. Read-modify-write, because those rules are not ours to
/// lose. See docs/spec-v1.html section 6.
enum ApprovalSettings {
    struct Floor: Equatable {
        /// Ask about any action at or above this amount.
        var moneyThreshold: Double
        /// Ask before deleting anything outside Yorozu's own directory.
        var confirmIrreversibleDeletes: Bool
    }

    static let defaults = Floor(moneyThreshold: 0, confirmIrreversibleDeletes: true)

    /// Kept in step with `stateDir()` in packages/runtime/src/memory.ts.
    static var file: URL {
        let dir = ProcessInfo.processInfo.environment["YOROZU_STATE_DIR"].map {
            URL(fileURLWithPath: $0)
        } ?? URL.applicationSupportDirectory.appending(path: "Yorozu")
        return dir.appending(path: "approval.json")
    }

    private static func stored() -> [String: Any] {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    static func load() -> Floor {
        let json = stored()
        return Floor(
            moneyThreshold: json["moneyThreshold"] as? Double ?? defaults.moneyThreshold,
            confirmIrreversibleDeletes: json["confirmIrreversibleDeletes"] as? Bool
                ?? defaults.confirmIrreversibleDeletes
        )
    }

    static func save(_ floor: Floor) {
        var json = stored()
        json["moneyThreshold"] = floor.moneyThreshold
        json["confirmIrreversibleDeletes"] = floor.confirmIrreversibleDeletes
        // A file the runtime has not written yet still needs the key to be valid on its side.
        if json["rules"] == nil { json["rules"] = [] }
        guard let data = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: file)
    }
}

/// The onboarding step, and the one place these two settings are edited.
struct ApprovalFloorView: View {
    @State private var floor = ApprovalSettings.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Always ask at or above")
                TextField(
                    "0",
                    value: $floor.moneyThreshold,
                    format: .currency(code: Locale.current.currency?.identifier ?? "USD")
                )
                .frame(width: 110)
            }
            Toggle("Confirm deletes outside Yorozu's own folder", isOn: $floor.confirmIrreversibleDeletes)
        }
        .onChange(of: floor) { ApprovalSettings.save(floor) }
    }
}
