import Foundation

/// One request a harness adapter sends a model run (receipt kind `request`; rows written before #318 have kind
/// `gateway-request` and no `harness`). Written durably before dispatch: if that write fails, nothing is sent.
/// Correlation metadata only: never prompts, responses, auth values or raw transport output.
public struct RequestReceipt: Codable, Sendable {
    public var requestID: String
    /// The harness id (`openclaw`, `hermes`); nil on older rows, which are all OpenClaw.
    public var harness: String?
    /// The harness's session the request went to, if any.
    public var sessionKey: String?
    public var sourceMessageID: String?
    /// A stateless role run (secretary, review, extraction): a lost one never blocks the next.
    public var rawModelRun: Bool
    public var state: String
    public var created: Double
    public init(requestID: String, harness: String, sessionKey: String?, sourceMessageID: String?, rawModelRun: Bool, state: String) {
        self.requestID = requestID; self.harness = harness; self.sessionKey = sessionKey; self.sourceMessageID = sourceMessageID
        self.rawModelRun = rawModelRun; self.state = state; self.created = Date().timeIntervalSince1970
    }
}
public typealias RequestAudit = @Sendable (RequestReceipt) async throws -> Void
