import Foundation

/// Discovers shared skills, slash commands, instructions, rules and MCP servers from standard
/// open directories, user-configured `extraDirectories` / `importMcpFiles`, inline `settings.json`
/// `mcpServers`, and project-local overrides. Foundation-only and OS-agnostic.
public enum ResourceCatalog {
    /// Discovers and merges resources in precedence order (later overrides earlier by name):
    /// 1. `~/.config/soprano-agents` (Soprano Agents global)
    /// 2. `~/.agents` (cross-agent shared skills)
    /// 3. `settings.extraDirectories` (e.g. `~/.omp/agent`)
    /// 4. `cwd` project overrides (`.soprano-agents/`, `.agents/`, `.mcp.json`)
    /// 5. `settings.importMcpFiles` and inline `settings.mcpServers` (highest precedence for MCPs)
    public static func discover(
        cwd: String? = nil,
        settings: ResourceSettings = ResourceSettings(),
        home: String = NSHomeDirectory(),
        configRoot: String? = nil
    ) -> ResolvedResources {
        let sopranoRoot = configRoot ?? (home as NSString).appendingPathComponent(".config/soprano-agents")
        let sharedAgentsRoot = (home as NSString).appendingPathComponent(".agents")

        var roots: [(path: String, source: ResourceSource)] = [
            (sopranoRoot, .soprano),
            (sharedAgentsRoot, .shared),
        ]
        for dir in settings.extraDirectories {
            let expanded = expand(dir, home: home)
            if !roots.contains(where: { standardized($0.path) == standardized(expanded) }) {
                roots.append((expanded, .custom))
            }
        }
        if let cwd, !cwd.isEmpty {
            roots.append(((cwd as NSString).appendingPathComponent(".soprano-agents"), .project))
            roots.append(((cwd as NSString).appendingPathComponent(".agents"), .project))
        }

        var skillsByName: [String: SharedSkill] = [:]
        var commandsByName: [String: SharedCommand] = [:]
        var rulesByName: [String: SharedRule] = [:]
        var instructions: [(source: ResourceSource, originRoot: String, path: String, text: String)] = []
        var mcpByName: [String: SharedMCPServer] = [:]

        for root in roots {
            guard isDirectory(root.path) else { continue }
            scanSkills(in: (root.path as NSString).appendingPathComponent("skills"), source: root.source, originRoot: root.path, into: &skillsByName)
            scanCommands(in: (root.path as NSString).appendingPathComponent("commands"), source: root.source, originRoot: root.path, into: &commandsByName)
            scanRules(in: (root.path as NSString).appendingPathComponent("rules"), source: root.source, originRoot: root.path, into: &rulesByName)

            for fileName in ["AGENTS.md", "RULES.md"] {
                let file = (root.path as NSString).appendingPathComponent(fileName)
                if let text = readTrimmed(file) {
                    instructions.append((root.source, root.path, file, text))
                }
            }

            let mcpFile = (root.path as NSString).appendingPathComponent("mcp.json")
            for spec in parseMCPFile(at: mcpFile) {
                mcpByName[spec.name] = SharedMCPServer(spec: spec, source: root.source, originPath: mcpFile)
            }
        }

        if let cwd, !cwd.isEmpty {
            let projectMCP = (cwd as NSString).appendingPathComponent(".mcp.json")
            for spec in parseMCPFile(at: projectMCP) {
                mcpByName[spec.name] = SharedMCPServer(spec: spec, source: .project, originPath: projectMCP)
            }
        }

        for file in settings.importMcpFiles {
            let path = expand(file, home: home)
            for spec in parseMCPFile(at: path) {
                mcpByName[spec.name] = SharedMCPServer(spec: spec, source: .custom, originPath: path)
            }
        }

        for spec in settings.mcpServers {
            mcpByName[spec.name] = SharedMCPServer(spec: spec, source: .soprano, originPath: nil)
        }

        return ResolvedResources(
            skills: skillsByName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            commands: commandsByName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            rules: rulesByName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            instructions: instructions,
            mcpServers: mcpByName.values.sorted { $0.spec.name.localizedCaseInsensitiveCompare($1.spec.name) == .orderedAscending }
        )
    }

    // MARK: - Provider projections

    /// Built-in MCP server names that repository-local MCP configs may never shadow.
    public static let reservedBuiltInMCPNames: Set<String> = ["soprano-team", "soprano-browser"]

