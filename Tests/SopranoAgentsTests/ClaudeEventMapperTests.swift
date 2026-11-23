import AppKit
import Testing
@testable import SopranoAgentsCore

struct ClaudeEventMapperTests {
    @Test func protocolParsesVersionAuthCatalogModesAndMcpConfig() {
        #expect(ClaudeProtocol.version(fromVersionOutput: "2.1.325 (Claude Code)\n") == "2.1.325")
        #expect(ClaudeProtocol.isAuthenticated(authOutput: "{\"loggedIn\":true,\"subscriptionType\":\"max\"}\n"))
        #expect(!ClaudeProtocol.isAuthenticated(authOutput: "{\"loggedIn\":false}\n"))
        #expect(ClaudeProtocol.accountPlan(from: ["subscriptionType": "max"]) == "Claude Max")
        #expect(ClaudeProtocol.accountPlan(from: ["subscriptionType": "Claude Ultra"]) == "Claude Ultra")

        let rawModels: [JSONValue] = [
            [
                "value": "default",
                "resolvedModel": "claude-fable-5-2",
                "displayName": "Default (recommended)",
                "description": "Fable 5.2",
                "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"],
                "supportsFastMode": true,
            ],
            [
                "value": "opus",
                "resolvedModel": "claude-opus-5-5",
                "displayName": "Opus 5.5",
                "supportedEffortLevels": ["low", "medium", "high", "max"],
                "supportsFastMode": true,
            ],
            [
                "value": "haiku",
                "resolvedModel": "claude-haiku-5-5",
                "displayName": "Haiku 5.5",
                "supportedEffortLevels": ["low", "medium", "high"],
                "supportsFastMode": false,
            ],
        ]
        let models = ClaudeProtocol.models(from: rawModels)
        #expect(models.count == 3)
        #expect(models[0].slug == ModelSelection.configuredDefaultModel)
        #expect(models[0].name == "Fable 5.2 · default")
        #expect(models[0].isDefault)
        #expect(models[0].option(ModelOptionID.effort)?.defaultValue == "high")
        #expect(models[0].option(ModelOptionID.fastMode)?.defaultValue == "false")
        #expect(models[1].slug == "opus")
        #expect(models[2].option(ModelOptionID.fastMode) == nil)

        #expect(ClaudeProtocol.permissionMode(for: .approvalRequired, interactionMode: .standard) == "default")
        #expect(ClaudeProtocol.permissionMode(for: .autoAcceptEdits, interactionMode: .standard) == "acceptEdits")
        #expect(ClaudeProtocol.permissionMode(for: .auto, interactionMode: .standard) == "auto")
        #expect(ClaudeProtocol.permissionMode(for: .fullAccess, interactionMode: .standard) == "bypassPermissions")
        #expect(ClaudeProtocol.permissionMode(for: .fullAccess, interactionMode: .plan) == "plan")

        let mcpJSON = ClaudeProtocol.mcpConfigJSON([
            MCPServerSpec(name: "browser", transport: .stdio(command: "/bin/mcp", args: ["browser"], env: ["PORT": "9333"])),
            MCPServerSpec(name: "remote", transport: .http(url: "http://127.0.0.1:8080/mcp", headers: ["Authorization": "Bearer tok"])),
        ])
        #expect(mcpJSON["mcpServers"]?["browser"]?["command"]?.stringValue == "/bin/mcp")
        #expect(mcpJSON["mcpServers"]?["remote"]?["url"]?.stringValue == "http://127.0.0.1:8080/mcp")
    }

    @Test func mapperReplaysRecordedToolAndSubagentTurnFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/claude-tool-turn.jsonl")
        let lines = try String(contentsOf: fixture, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        var mapper = ClaudeEventMapper(cwd: "/repo")
        var events: [ProviderEvent] = []
        for line in lines {
            events += mapper.map(try JSONValue.parse(line))
        }

        #expect(events.contains(.reasoningDelta(itemID: "msg_1:0", delta: "Inspecting auth cookie.")))
        #expect(events.contains(.assistantDelta(itemID: "msg_2:0", delta: "Changed cookie to ", isFinal: false)))
        #expect(events.contains(.tokenUsage(TokenUsage(usedTokens: 2200, contextWindow: 200_000))))
        #expect(events.contains(.turnCompleted(outcome: .completed, error: nil)))

        let items = events.compactMap { event -> TurnItem? in
            if case let .itemUpdated(item) = event { return item }
            return nil
        }
        let bash = items.last { $0.id == "tu_bash" }
        if case let .command(cmd)? = bash?.kind {
            #expect(cmd.command == "swift test --filter AuthTests")
            #expect(cmd.output == "Test Suite 'AuthTests' passed.")
            #expect(cmd.exitCode == 0)
        } else {
            Issue.record("Expected completed Bash command item")
        }

        let edit = items.last { $0.id == "tu_edit" }
        if case let .fileChange(changes)? = edit?.kind {
            #expect(changes.count == 1)
            #expect(changes[0].path == "Sources/Auth.swift")
            #expect(changes[0].diff?.contains("+let sameSite = \"Lax\"") == true)
        } else {
            Issue.record("Expected Edit fileChange item")
        }

        let subagentEvents = events.filter {
            if case .subagent("tu_sub", _) = $0 { return true }
            return false
        }
        #expect(subagentEvents.count >= 4)

        let finalAnswer = items.last { $0.id == "msg_2:0" }
        if case let .assistantMessage(text, isFinal)? = finalAnswer?.kind {
            #expect(text == "Changed cookie to `SameSite=Lax`.")
            #expect(isFinal)
        } else {
            Issue.record("Expected final assistant message")
        }
    }

    @Test func mapperTranslatesCanUseToolApprovalsAndAskUserQuestion() {
        var mapper = ClaudeEventMapper(cwd: "/repo")
        let (cmdEvents, _) = mapper.mapControlRequest(
            id: "req-1",
            request: [
                "subtype": "can_use_tool",
                "tool_name": "Bash",
                "input": ["command": "rm -rf .build", "description": "Clean build dir"],
                "permission_suggestions": [["type": "addRules"]],
            ]
        )
        if case let .approvalRequested(request)? = cmdEvents.first {
            #expect(request.id == "req-1")
            #expect(request.kind == .command)
            #expect(request.detail == "rm -rf .build")
            #expect(request.options == [.cancel, .decline, .acceptForSession, .accept])
        } else {
            Issue.record("Expected Bash approval")
        }

        let (askEvents, textByID) = mapper.mapControlRequest(
            id: "req-2",
            request: [
                "subtype": "can_use_tool",
                "tool_name": "AskUserQuestion",
                "input": [
                    "questions": [[
                        "header": "Target",
                        "question": "Which OS target?",
                        "multiSelect": true,
                        "options": [
                            ["label": "macOS", "description": "AppKit"],
                            ["label": "Linux", "description": "Wayland"],
                        ],
                    ]],
                ],
            ]
        )
        if case let .userInputRequested(request)? = askEvents.first {
            #expect(request.id == "req-2")
            #expect(request.questions.count == 1)
            #expect(request.questions[0].allowsMultiple)
            #expect(request.questions[0].options.map(\.label) == ["macOS", "Linux"])
            #expect(textByID["q1"] == "Which OS target?")
        } else {
            Issue.record("Expected AskUserQuestion userInputRequested")
        }
    }
}
