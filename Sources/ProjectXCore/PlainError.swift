import Foundation

/// A known setup failure in plain words (#317), for notices, the status line and the readiness model. `cause` is a stable
/// id the app localizes (`NoticeText.plain`), with `subject` (the model or file it names); `title` is the English
/// sentence; `detail` is the raw text, OpenClaw's own hint included, for Details.
public struct PlainError: Sendable, Equatable {
    public var cause: String, title: String, detail: String, subject: String?
    /// Nil for an error with no known cause: show its raw text as before.
    public static func describe(_ error: Error) -> PlainError? {
        if let m = error as? MemoryFileError { return PlainError(cause: "memory_file",title: "Yorozu's memory can't load \(m.file)",detail: m.localizedDescription,subject: m.file) }
        return describe(error.localizedDescription)
    }
    public static func describe(_ raw: String) -> PlainError? {
        func plain(_ cause: String,_ title: String,_ subject: String? = nil) -> PlainError { PlainError(cause: cause,title: title,detail: raw,subject: subject) }
        let s = raw.lowercased()
        // Yorozu's own refusals (`GatewayRPC.enforceAttribution`, `Store`), then `GatewayRPC` categories, then OpenClaw's error texts.
        if s.contains("caller-attribution") { return plain("exec_markers",String(localized: "Yorozu was started from an agent's shell; open it from Finder")) }
        if s.contains("data directory is already open") { return plain("already_running",String(localized: "Yorozu is already running")) }
        if s.contains(OpenClawSetup.personalAgent.lowercased()) { return plain("personal_agent",OpenClawSetup.personalAgent) }
        // Only the shapes `GatewayRPC` writes: worker errors may quote anything.
        if s.contains("gateway cli failed [exit=127,") || s.contains("category=executable-or-runtime]") || s.contains("[category=executable-unavailable]") { return plain("openclaw_missing",String(localized: "OpenClaw or Node.js isn't installed")) }
        if s.contains("category=gateway-unreachable]") { return plain("gateway_down",String(localized: "The OpenClaw Gateway isn't running. Start it with `openclaw gateway run`.")) }
        if let m = raw.firstMatch(of: #/category=gateway-target-mismatch, target=([^\]\s]+)\]/#) {
            let url = String(m.1)
            return plain("gateway_target",String(localized: "Nothing answers at \(url); check [harness] gateway_url"),url)
        }
        if s.contains(HermesHarness.copilotRefusal.lowercased()) { return plain("hermes_copilot",String(localized: "Hermes uses GitHub Copilot, which Yorozu doesn't use")) } // HermesHarness.split
        if s.contains("not connected to any ai provider") { return plain("hermes_no_provider",String(localized: "Hermes isn't connected to an AI provider")) } // hermes_cli/auth.py, no_provider_configured
        if s.contains("unknown agent id") { return plain("agent_missing",String(localized: "Yorozu's agent isn't set up in OpenClaw")) }
        if let m = raw.firstMatch(of: #/(?i)model not allowed:\s*([^\s"'`,;]+)/#) {
            let model = String(m.1).trimmingCharacters(in: CharacterSet(charactersIn: ".)"))
            return plain("model_not_allowed",String(localized: "OpenClaw doesn't allow \(model) for Yorozu"),model)
        }
        return nil
    }
}
public extension Notice {
    /// A failure notice: the raw error in `error` (Details), plus a known setup cause (`PlainError`) for its plain sentence.
    init(_ code: Code, error: Error) {
        var params = ["error": error.localizedDescription]
        if let plain = PlainError.describe(error) { params["cause"] = plain.cause; params["subject"] = plain.subject }
        self.init(code,params)
    }
}
