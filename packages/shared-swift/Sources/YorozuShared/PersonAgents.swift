import Foundation

public enum PersonAgentPlugin: String, Codable, Equatable, Sendable, CaseIterable {
    case hermes, openclaw
}
public enum PersonAgentTool: String, Codable, Equatable, Sendable, CaseIterable {
    case file, terminal, delegation, memory, web, browser, team, computer
}

enum PersonAgentWire {
    struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    static func keys(_ decoder: Decoder, _ allowed: [String]) throws {
        let c = try decoder.container(keyedBy: Key.self)
        for key in c.allKeys {
            guard allowed.contains(key.stringValue), try !c.decodeNil(forKey: key) else { throw invalid(decoder) }
        }
    }
    static func invalid(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid person-agent data"))
    }
    static func id(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 64, let first = bytes.first, (97...122).contains(first) else { return false }
        return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
    }
    static func text(_ value: String, _ max: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= max
            && !value.contains("\0") && !value.contains("\r") && !value.contains("\n")
    }
    static func path(_ value: String) -> Bool {
        text(value, 4096) && value.hasPrefix("/")
            && !value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }
    static func revision(_ value: Int) -> Bool { value >= 0 && value <= 9_007_199_254_740_991 }
    static func ids(_ value: [String], _ max: Int, nonempty: Bool = false) -> Bool {
        value.count <= max && (!nonempty || !value.isEmpty) && value.allSatisfy(id)
            && Set(value).count == value.count
    }
    static func knowledge(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= 8192 && !value.contains("\0")
    }
    static func tools(_ value: [PersonAgentTool]) -> Bool {
        value.count <= PersonAgentTool.allCases.count && Set(value).count == value.count
    }
    static func directories(_ value: [PersonAgentDirectoryGrant]) -> Bool {
        value.count <= 64 && value.allSatisfy(\.isValid) && Set(value.map(\.path)).count == value.count
    }
}

public struct PersonAgentDirectoryGrant: Codable, Equatable, Sendable {
    public enum Access: String, Codable, Sendable { case read, write }
    public var path: String
    public var access: Access
    public init(path: String, access: Access) { self.path = path; self.access = access }
    public var isValid: Bool { PersonAgentWire.path(path) }
    private enum CodingKeys: String, CodingKey { case path, access }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["path", "access"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path); access = try c.decode(Access.self, forKey: .access)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}

/// Configuration references only. Workspace and memory paths are supplied separately by the host.
public struct PersonAgentInput: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String
    public var role: String
    public var pluginId: PersonAgentPlugin
    public var model: String?
    public var accountBindingId: String?
    public var allowedTools: [PersonAgentTool]
    public var directories: [PersonAgentDirectoryGrant]?
    public init(id: String? = nil, name: String, role: String, pluginId: PersonAgentPlugin,
        model: String? = nil, accountBindingId: String? = nil, allowedTools: [PersonAgentTool],
        directories: [PersonAgentDirectoryGrant]? = nil) {
        self.id = id; self.name = name; self.role = role; self.pluginId = pluginId
        self.model = model; self.accountBindingId = accountBindingId; self.allowedTools = allowedTools; self.directories = directories
    }
    public var isValid: Bool {
        (id.map(PersonAgentWire.id) ?? true) && PersonAgentWire.text(name, 80) && PersonAgentWire.text(role, 512)
            && (model.map { PersonAgentWire.text($0, 128) } ?? true)
            && (accountBindingId.map { PersonAgentWire.text($0, 256) } ?? true)
            && PersonAgentWire.tools(allowedTools) && (directories.map(PersonAgentWire.directories) ?? true)
    }
    private enum CodingKeys: String, CodingKey { case id, name, role, pluginId, model, accountBindingId, allowedTools, directories }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["id", "name", "role", "pluginId", "model", "accountBindingId", "allowedTools", "directories"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        role = try c.decode(String.self, forKey: .role); pluginId = try c.decode(PersonAgentPlugin.self, forKey: .pluginId)
        model = try c.decodeIfPresent(String.self, forKey: .model); accountBindingId = try c.decodeIfPresent(String.self, forKey: .accountBindingId)
        allowedTools = try c.decode([PersonAgentTool].self, forKey: .allowedTools)
        directories = try c.decodeIfPresent([PersonAgentDirectoryGrant].self, forKey: .directories)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}

