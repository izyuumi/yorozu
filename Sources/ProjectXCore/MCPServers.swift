import Foundation

/// The MCP servers Yorozu's workers may use (owner, 2026-10-08). Yorozu only declares them; the harness starts,
/// connects and calls them, so switching harness keeps the list. Stdio servers only.
public struct MCPServer: Codable, Sendable, Equatable {
    public var command: String; public var args: [String]?
    /// Refused for now: removing a value would not reach OpenClaw's merge-patched config, and values would travel in argv.
    public var env: [String:String]?
    public init(command: String, args: [String]? = nil) { self.command = command; self.args = args }
}
public enum MCPServers {
    /// cua-driver's `mcp` proxy starts the CuaDriver daemon through LaunchServices when it is not running.
    public static let defaults = ["cua-driver": MCPServer(command: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",args: ["mcp"])]
    static let rule = "needs a name of 1-23 letters, digits, - or _, an absolute command path and no env"
    /// The first server that breaks the rule, if any. OpenClaw caps the server part of a tool name at 30 characters;
    /// harness names add a 7-character prefix.
    public static func invalid(_ list: [String:MCPServer]) -> String? {
        list.keys.sorted().first { name in let server = list[name]!; return name.range(of: "^[A-Za-z0-9_-]{1,23}$",options: .regularExpression) == nil || !server.command.hasPrefix("/") || server.env != nil }
    }
    /// The `[mcp_servers]` list of `config.toml` (`Config`); a missing file is created with the defaults.
    public static func load(_ file: URL) throws -> [String:MCPServer] { try Config.load(file).mcpServers }
    /// The retired `{"mcpServers": {...}}` file, imported once when `config.toml` is first created; nil when absent or invalid.
    static func legacy(_ file: URL) -> [String:MCPServer]? {
        guard let data = try? Data(contentsOf: file), let list = (try? JSONDecoder().decode([String:[String:MCPServer]].self,from: data))?["mcpServers"], invalid(list) == nil else { return nil }
        return list
    }
}
