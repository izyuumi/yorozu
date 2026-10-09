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
        if s.contains("caller-attribution") { return plain("exec_markers","Yorozu was started from an agent's shell; open it from Finder") }
        if s.contains("data directory is already open") { return plain("already_running","Yorozu is already running") }
        if s.contains("exit=127") || s.contains("category=executable-") { return plain("openclaw_missing","OpenClaw or Node.js isn't installed") }
        if s.contains("category=gateway-unreachable") || s.contains("could not connect to the server") { return plain("gateway_down","The OpenClaw Gateway isn't running. Start it with `openclaw gateway run`.") }
        if s.contains("unknown agent id") { return plain("agent_missing","Yorozu's agent isn't set up in OpenClaw") }
        if let m = raw.firstMatch(of: #/(?i)model not allowed:\s*([^\s"'`,;]+)/#) {
            let model = String(m.1).trimmingCharacters(in: CharacterSet(charactersIn: ".)"))
            return plain("model_not_allowed","OpenClaw doesn't allow \(model) for Yorozu",model)
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
