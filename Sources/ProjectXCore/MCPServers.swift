import Foundation

/// The MCP servers Yorozu's workers may use (owner, 2026-10-08). Yorozu only declares them; the harness starts,
/// connects and calls them, so switching harness keeps the list. Stdio servers only.
public struct MCPServer: Codable, Sendable, Equatable {
    public var command: String; public var args: [String]?
    /// Refused for now: removing a value would not reach OpenClaw's merge-patched config, and values would travel in argv.
    public var env: [String:String]?
}
public enum MCPServers {
    /// cua-driver's `mcp` proxy starts the CuaDriver daemon through LaunchServices when it is not running.
    public static let defaults = ["cua-driver": MCPServer(command: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",args: ["mcp"])]
    /// `{"mcpServers": {"<name>": {"command": absolute path, "args": [...]}}}`. A missing file is created with the
    /// defaults so the owner can edit it; it is read once per app run.
    public static func load(_ file: URL) throws -> [String:MCPServer] {
        let list: [String:MCPServer]
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
                try encoder.encode(["mcpServers": defaults]).write(to: file,options: .withoutOverwriting)
            }
            guard let servers = try JSONDecoder().decode([String:[String:MCPServer]].self,from: Data(contentsOf: file))["mcpServers"] else { throw ProjectError.invalid("no mcpServers object") }
            list = servers
        } catch { throw ProjectError.invalid("MCP server list \(file.path): \(error). Fix the file and relaunch Yorozu.") }
        // OpenClaw caps the server part of a tool name at 30 characters; harness names add a 7-character prefix.
        for (name,server) in list where name.range(of: "^[A-Za-z0-9_-]{1,23}$",options: .regularExpression) == nil || !server.command.hasPrefix("/") || server.env != nil {
            throw ProjectError.invalid("MCP server list \(file.path): server \"\(name)\" needs a name of 1-23 letters, digits, - or _, an absolute command path and no env. Fix the file and relaunch Yorozu.")
        }
        return list
    }
}
