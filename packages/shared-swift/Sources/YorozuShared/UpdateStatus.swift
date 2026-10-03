import Foundation
import SwiftUI

public struct UpdateStatusData: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case none, unknown, waiting, countdown, postponed, draining, installing
    }
    public var phase: Phase
    public var updateId: String?
    public var version: String?
    public var activeThreads: Int?
    public var deadline: Double?
    public var postponedUntil: Double?
    public var requestId: String?

    public init(phase: Phase, updateId: String? = nil, version: String? = nil,
                deadline: Double? = nil, postponedUntil: Double? = nil) {
        self.phase = phase
        self.updateId = updateId
        self.version = version
        self.deadline = deadline
        self.postponedUntil = postponedUntil
    }

    public func label(at date: Date = Date()) -> String {
        switch phase {
        case .none: return ""
        case .unknown: return SecretaryUI.localized("Update waiting · checking agent status")
        case .waiting:
            return activeThreads == 1 ? SecretaryUI.localized("Update queued · 1 agent working")
                : SecretaryUI.localized("Update queued · \(activeThreads ?? 0) agents working")
        case .countdown: return SecretaryUI.localized("Restarting in \(max(0, Int(ceil((deadline ?? 0) / 1000 - date.timeIntervalSince1970))))s")
        case .postponed: return SecretaryUI.localized("Update postponed until \(Date(timeIntervalSince1970: (postponedUntil ?? 0) / 1000).formatted(date: .omitted, time: .shortened))")
        case .draining: return SecretaryUI.localized("Finishing agent work before update")
        case .installing: return SecretaryUI.localized("Updating · waiting for Mac to restart")
        }
    }
}

public struct UpdateControlData: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case queue, poll, cancel, postpone, installNow = "install_now", status }
    public var action: Action
    public var updateId: String?
    public var version: String?

    public init(action: Action, updateId: String? = nil, version: String? = nil) {
        self.action = action
        self.updateId = updateId
        self.version = version
    }
}

/// A host-qualified update notice for a thread list. The action stays bound to its host.
public struct UpdateStatusItem: Identifiable {
    public let id: String
    public let hostLabel: String?
    public let status: UpdateStatusData
    public let postpone: () -> Void
    public let installNow: (() -> Void)?

    public init(id: String, hostLabel: String? = nil, status: UpdateStatusData,
                postpone: @escaping () -> Void, installNow: (() -> Void)? = nil) {
        self.id = id
        self.hostLabel = hostLabel
        self.status = status
        self.postpone = postpone
        self.installNow = installNow
    }
}

public struct UpdateStatusView: View {
    public var status: UpdateStatusData
    public var hostLabel: String?
    public var postpone: () -> Void
    public var installNow: (() -> Void)?

    public init(status: UpdateStatusData, hostLabel: String? = nil, postpone: @escaping () -> Void,
                installNow: (() -> Void)? = nil) {
        self.status = status
        self.hostLabel = hostLabel
        self.postpone = postpone
        self.installNow = installNow
    }

    public var body: some View {
        if status.phase != .none {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    if let hostLabel {
                        Text(hostLabel).font(.scaled(.subheadline).weight(.semibold))
                    }
                    Label(status.label(at: context.date), systemImage: "arrow.down.circle")
                        .font(.scaled(.callout))
                    if status.phase != .installing {
                        HStack {
                            if let installNow { Button("Install now", action: installNow) }
                            Button("Postpone 1 hour", action: postpone)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary)
            }
        }
    }
}
