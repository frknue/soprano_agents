import Foundation

/// User-customizable configuration for shared skills, commands, rules, custom agents and MCP
/// servers across all providers. All fields have clean defaults so the feature works out of the
/// box with zero personal hardcoding, while letting power users point at existing agent folders
/// (such as `~/.omp/agent` or a dotfiles checkout).
public struct ResourceSettings: Sendable, Hashable {
    /// Automatically include `~/.omp/agent` (omp's `AGENTS.md`, `RULES.md`, `rules/`, `skills/`,
    /// `commands/`, and `mcp.json`) so omp workflows and MCP servers are shared with every other
    /// agent in Soprano Agents. Enabled by default.
    public var includeOmp: Bool
    /// Additional root directories scanned for `AGENTS.md`, `RULES.md`, `rules/`, `skills/`,
    /// `commands/`, `agents/` and `mcp.json` (after `~/.omp/agent`, `~/.agents`, and
    /// `~/.config/soprano-agents`).
    public var extraDirectories: [String]
    /// Additional `mcp.json` files imported and merged into the shared MCP server list.
    public var importMcpFiles: [String]
    /// Inline MCP servers defined directly in `settings.json` (`mcpServers`).
    public var mcpServers: [MCPServerSpec]
    /// Append shared instructions, rules and a skills index to sessions that support it.
    public var injectInstructions: Bool
    /// Pass resolved shared MCP servers to sessions that support MCP injection.
    public var injectMcp: Bool
    /// Opt-in trust for repository-local MCP configs (`<cwd>/.mcp.json`, `.agents/mcp.json`,
    /// `.soprano-agents/mcp.json`). Disabled by default so untrusted repositories never execute
    /// commands automatically.
    public var trustProjectMcp: Bool

    public init(
        includeOmp: Bool = true,
        extraDirectories: [String] = [],
        importMcpFiles: [String] = [],
        mcpServers: [MCPServerSpec] = [],
        injectInstructions: Bool = true,
        injectMcp: Bool = true,
        trustProjectMcp: Bool = false
    ) {
        self.includeOmp = includeOmp
        self.extraDirectories = extraDirectories
        self.importMcpFiles = importMcpFiles
        self.mcpServers = mcpServers
        self.injectInstructions = injectInstructions
        self.injectMcp = injectMcp
        self.trustProjectMcp = trustProjectMcp
    }
}

/// Where a shared resource was discovered.
public enum ResourceSource: String, Sendable, Hashable {
    case omp = "omp"
    case soprano = "Soprano"
    case shared = "Shared"
    case custom = "Custom"
    case project = "Project"
}

public struct SharedSkill: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String?
    /// Absolute path to `SKILL.md`.
    public var path: String
    public var source: ResourceSource
    public var originRoot: String

    public init(name: String, description: String? = nil, path: String, source: ResourceSource, originRoot: String) {
        self.name = name
        self.description = description
        self.path = path
        self.source = source
        self.originRoot = originRoot
    }
}

public struct SharedCommand: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String?
    public var argumentHint: String?
    /// Markdown prompt body (without YAML frontmatter).
    public var body: String
    public var path: String
    public var source: ResourceSource
    public var originRoot: String

    public init(
        name: String,
        description: String? = nil,
        argumentHint: String? = nil,
        body: String,
        path: String,
        source: ResourceSource,
        originRoot: String
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.body = body
        self.path = path
        self.source = source
        self.originRoot = originRoot
    }
}

public struct SharedRule: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var body: String
    public var path: String
    public var source: ResourceSource
    public var originRoot: String

    public init(name: String, body: String, path: String, source: ResourceSource, originRoot: String) {
        self.name = name
        self.body = body
        self.path = path
        self.source = source
        self.originRoot = originRoot
    }
}

public struct SharedMCPServer: Sendable, Hashable, Identifiable {
    public var id: String { spec.name }
    public var spec: MCPServerSpec
    public var source: ResourceSource
    public var originPath: String?

    public init(spec: MCPServerSpec, source: ResourceSource, originPath: String? = nil) {
        self.spec = spec
        self.source = source
        self.originPath = originPath
    }
}

/// Everything `ResourceCatalog` discovered for one workspace and settings snapshot.
public struct ResolvedResources: Sendable, Hashable {
    public var skills: [SharedSkill]
    public var commands: [SharedCommand]
    public var rules: [SharedRule]
    public var instructions: [(source: ResourceSource, originRoot: String, path: String, text: String)]
    public var mcpServers: [SharedMCPServer]

    public init(
        skills: [SharedSkill] = [],
        commands: [SharedCommand] = [],
        rules: [SharedRule] = [],
        instructions: [(source: ResourceSource, originRoot: String, path: String, text: String)] = [],
        mcpServers: [SharedMCPServer] = []
    ) {
        self.skills = skills
        self.commands = commands
        self.rules = rules
        self.instructions = instructions
        self.mcpServers = mcpServers
    }

    public static func == (lhs: ResolvedResources, rhs: ResolvedResources) -> Bool {
        lhs.skills == rhs.skills
            && lhs.commands == rhs.commands
            && lhs.rules == rhs.rules
            && lhs.mcpServers == rhs.mcpServers
            && lhs.instructions.count == rhs.instructions.count
            && zip(lhs.instructions, rhs.instructions).allSatisfy { $0.path == $1.path && $0.text == $1.text }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(skills)
        hasher.combine(commands)
        hasher.combine(rules)
        hasher.combine(mcpServers)
        for item in instructions {
            hasher.combine(item.path)
            hasher.combine(item.text)
        }
    }

    public var isEmpty: Bool {
        skills.isEmpty && commands.isEmpty && rules.isEmpty && instructions.isEmpty && mcpServers.isEmpty
    }
}
