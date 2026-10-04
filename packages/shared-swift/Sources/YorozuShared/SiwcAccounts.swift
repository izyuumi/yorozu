import Foundation

enum SiwcAccountWire {
    static func keys(_ decoder: Decoder, _ allowed: [String]) throws {
        let c = try decoder.container(keyedBy: PersonAgentWire.Key.self)
        for key in c.allKeys {
            guard allowed.contains(key.stringValue), try !c.decodeNil(forKey: key) else { throw invalid(decoder) }
        }
    }
    static func invalid(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid account settings data"))
    }
    static func id(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 128 && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 58, 95].contains($0)
        }
    }
}

/// The containing event ID is the operation ID. No authorization data belongs here.
public struct SiwcAccountControlData: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        case signIn = "sign-in", cancel, verifyPending = "verify-pending", select, signOut = "sign-out", status
    }
    public var version: Int = 1
    public var method: Method
    public var bindingId: String?
    public var returning: Bool?
    public var attemptId: String?
    public init(method: Method, bindingId: String? = nil, returning: Bool? = nil, attemptId: String? = nil) {
        self.method = method; self.bindingId = bindingId; self.returning = returning; self.attemptId = attemptId
    }
    public var isValid: Bool {
        guard version == 1, bindingId.map(SiwcAccountWire.id) ?? true, attemptId.map(SiwcAccountWire.id) ?? true else { return false }
        switch method {
        case .signIn: return attemptId == nil && (returning != true || bindingId != nil)
        case .cancel: return attemptId != nil && bindingId == nil && returning == nil
        case .verifyPending, .select, .signOut: return bindingId != nil && returning == nil && attemptId == nil
        case .status: return bindingId == nil && returning == nil && attemptId == nil
        }
    }
    private enum CodingKeys: String, CodingKey { case version, method, bindingId, returning, attemptId }
    public init(from decoder: Decoder) throws {
        try SiwcAccountWire.keys(decoder, ["version", "method", "bindingId", "returning", "attemptId"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version); method = try c.decode(Method.self, forKey: .method)
        bindingId = try c.decodeIfPresent(String.self, forKey: .bindingId); returning = try c.decodeIfPresent(Bool.self, forKey: .returning)
        attemptId = try c.decodeIfPresent(String.self, forKey: .attemptId)
        guard isValid else { throw SiwcAccountWire.invalid(decoder) }
    }
}