public struct PersonAgentPatch: Codable, Equatable, Sendable {
    public enum Clear: String, Codable, Sendable { case model, accountBindingId }
    public var name: String?
    public var role: String?
    public var pluginId: PersonAgentPlugin?
    public var model: String?
    public var accountBindingId: String?
    public var allowedTools: [PersonAgentTool]?
    public var directories: [PersonAgentDirectoryGrant]?
    public var clear: [Clear]?
    public init(name: String? = nil, role: String? = nil, pluginId: PersonAgentPlugin? = nil,
        model: String? = nil, accountBindingId: String? = nil, allowedTools: [PersonAgentTool]? = nil,
        directories: [PersonAgentDirectoryGrant]? = nil, clear: [Clear]? = nil) {
        self.name = name; self.role = role; self.pluginId = pluginId; self.model = model
        self.accountBindingId = accountBindingId; self.allowedTools = allowedTools; self.directories = directories
        self.clear = clear
    }
    public var isValid: Bool {
        (name.map { PersonAgentWire.text($0, 80) } ?? true) && (role.map { PersonAgentWire.text($0, 512) } ?? true)
            && (model.map { PersonAgentWire.text($0, 128) } ?? true)
            && (accountBindingId.map { PersonAgentWire.text($0, 256) } ?? true)
            && (allowedTools.map(PersonAgentWire.tools) ?? true) && (directories.map(PersonAgentWire.directories) ?? true)
            && (clear.map { $0.count <= 2 && Set($0).count == $0.count } ?? true)
            && !(clear?.contains(.model) == true && model != nil)
            && !(clear?.contains(.accountBindingId) == true && accountBindingId != nil)
    }
    private enum CodingKeys: String, CodingKey { case name, role, pluginId, model, accountBindingId, allowedTools, directories, clear }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["name", "role", "pluginId", "model", "accountBindingId", "allowedTools", "directories", "clear"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name); role = try c.decodeIfPresent(String.self, forKey: .role)
        pluginId = try c.decodeIfPresent(PersonAgentPlugin.self, forKey: .pluginId)
        model = try c.decodeIfPresent(String.self, forKey: .model); accountBindingId = try c.decodeIfPresent(String.self, forKey: .accountBindingId)
        allowedTools = try c.decodeIfPresent([PersonAgentTool].self, forKey: .allowedTools)
        directories = try c.decodeIfPresent([PersonAgentDirectoryGrant].self, forKey: .directories)
        clear = try c.decodeIfPresent([Clear].self, forKey: .clear)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}

public struct PersonAgent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var role: String
    public var pluginId: PersonAgentPlugin
    public var model: String?
    public var accountBindingId: String?
    public var workspace: String
    public var memoryDir: String
    public var allowedTools: [PersonAgentTool]
    public var directories: [PersonAgentDirectoryGrant]
    public var teamIds: [String]
    public init(id: String, name: String, role: String, pluginId: PersonAgentPlugin, model: String? = nil,
        accountBindingId: String? = nil, workspace: String, memoryDir: String,
        allowedTools: [PersonAgentTool], directories: [PersonAgentDirectoryGrant] = [], teamIds: [String] = []) {
        self.id = id; self.name = name; self.role = role; self.pluginId = pluginId; self.model = model
        self.accountBindingId = accountBindingId; self.workspace = workspace; self.memoryDir = memoryDir
        self.allowedTools = allowedTools; self.directories = directories; self.teamIds = teamIds
    }
    public var isValid: Bool {
        PersonAgentInput(id: id, name: name, role: role, pluginId: pluginId, model: model,
            accountBindingId: accountBindingId, allowedTools: allowedTools, directories: directories).isValid
            && PersonAgentWire.path(workspace) && PersonAgentWire.path(memoryDir) && PersonAgentWire.ids(teamIds, 32)
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, role, pluginId, model, accountBindingId, workspace, memoryDir, allowedTools, directories, teamIds
    }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["id", "name", "role", "pluginId", "model", "accountBindingId", "workspace", "memoryDir", "allowedTools", "directories", "teamIds"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name); role = try c.decode(String.self, forKey: .role)
        pluginId = try c.decode(PersonAgentPlugin.self, forKey: .pluginId)
        model = try c.decodeIfPresent(String.self, forKey: .model); accountBindingId = try c.decodeIfPresent(String.self, forKey: .accountBindingId)
        workspace = try c.decode(String.self, forKey: .workspace); memoryDir = try c.decode(String.self, forKey: .memoryDir)
        allowedTools = try c.decode([PersonAgentTool].self, forKey: .allowedTools)
        directories = try c.decode([PersonAgentDirectoryGrant].self, forKey: .directories); teamIds = try c.decode([String].self, forKey: .teamIds)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}

