import SwiftUI

/// The production schedule adapter is not implemented. Keep this explicit even when the
/// chat connection is healthy; an unavailable service is not an empty schedule list.
public struct SchedulesUnavailableView: View {
    private let models: [ChatModel]
    private let onSettings: () -> Void

    public init(models: [ChatModel], onSettings: @escaping () -> Void) {
        self.models = models
        self.onSettings = onSettings
    }

    public var body: some View {
        List {
            Section {
                Label("Schedules unavailable", systemImage: "calendar.badge.exclamationmark")
                    .font(.scaled(.headline))
                Text("This version of Yorozu cannot display or manage schedules yet. Existing schedules are not changed.")
                Text("You can continue chatting. Scheduled work needs a separate connection that has not been enabled in Yorozu.")
                    .foregroundStyle(.secondary)
            }
            Section("Connection") {
                if models.isEmpty {
                    Label("No Mac connected", systemImage: "desktopcomputer")
                    Text("Connect your Mac in Settings to use chat. Connecting chat does not enable schedules.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(models.indices, id: \.self) { index in
                        ChatConnectionSummary(model: models[index])
                    }
                }
                Button("Open Settings", systemImage: "gearshape", action: onSettings)
            }
        }
        .navigationTitle("Schedules")
    }
}

/// Transport, compatibility and provider execution are distinct checks. This summary uses
/// live transport state, not the brief visual grace used by connection toasts.
public struct ChatConnectionSummary: View {
    public let model: ChatModel
    public init(model: ChatModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
            if case .updateRequired = model.compatibility {
                Label("Update required", systemImage: "arrow.down.circle")
                Text("Update Yorozu on your Mac before sending messages.")
                    .foregroundStyle(.secondary)
            } else {
                Label(ClientConnectionStatus(state: model.state, ownerOnline: model.ownerOnline,
                    failure: nil).label, systemImage: model.canDeliver ? "checkmark.circle" : "link")
                Text(model.canDeliver
                    ? String(localized: "Chat is connected. The assistant must also be set up on your Mac to answer.")
                    : String(localized: "Saved chats and drafts remain available. Messages wait until your Mac reconnects."))
                    .foregroundStyle(.secondary)
            }
            if let name = model.peerInfo?.computerName { Text(name).font(.scaled(.caption)).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}