public struct SiwcAccountControlResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, completed, rejected, unknown }
    public enum Reason: String, Codable, Sendable {
        case unsupported, invalid, identity, permission, conflict, unknown, signedOut = "signed-out"
        case localSignInRequired = "local-sign-in-required", busy
    }
    public var operationId: String
    public var status: Status
    public var attemptId: String?
    public var reason: Reason?
    public init(operationId: String, status: Status, attemptId: String? = nil, reason: Reason? = nil) {
        self.operationId = operationId; self.status = status; self.attemptId = attemptId; self.reason = reason
    }
    public var isValid: Bool {
        SiwcAccountWire.id(operationId) && (attemptId.map(SiwcAccountWire.id) ?? true) && (attemptId == nil || status == .pending)
    }
    private enum CodingKeys: String, CodingKey { case operationId, status, attemptId, reason }
    public init(from decoder: Decoder) throws {
        try SiwcAccountWire.keys(decoder, ["operationId", "status", "attemptId", "reason"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationId = try c.decode(String.self, forKey: .operationId); status = try c.decode(Status.self, forKey: .status)
        attemptId = try c.decodeIfPresent(String.self, forKey: .attemptId); reason = try c.decodeIfPresent(Reason.self, forKey: .reason)
        guard isValid else { throw SiwcAccountWire.invalid(decoder) }
    }
}

public struct SiwcAccountSummary: Codable, Equatable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable { case ready, signedOut = "signed-out", unknown }
    public enum RemoteRevocation: String, Codable, Sendable { case confirmed, unconfirmed }
    public var accountBindingId: String
    public var phase: Phase
    public var planUse: Bool
    public var active: Bool
    public var remoteRevocation: RemoteRevocation?
    public var id: String { accountBindingId }
    public init(accountBindingId: String, phase: Phase, planUse: Bool, active: Bool, remoteRevocation: RemoteRevocation? = nil) {
        self.accountBindingId = accountBindingId; self.phase = phase; self.planUse = planUse; self.active = active; self.remoteRevocation = remoteRevocation
    }
    public var isValid: Bool { SiwcAccountWire.id(accountBindingId) && (!planUse || phase == .ready) }
    private enum CodingKeys: String, CodingKey { case accountBindingId, phase, planUse, active, remoteRevocation }
    public init(from decoder: Decoder) throws {
        try SiwcAccountWire.keys(decoder, ["accountBindingId", "phase", "planUse", "active", "remoteRevocation"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountBindingId = try c.decode(String.self, forKey: .accountBindingId); phase = try c.decode(Phase.self, forKey: .phase)
        planUse = try c.decode(Bool.self, forKey: .planUse); active = try c.decode(Bool.self, forKey: .active)
        remoteRevocation = try c.decodeIfPresent(RemoteRevocation.self, forKey: .remoteRevocation)
        guard isValid else { throw SiwcAccountWire.invalid(decoder) }
    }
}

/// Host projection of lifecycle status. This is never a credential or login callback.
public struct SiwcAccountStatusData: Codable, Equatable, Sendable {
    public enum NativeIntegration: String, Codable, Sendable { case unwired, wiredUnverified = "wired-unverified" }
    public enum State: String, Codable, Sendable { case available, unsupported, unknown }
    public var version: Int = 1
    public var productionReady: Bool = false
    public var nativeIntegration: NativeIntegration
    public var available: Bool
    public var state: State
    public var revision: Int?
    public var activeAccountBindingId: String?
    public var accounts: [SiwcAccountSummary]
    public var lastControlResult: SiwcAccountControlResult?
    public init(nativeIntegration: NativeIntegration, available: Bool, state: State, revision: Int? = nil,
        activeAccountBindingId: String? = nil, accounts: [SiwcAccountSummary] = [], lastControlResult: SiwcAccountControlResult? = nil) {
        self.nativeIntegration = nativeIntegration; self.available = available; self.state = state; self.revision = revision
        self.activeAccountBindingId = activeAccountBindingId; self.accounts = accounts; self.lastControlResult = lastControlResult
    }
    public var isValid: Bool {
        guard version == 1, !productionReady, available == (state == .available),
              revision.map(PersonAgentWire.revision) ?? !available, accounts.count <= 32,
              accounts.allSatisfy(\.isValid), Set(accounts.map(\.id)).count == accounts.count,
              activeAccountBindingId.map(SiwcAccountWire.id) ?? true, lastControlResult?.isValid ?? true else { return false }
        let active = accounts.filter(\.active)
        return active.count <= 1 && active.first?.accountBindingId == activeAccountBindingId
            && (available || accounts.isEmpty && activeAccountBindingId == nil)
    }
    private enum CodingKeys: String, CodingKey {
        case version, productionReady, nativeIntegration, available, state, revision, activeAccountBindingId, accounts, lastControlResult
    }
    public init(from decoder: Decoder) throws {
        try SiwcAccountWire.keys(decoder, ["version", "productionReady", "nativeIntegration", "available", "state", "revision", "activeAccountBindingId", "accounts", "lastControlResult"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version); productionReady = try c.decode(Bool.self, forKey: .productionReady)
        nativeIntegration = try c.decode(NativeIntegration.self, forKey: .nativeIntegration)
        available = try c.decode(Bool.self, forKey: .available); state = try c.decode(State.self, forKey: .state)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision); activeAccountBindingId = try c.decodeIfPresent(String.self, forKey: .activeAccountBindingId)
        accounts = try c.decode([SiwcAccountSummary].self, forKey: .accounts); lastControlResult = try c.decodeIfPresent(SiwcAccountControlResult.self, forKey: .lastControlResult)
        guard isValid else { throw SiwcAccountWire.invalid(decoder) }
    }
}