    /// Shared MCP servers to inject into `provider` (respecting `settings.injectMcp`, gating
    /// project-local MCP configs behind `settings.trustProjectMcp`, blocking repo shadowing of
    /// built-in servers, and avoiding re-injecting `~/.omp/agent/mcp.json` back into `omp`).
    public static func mcpServers(
        from resources: ResolvedResources,
        for provider: ProviderKind,
        settings: ResourceSettings,
        home: String = NSHomeDirectory()
    ) -> [MCPServerSpec] {
        guard settings.injectMcp, provider.capabilities.supportsMCPInjection else { return [] }
        let ompRoot = standardized((home as NSString).appendingPathComponent(".omp/agent"))
        return resources.mcpServers.compactMap { entry in
            if entry.source == .project {
                guard settings.trustProjectMcp else { return nil }
                if reservedBuiltInMCPNames.contains(entry.spec.name) { return nil }
            }
            if provider == .omp, let origin = entry.originPath, standardized(origin).hasPrefix(ompRoot + "/") {
                return nil
            }
            return entry.spec
        }
    }

    /// Composes a Markdown system-prompt appendix (shared instructions, rules and skills index)
    /// for `provider`. Returns nil when nothing applies or `settings.injectInstructions` is false.
    /// Avoids duplicating `~/.omp/agent` files into `omp` itself.
    public static func systemPromptAppendix(
        from resources: ResolvedResources,
        for provider: ProviderKind,
        settings: ResourceSettings,
        home: String = NSHomeDirectory()
    ) -> String? {
        guard settings.injectInstructions, provider.capabilities.supportsSystemPromptAppend else { return nil }
        let ompRoot = standardized((home as NSString).appendingPathComponent(".omp/agent"))
        let isOmp = provider == .omp

        var sections: [String] = []

        let filteredInstructions = resources.instructions.filter { item in
            !(isOmp && standardized(item.originRoot) == ompRoot)
        }
        for item in filteredInstructions {
            sections.append(item.text)
        }

        let filteredRules = resources.rules.filter { rule in
            !(isOmp && standardized(rule.originRoot) == ompRoot)
        }
        if !filteredRules.isEmpty {
            let block = filteredRules.map { "## Rule: \($0.name)\n\($0.body)" }.joined(separator: "\n\n")
            sections.append(block)
        }

        let filteredSkills = resources.skills.filter { skill in
            !(isOmp && standardized(skill.originRoot) == ompRoot)
        }
        if !filteredSkills.isEmpty {
            let lines = filteredSkills.map { skill -> String in
                let desc = skill.description.map { ": \($0)" } ?? ""
                return "- `\(skill.name)`\(desc) — read `\(skill.path)` before using."
            }
            sections.append("## Shared skills\nWhen a task matches one of these skills, read its `SKILL.md` file first:\n" + lines.joined(separator: "\n"))
        }

        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n---\n\n") + "\n"
    }

    /// Shared commands and skills as composer `/` menu items.
    public static func composerCommands(from resources: ResolvedResources) -> [ProviderCommand] {
        var result: [ProviderCommand] = []
        for command in resources.commands {
            result.append(ProviderCommand(
                name: command.name,
                kind: .command,
                description: command.description,
                argumentHint: command.argumentHint,
                source: command.source.rawValue,
                insertText: "/\(command.name) "
            ))
        }
        for skill in resources.skills {
            result.append(ProviderCommand(
                name: "skill:\(skill.name)",
                kind: .skill,
                description: skill.description,
                source: skill.source.rawValue,
                insertText: "/skill:\(skill.name) "
            ))
        }
        return result
    }

    /// Expands a leading `/<command> [args]` or `/skill:<name> [args]` using shared resources for
    /// providers that do not natively expand those commands (e.g. Antigravity). Returns nil when
    /// `text` does not match a shared command or skill.
    public static func expandPrompt(_ text: String, resources: ResolvedResources) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let splitIndex = body.firstIndex(where: \.isWhitespace) ?? body.endIndex
        let token = String(body[..<splitIndex])
        let arguments = String(body[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        if token.hasPrefix("skill:") {
            let skillName = String(token.dropFirst("skill:".count))
            guard let skill = resources.skills.first(where: { $0.name.caseInsensitiveCompare(skillName) == .orderedSame }) else {
                return nil
            }
            let prefix = "Use the skill `\(skill.name)` by reading `\(skill.path)` first and following its instructions."
            return arguments.isEmpty ? prefix : "\(prefix)\n\n\(arguments)"
        }

        guard let command = resources.commands.first(where: { $0.name.caseInsensitiveCompare(token) == .orderedSame }) else {
            return nil
        }
        if command.body.contains("$ARGUMENTS") {
            return command.body.replacingOccurrences(of: "$ARGUMENTS", with: arguments)
        }
        return arguments.isEmpty ? command.body : "\(command.body)\n\n\(arguments)"
    }

    // MARK: - Scanners & parsers

    private static func scanSkills(in directory: String, source: ResourceSource, originRoot: String, into map: inout [String: SharedSkill]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let folder = (directory as NSString).appendingPathComponent(entry)
            let skillFile = (folder as NSString).appendingPathComponent("SKILL.md")
            guard let raw = readTrimmed(skillFile) else { continue }
            let parsed = parseMarkdownFrontmatter(raw)
            let name = parsed.meta["name"]?.nonEmptyTrimmed ?? entry
            let description = parsed.meta["description"]?.nonEmptyTrimmed
            map[name] = SharedSkill(name: name, description: description, path: skillFile, source: source, originRoot: originRoot)
        }
    }

