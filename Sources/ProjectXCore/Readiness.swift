import Foundation

/// Whether Yorozu can answer (#317), in plain words: items with a fix, and the overall state. Blocked only when no
/// harness is installed at all, or the agent is the user's own (OpenClaw's default); everything else wrong is a warning.
/// The app maps it to the wire's `ReadinessData`.
public struct Readiness: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public enum Severity: String, Sendable { case ok, warning, blocking }
        /// What the user can do; Yorozu never runs a fix itself.
        public enum Fix: Sendable, Equatable {
            /// Open the setup window at this step (`SetupEngine.order`).
            case step(String)
            case copy(title: String, command: String)
            case open(title: String, url: URL)
            /// A one-line hint for phones (the wire's `fix`).
            public var hint: String {
                switch self { case .step(let id): String(localized: "Setup › \(SetupEngine.titles[id] ?? id)"); case .copy(_,let command): command; case .open(_,let url): url.absoluteString }
            }
            public init(_ fix: Integration.Fix) {
                switch fix { case .copy(let t,let c): self = .copy(title: String(localized: String.LocalizationValue(t)),command: c); case .open(let t,let u): self = .open(title: String(localized: String.LocalizationValue(t)),url: u) }
            }
        }
        /// Stable id, such as `openclaw.gateway`; `title` is plain language; `detail` is the raw text for Details.
        public var id: String, title: String, detail: String, severity: Severity, fix: Fix?
        public init(id: String, title: String, detail: String = "", severity: Severity, fix: Fix? = nil) { self.id = id; self.title = title; self.detail = detail; self.severity = severity; self.fix = fix }
    }
    public enum State: Sendable, Equatable { case ready, attention(Int), blocked }
    public var items: [Item]
    public init(items: [Item] = []) { self.items = items }
    /// Items that need attention (warning or blocking).
    public var count: Int { items.filter { $0.severity != .ok }.count }
    public var state: State { items.contains { $0.severity == .blocking } ? .blocked : count > 0 ? .attention(count) : .ready }
    /// "Ready", "N items need attention", or the first blocking item's title.
    public var summary: String {
        switch state { case .ready: String(localized: "Ready"); case .attention(let n): n == 1 ? String(localized: "1 item needs attention") : String(localized: "\(n) items need attention"); case .blocked: items.first { $0.severity == .blocking }!.title }
    }

    /// The main harness's readiness: its detection, Gateway `health` included. The app runs it at launch and again after a
    /// Gateway call fails. A main harness that is not installed blocks only when no other harness is installed either.
    public static func harness(_ settings: Config.HarnessSettings, rpc: GatewayRPC) async -> Readiness {
        let main = settings.kind.adapter(settings,rpc: rpc), d = await main.detect()
        guard !d.installed, Config.HarnessKind.allCases.contains(where: { $0 != settings.kind && $0.adapter(settings,rpc: rpc).installed }) else { return Readiness(items: d.items) }
        return Readiness(items: d.items.map { var i = $0; if i.severity == .blocking { i.severity = .warning; i.fix = .step("harness") }; return i })
    }
}

/// What a harness adapter found on this Mac, read-only.
public struct HarnessDetection: Sendable, Equatable {
    public var kind: Config.HarnessKind, title: String
    public var installed = false
    public var version: String?
    /// nil when not checked (not installed, or Gateway calls are refused from this process).
    public var reachable: Bool?
    /// Installed, version and reachable as readiness items, with their fixes.
    public var items: [Readiness.Item] = []
}

/// A coding executor for display (Settings › Advanced): whether its tool's binary is found on the launch PATH, `~/.local/bin`
/// or the Homebrew folders. Never a login state: no Gateway method reports one.
public struct CodingExecutor: Sendable, Equatable {
    public var executor: Executor; public var binary: String?; public var path: String?
}

/// The setup seam each harness adapter fills in beside `Harness` (#317): read-only detection, its readiness checks, the setup
/// steps it takes part in, and its coding executors for display.
public protocol HarnessSetup: Sendable {
    var kind: Config.HarnessKind { get }
    var title: String { get }
    /// Local check only (files on disk), cheap enough to run for every adapter.
    var installed: Bool { get }
    /// Installed, version and reachable, as readiness items.
    func detect() async -> HarnessDetection
    /// The setup steps (`SetupEngine.order`) this adapter takes part in beyond detection.
    var steps: [String] { get }
    func executors(_ settings: HarnessSettings) -> [CodingExecutor]
}

public extension Config.HarnessKind {
    /// This kind's setup adapter; `rpc` is the Gateway client OpenClaw's checks go through.
    func adapter(_ settings: Config.HarnessSettings, rpc: GatewayRPC) -> any HarnessSetup {
        switch self {
        case .openclaw: OpenClawSetup(agent: settings.agent,rpc: rpc)
        case .hermes: HermesSetup(url: settings.hermesURL,agent: settings.agent)
        }
    }
}
