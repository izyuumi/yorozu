import Foundation
import SwiftUI
import YorozuShared

/// Approval settings in `<state dir>/approval.json` — the same file the runtime keeps its learned
/// rules in. Read-modify-write, because those rules are not ours to lose. The Mac owns the two
/// onboarding floors; Mac and iOS can both edit the global YOLO bypass.
enum ApprovalSettings {
    struct Floor: Equatable {
        /// Skip every approval gate until the user switches it off.
        var yolo: Bool
        /// Ask about any action at or above this amount.
        var moneyThreshold: Double
        /// Ask before deleting anything outside Yorozu's own directory.
        var confirmIrreversibleDeletes: Bool
    }

    static let defaults = Floor(yolo: false, moneyThreshold: 0, confirmIrreversibleDeletes: true)

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
            yolo: json["yolo"] as? Bool ?? defaults.yolo,
            moneyThreshold: json["moneyThreshold"] as? Double ?? defaults.moneyThreshold,
            confirmIrreversibleDeletes: json["confirmIrreversibleDeletes"] as? Bool
                ?? defaults.confirmIrreversibleDeletes
        )
    }

    static func save(_ floor: Floor) {
        var json = stored()
        json["yolo"] = floor.yolo
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

/// The onboarding step and Mac editor for the two floors and global YOLO bypass.
struct ApprovalFloorView: View {
    @State private var floor = ApprovalSettings.load()
    @State private var session = MacChatSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("YOLO mode — skip all approvals", isOn: $floor.yolo)
            if floor.yolo {
                Text("Every tool request runs without asking, including purchases, messages, commands, and deletes.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
        .onAppear {
            floor = ApprovalSettings.load()
            session.model.requestApprovalSettings()
        }
        .onChange(of: session.model.yoloMode) { _, enabled in floor.yolo = enabled }
        .onChange(of: floor) { old, new in
            ApprovalSettings.save(new)
            if old.yolo != new.yolo && session.model.yoloMode != new.yolo {
                session.model.setYoloMode(new.yolo)
            }
        }
    }
}

/// The stored rules, in the same `approval.json` the floor lives in. Read and written here
/// rather than over the socket: the Mac and the runtime share a disk, the runtime re-reads the
/// file on every decision, and Settings is not a chat window with a transport in it.
///
/// Read-modify-write throughout, because the floor and the runtime's own bookkeeping — a rule's
/// `lastUsed` and `useCount` — are not ours to lose.
extension ApprovalSettings {
    static func loadRules() -> [ApprovalRule] {
        guard let raw = stored()["rules"] as? [[String: Any]] else { return [] }
        // Decoded one at a time: one rule someone broke by hand must not empty the list.
        return raw.enumerated().compactMap { index, one in
            var one = one
            // A rule from before v1.5 has no id. The same synthesised one the runtime uses,
            // so revoking it here revokes the rule the runtime is actually applying — see
            // `normalizeRule` in packages/runtime/src/approval.ts.
            if one["id"] == nil { one["id"] = "legacy-\(index)" }
            // And its target was a bare string rather than a pattern.
            if one["scope"] == nil, let target = one["target"] as? String, !target.isEmpty {
                one["scope"] = ["target": ["mode": "exact", "value": target]]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: one) else { return nil }
            return try? JSONDecoder().decode(ApprovalRule.self, from: data)
        }
    }

    static func saveRules(_ rules: [ApprovalRule]) {
        var json = stored()
        guard let encoded = try? JSONEncoder().encode(rules),
              let array = try? JSONSerialization.jsonObject(with: encoded)
        else { return }
        json["rules"] = array
        // A file the runtime has not written yet still needs the floor keys to be valid.
        if json["moneyThreshold"] == nil { json["moneyThreshold"] = defaults.moneyThreshold }
        if json["confirmIrreversibleDeletes"] == nil {
            json["confirmIrreversibleDeletes"] = defaults.confirmIrreversibleDeletes
        }
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