public struct PersonAgentTeamInput: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String
    public var agentIds: [String]
    public init(id: String? = nil, name: String, agentIds: [String]) { self.id = id; self.name = name; self.agentIds = agentIds }
    public var isValid: Bool {
        (id.map(PersonAgentWire.id) ?? true) && PersonAgentWire.text(name, 80) && PersonAgentWire.ids(agentIds, 64, nonempty: true)
    }
    private enum CodingKeys: String, CodingKey { case id, name, agentIds }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["id", "name", "agentIds"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        agentIds = try c.decode([String].self, forKey: .agentIds)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}
public struct PersonAgentTeamPatch: Codable, Equatable, Sendable {
    public var name: String?
    public var agentIds: [String]?
    public init(name: String? = nil, agentIds: [String]? = nil) { self.name = name; self.agentIds = agentIds }
    public var isValid: Bool {
        (name.map { PersonAgentWire.text($0, 80) } ?? true) && (agentIds.map { PersonAgentWire.ids($0, 64, nonempty: true) } ?? true)
    }
    private enum CodingKeys: String, CodingKey { case name, agentIds }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["name", "agentIds"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name); agentIds = try c.decodeIfPresent([String].self, forKey: .agentIds)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}
public struct PersonAgentTeam: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var agentIds: [String]
    public init(id: String, name: String, agentIds: [String]) { self.id = id; self.name = name; self.agentIds = agentIds }
    public var isValid: Bool { PersonAgentWire.id(id) && PersonAgentTeamInput(name: name, agentIds: agentIds).isValid }
    private enum CodingKeys: String, CodingKey { case id, name, agentIds }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["id", "name", "agentIds"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name); agentIds = try c.decode([String].self, forKey: .agentIds)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}

public enum PersonAgentPreference: Codable, Equatable, Sendable {
    case agent(String, text: String)
    case allAgents(text: String)
    public var isValid: Bool {
        switch self {
        case .agent(let id, let text): PersonAgentWire.id(id) && PersonAgentWire.knowledge(text)
        case .allAgents(let text): PersonAgentWire.knowledge(text)
        }
    }
    private enum CodingKeys: String, CodingKey { case agentId, allAgents, text }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["agentId", "allAgents", "text"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let text = try c.decode(String.self, forKey: .text)
        if c.contains(.agentId), !c.contains(.allAgents) { self = .agent(try c.decode(String.self, forKey: .agentId), text: text) }
        else if !c.contains(.agentId), try c.decode(Bool.self, forKey: .allAgents) { self = .allAgents(text: text) }
        else { throw PersonAgentWire.invalid(decoder) }
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .agent(let id, let text): try c.encode(id, forKey: .agentId); try c.encode(text, forKey: .text)
        case .allAgents(let text): try c.encode(true, forKey: .allAgents); try c.encode(text, forKey: .text)
        }
    }
}
public struct PersonAgentSharedKnowledge: Codable, Equatable, Sendable {
    public var fromAgentId: String
    public var toAgentIds: [String]
    public var text: String
    public init(fromAgentId: String, toAgentIds: [String], text: String) {
        self.fromAgentId = fromAgentId; self.toAgentIds = toAgentIds; self.text = text
    }
    public var isValid: Bool {
        PersonAgentWire.id(fromAgentId) && PersonAgentWire.ids(toAgentIds, 64, nonempty: true) && PersonAgentWire.knowledge(text)
    }
    private enum CodingKeys: String, CodingKey { case fromAgentId, toAgentIds, text }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["fromAgentId", "toAgentIds", "text"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fromAgentId = try c.decode(String.self, forKey: .fromAgentId); toAgentIds = try c.decode([String].self, forKey: .toAgentIds)
        text = try c.decode(String.self, forKey: .text)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}

public struct PersonAgentControlResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case applied, rejected, unknown }
    public var operationId: String
    public var status: Status
    public var revision: Int
    public var reason: String?
    public init(operationId: String, status: Status, revision: Int, reason: String? = nil) {
        self.operationId = operationId; self.status = status; self.revision = revision; self.reason = reason
    }
    public var isValid: Bool {
        PersonAgentWire.text(operationId, 128) && PersonAgentWire.revision(revision) && (reason.map { PersonAgentWire.text($0, 512) } ?? true)
    }
    private enum CodingKeys: String, CodingKey { case operationId, status, revision, reason }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["operationId", "status", "revision", "reason"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationId = try c.decode(String.self, forKey: .operationId); status = try c.decode(Status.self, forKey: .status)
        revision = try c.decode(Int.self, forKey: .revision); reason = try c.decodeIfPresent(String.self, forKey: .reason)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}

