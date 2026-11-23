import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

struct ResourceCatalogTests {
    @Test func discoversAndMergesResourcesAcrossSopranoSharedCustomAndProjectRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sa-resources-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let soprano = home.appendingPathComponent(".config/soprano-agents", isDirectory: true)
        let shared = home.appendingPathComponent(".agents", isDirectory: true)
        let omp = home.appendingPathComponent(".omp/agent", isDirectory: true)
        let project = root.appendingPathComponent("repo", isDirectory: true)

        try write(soprano.appendingPathComponent("skills/deploy/SKILL.md"), """
        ---
        name: deploy
        description: Global deploy skill
        ---
        Run deploy.
        """)
        try write(shared.appendingPathComponent("skills/scan/SKILL.md"), """
        ---
        name: scan
        description: Shared page scan
        ---
        Scan the page.
        """)
        try write(omp.appendingPathComponent("commands/ship.md"), """
        ---
        description: Commit and ship changes
        argument-hint: "[target]"
        ---
        Ship $ARGUMENTS safely.
        """)
        try write(omp.appendingPathComponent("rules/no-force-push.md"), """
        ---
        name: no-force-push
        ---
        Never force push main.
        """)
        try write(omp.appendingPathComponent("mcp.json"), """
        {"mcpServers":{"asana":{"command":"bun","args":["proxy.ts"]},"disabled-one":{"command":"x","disabled":true}}}
        """)
        try write(project.appendingPathComponent(".agents/skills/deploy/SKILL.md"), """
        ---
        name: deploy
        description: Project-specific deploy override
        ---
        Project deploy.
        """)
        try write(project.appendingPathComponent(".mcp.json"), """
        {"mcpServers":{"local-api":{"url":"http://127.0.0.1:4000/mcp"}}}
        """)

        let settings = ResourceSettings(
            extraDirectories: ["~/.omp/agent"],
            mcpServers: [MCPServerSpec(name: "inline-tool", transport: .stdio(command: "/bin/tool"))]
        )
        let resolved = ResourceCatalog.discover(cwd: project.path, settings: settings, home: home.path)

        #expect(resolved.skills.map(\.name) == ["deploy", "scan"])
        // Project skill overrides global skill by name.
        #expect(resolved.skills.first { $0.name == "deploy" }?.source == .project)
        #expect(resolved.skills.first { $0.name == "deploy" }?.description == "Project-specific deploy override")
        #expect(resolved.commands.map(\.name) == ["ship"])
        #expect(resolved.rules.map(\.name) == ["no-force-push"])
        #expect(resolved.mcpServers.map(\.spec.name) == ["asana", "inline-tool", "local-api"])

        // Antigravity gets all 3 MCP servers; omp skips its own ~/.omp/agent/mcp.json server to avoid duplication.
        let agyMCP = ResourceCatalog.mcpServers(from: resolved, for: .antigravity, settings: settings, home: home.path)
        let ompMCP = ResourceCatalog.mcpServers(from: resolved, for: .omp, settings: settings, home: home.path)
        #expect(agyMCP.map(\.name) == ["asana", "inline-tool", "local-api"])
        #expect(ompMCP.map(\.name) == ["inline-tool", "local-api"])

        // Antigravity ACP serialization matches ACP v1 spec.
        let acpArray = AntigravityProtocol.mcpServers(agyMCP).arrayValue ?? []
        #expect(acpArray.count == 3)
        #expect(acpArray[0]["name"]?.stringValue == "asana")
        #expect(acpArray[2]["type"]?.stringValue == "http")
        #expect(acpArray[2]["url"]?.stringValue == "http://127.0.0.1:4000/mcp")

        // System prompt appendix includes rules and skills index for Antigravity, skips omp-originated rules for omp.
        let agyPrompt = try #require(ResourceCatalog.systemPromptAppendix(from: resolved, for: .antigravity, settings: settings, home: home.path))
        #expect(agyPrompt.contains("Never force push main."))
        #expect(agyPrompt.contains("Shared skills"))
        #expect(agyPrompt.contains("`scan`"))

        // Shared command and skill prompt expansion.
        #expect(ResourceCatalog.expandPrompt("/ship staging", resources: resolved) == "Ship staging safely.")
        let expandedSkill = try #require(ResourceCatalog.expandPrompt("/skill:scan check header", resources: resolved))
        #expect(expandedSkill.contains("Use the skill `scan`"))
        #expect(expandedSkill.contains("check header"))
    }

    @Test func settingsResolverParsesResourcesAndInlineMcpServers() throws {
        let resolved = try SettingsResolver.resolve(text: """
        {
          "resources": {
            "extraDirectories": ["~/.omp/agent"],
            "importMcpFiles": ["~/.omp/agent/mcp.json"],
            "injectInstructions": true,
            "injectMcp": false
          },
          "mcpServers": {
            "browser": { "command": "bun", "args": ["browser.ts"], "env": { "PORT": "9333" } },
            "docs": { "url": "http://127.0.0.1:9000/mcp", "headers": { "X-Key": "secret" } }
          }
        }
        """)
        #expect(resolved.issues.isEmpty)
        #expect(resolved.settings.resources.extraDirectories == ["~/.omp/agent"])
        #expect(resolved.settings.resources.importMcpFiles == ["~/.omp/agent/mcp.json"])
        #expect(resolved.settings.resources.injectInstructions)
        #expect(!resolved.settings.resources.injectMcp)
        #expect(resolved.settings.resources.mcpServers.count == 2)
        #expect(resolved.settings.resources.mcpServers[0].name == "browser")
        #expect(resolved.settings.resources.mcpServers[1].name == "docs")
    }

    private func write(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
