import Foundation

/// Correlation metadata only: never prompts, responses, auth values or raw CLI output.
public struct GatewayRequestReceipt: Codable, Sendable {
    public var requestID: String
    public var sessionKey: String?
    public var sourceMessageID: String?
    public var rawModelRun: Bool
    public var state: String
    public var created: Double
    public init(requestID: String, sessionKey: String?, sourceMessageID: String?, rawModelRun: Bool, state: String) {
        self.requestID = requestID; self.sessionKey = sessionKey; self.sourceMessageID = sourceMessageID
        self.rawModelRun = rawModelRun; self.state = state; self.created = Date().timeIntervalSince1970
    }
}
public typealias GatewayAudit = @Sendable (GatewayRequestReceipt) async throws -> Void