    private static func scanCommands(in directory: String, source: ResourceSource, originRoot: String, into map: inout [String: SharedCommand]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries.sorted() where entry.hasSuffix(".md") && !entry.hasPrefix(".") {
            let file = (directory as NSString).appendingPathComponent(entry)
            guard let raw = readTrimmed(file) else { continue }
            let parsed = parseMarkdownFrontmatter(raw)
            let defaultName = String(entry.dropLast(3))
            let name = parsed.meta["name"]?.nonEmptyTrimmed ?? defaultName
            let description = parsed.meta["description"]?.nonEmptyTrimmed
            let hint = parsed.meta["argument-hint"]?.nonEmptyTrimmed ?? parsed.meta["argumentHint"]?.nonEmptyTrimmed
            map[name] = SharedCommand(name: name, description: description, argumentHint: hint, body: parsed.body, path: file, source: source, originRoot: originRoot)
        }
    }

    private static func scanRules(in directory: String, source: ResourceSource, originRoot: String, into map: inout [String: SharedRule]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries.sorted() where entry.hasSuffix(".md") && !entry.hasPrefix(".") {
            let file = (directory as NSString).appendingPathComponent(entry)
            guard let raw = readTrimmed(file) else { continue }
            let parsed = parseMarkdownFrontmatter(raw)
            let name = parsed.meta["name"]?.nonEmptyTrimmed ?? String(entry.dropLast(3))
            guard !parsed.body.isEmpty else { continue }
            map[name] = SharedRule(name: name, body: parsed.body, path: file, source: source, originRoot: originRoot)
        }
    }

    /// Parses a standard `mcp.json` file (`{ "mcpServers": { name: { command, args, env } | { url, headers } } }`).
    public static func parseMCPFile(at path: String) -> [MCPServerSpec] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8),
              let root = try? JSONValue.parse(text) else { return [] }
        let container = root["mcpServers"]?.objectValue ?? root["servers"]?.objectValue ?? root.objectValue ?? [:]
        return parseMCPDictionary(container)
    }

    /// Parses a dictionary of `name -> serverConfig` JSON objects into `MCPServerSpec`s.
    public static func parseMCPDictionary(_ dict: [String: JSONValue]) -> [MCPServerSpec] {
        var specs: [MCPServerSpec] = []
        for name in dict.keys.sorted() {
            guard let entry = dict[name], entry.objectValue != nil else { continue }
            if entry["enabled"]?.boolValue == false || entry["disabled"]?.boolValue == true { continue }
            if let command = entry["command"]?.nonEmptyString {
                let args = (entry["args"]?.arrayValue ?? []).compactMap(\.stringValue)
                let env = (entry["env"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
                specs.append(MCPServerSpec(name: name, transport: .stdio(command: command, args: args, env: env)))
            } else if let url = entry["url"]?.nonEmptyString ?? entry["serverUrl"]?.nonEmptyString {
                let headers = (entry["headers"]?.objectValue ?? entry["httpHeaders"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
                specs.append(MCPServerSpec(name: name, transport: .http(url: url, headers: headers)))
            }
        }
        return specs
    }

    /// Lightweight YAML frontmatter parser for `--- ... ---` blocks (single-line key: value pairs).
    static func parseMarkdownFrontmatter(_ text: String) -> (meta: [String: String], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return ([:], normalized.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let rest = normalized.dropFirst(4)
        guard let closing = rest.range(of: "\n---\n") ?? rest.range(of: "\n---") else {
            return ([:], normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let header = String(rest[..<closing.lowerBound])
        let body = String(rest[closing.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var meta: [String: String] = [:]
        for line in header.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { meta[key] = value }
        }
        return (meta, body)
    }

    private static func readTrimmed(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isDirectory(_ path: String) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &flag) && flag.boolValue
    }

    private static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
