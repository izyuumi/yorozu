import Foundation

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
        case .unknown: return String(localized: "Update waiting · checking agent status")
        case .waiting:
            return activeThreads == 1 ? String(localized: "Update queued · 1 agent working")
                : String(localized: "Update queued · \(activeThreads ?? 0) agents working")
        case .countdown: return String(localized: "Restarting in \(max(0, Int(ceil((deadline ?? 0) / 1000 - date.timeIntervalSince1970))))s")
        case .postponed: return String(localized: "Update postponed until \(Date(timeIntervalSince1970: (postponedUntil ?? 0) / 1000).formatted(date: .omitted, time: .shortened))")
        case .draining: return String(localized: "Finishing agent work before update")
        case .installing: return String(localized: "Updating · waiting for Mac to restart")
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