public struct PersonAgentRegistry: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var revision: Int
    public var defaultAgentId: String?
    public var agents: [PersonAgent]
    public var teams: [PersonAgentTeam]
    public var journalRevision: Int?
    public var lastControlResult: PersonAgentControlResult?
    public init(revision: Int, defaultAgentId: String? = nil, agents: [PersonAgent], teams: [PersonAgentTeam] = [],
        journalRevision: Int? = nil, lastControlResult: PersonAgentControlResult? = nil) {
        self.revision = revision; self.defaultAgentId = defaultAgentId; self.agents = agents; self.teams = teams
        self.journalRevision = journalRevision; self.lastControlResult = lastControlResult
    }
    public var isValid: Bool {
        guard version == 1, PersonAgentWire.revision(revision), agents.count <= 64, teams.count <= 32,
              agents.allSatisfy(\.isValid), teams.allSatisfy(\.isValid),
              Set(agents.map(\.id)).count == agents.count, Set(teams.map(\.id)).count == teams.count,
              journalRevision.map(PersonAgentWire.revision) ?? true, lastControlResult?.isValid ?? true else { return false }
        let known = Set(agents.map(\.id))
        guard agents.isEmpty ? defaultAgentId == nil : defaultAgentId.map(known.contains) == true,
              teams.allSatisfy({ Set($0.agentIds).isSubset(of: known) }) else { return false }
        for agent in agents {
            if Set(agent.teamIds) != Set(teams.filter { $0.agentIds.contains(agent.id) }.map(\.id)) { return false }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(self).count).map { $0 <= 2 * 1024 * 1024 } ?? false
    }
    private enum CodingKeys: String, CodingKey { case version, revision, defaultAgentId, agents, teams, journalRevision, lastControlResult }
    public init(from decoder: Decoder) throws {
        try PersonAgentWire.keys(decoder, ["version", "revision", "defaultAgentId", "agents", "teams", "journalRevision", "lastControlResult"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version); revision = try c.decode(Int.self, forKey: .revision)
        defaultAgentId = try c.decodeIfPresent(String.self, forKey: .defaultAgentId)
        agents = try c.decode([PersonAgent].self, forKey: .agents); teams = try c.decode([PersonAgentTeam].self, forKey: .teams)
        journalRevision = try c.decodeIfPresent(Int.self, forKey: .journalRevision)
        lastControlResult = try c.decodeIfPresent(PersonAgentControlResult.self, forKey: .lastControlResult)
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
}

public enum PersonAgentControlAction: Equatable, Sendable {
    case create(PersonAgentInput)
    case update(agentId: String, patch: PersonAgentPatch)
    case setDefault(agentId: String)
    case createTeam(PersonAgentTeamInput)
    case updateTeam(teamId: String, patch: PersonAgentTeamPatch)
    case remember(PersonAgentPreference, expectedJournalRevision: Int)
    case shareKnowledge(PersonAgentSharedKnowledge, expectedJournalRevision: Int)
}

/// The containing event ID is the operation ID. These controls never belong to chat history.
public struct PersonAgentControlData: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var expectedRevision: Int
    public var action: PersonAgentControlAction
    public init(expectedRevision: Int, action: PersonAgentControlAction) { self.expectedRevision = expectedRevision; self.action = action }
    public var isValid: Bool {
        guard version == 1, PersonAgentWire.revision(expectedRevision) else { return false }
        switch action {
        case .create(let input): return input.isValid
        case .update(let id, let patch): return PersonAgentWire.id(id) && patch.isValid
        case .setDefault(let id): return PersonAgentWire.id(id)
        case .createTeam(let team): return team.isValid
        case .updateTeam(let id, let patch): return PersonAgentWire.id(id) && patch.isValid
        case .remember(let preference, let revision): return preference.isValid && PersonAgentWire.revision(revision)
        case .shareKnowledge(let knowledge, let revision): return knowledge.isValid && PersonAgentWire.revision(revision)
        }
    }
    private enum CodingKeys: String, CodingKey {
        case version, expectedRevision, action, agent, agentId, patch, team, teamId, expectedJournalRevision, preference, knowledge
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version); expectedRevision = try c.decode(Int.self, forKey: .expectedRevision)
        let base = ["version", "expectedRevision", "action"]
        switch try c.decode(String.self, forKey: .action) {
        case "create":
            try PersonAgentWire.keys(decoder, base + ["agent"]); action = .create(try c.decode(PersonAgentInput.self, forKey: .agent))
        case "update":
            try PersonAgentWire.keys(decoder, base + ["agentId", "patch"])
            action = .update(agentId: try c.decode(String.self, forKey: .agentId), patch: try c.decode(PersonAgentPatch.self, forKey: .patch))
        case "default":
            try PersonAgentWire.keys(decoder, base + ["agentId"]); action = .setDefault(agentId: try c.decode(String.self, forKey: .agentId))
        case "create-team":
            try PersonAgentWire.keys(decoder, base + ["team"]); action = .createTeam(try c.decode(PersonAgentTeamInput.self, forKey: .team))
        case "update-team":
            try PersonAgentWire.keys(decoder, base + ["teamId", "patch"])
            action = .updateTeam(teamId: try c.decode(String.self, forKey: .teamId), patch: try c.decode(PersonAgentTeamPatch.self, forKey: .patch))
        case "remember":
            try PersonAgentWire.keys(decoder, base + ["expectedJournalRevision", "preference"])
            action = .remember(try c.decode(PersonAgentPreference.self, forKey: .preference),
                expectedJournalRevision: try c.decode(Int.self, forKey: .expectedJournalRevision))
        case "share-knowledge":
            try PersonAgentWire.keys(decoder, base + ["expectedJournalRevision", "knowledge"])
            action = .shareKnowledge(try c.decode(PersonAgentSharedKnowledge.self, forKey: .knowledge),
                expectedJournalRevision: try c.decode(Int.self, forKey: .expectedJournalRevision))
        default: throw PersonAgentWire.invalid(decoder)
        }
        guard isValid else { throw PersonAgentWire.invalid(decoder) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(expectedRevision, forKey: .expectedRevision)
        switch action {
        case .create(let agent): try c.encode("create", forKey: .action); try c.encode(agent, forKey: .agent)
        case .update(let id, let patch): try c.encode("update", forKey: .action); try c.encode(id, forKey: .agentId); try c.encode(patch, forKey: .patch)
        case .setDefault(let id): try c.encode("default", forKey: .action); try c.encode(id, forKey: .agentId)
        case .createTeam(let team): try c.encode("create-team", forKey: .action); try c.encode(team, forKey: .team)
        case .updateTeam(let id, let patch): try c.encode("update-team", forKey: .action); try c.encode(id, forKey: .teamId); try c.encode(patch, forKey: .patch)
        case .remember(let preference, let revision):
            try c.encode("remember", forKey: .action); try c.encode(preference, forKey: .preference); try c.encode(revision, forKey: .expectedJournalRevision)
        case .shareKnowledge(let knowledge, let revision):
            try c.encode("share-knowledge", forKey: .action); try c.encode(knowledge, forKey: .knowledge); try c.encode(revision, forKey: .expectedJournalRevision)
        }
    }
}
