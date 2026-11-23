import AppKit
import Testing
@testable import SopranoAgentsCore

struct CodexEventMapperTests {
    @Test func protocolParsesVersionAuthPlanAndCatalog() {
        #expect(CodexProtocol.version(fromVersionOutput: "codex-cli 0.144.6\n") == "0.144.6")

        let unauth: JSONValue = ["account": .null, "requiresOpenaiAuth": true]
        #expect(!CodexProtocol.isAuthenticated(accountResponse: unauth))

        let pro: JSONValue = ["account": ["type": "chatgpt", "email": "dev@example.com", "planType": "pro"], "requiresOpenaiAuth": true]
        #expect(CodexProtocol.isAuthenticated(accountResponse: pro))
        #expect(CodexProtocol.accountPlan(from: pro) == "ChatGPT Pro")

        let apiKey: JSONValue = ["account": ["type": "apiKey"], "requiresOpenaiAuth": true]
        #expect(CodexProtocol.isAuthenticated(accountResponse: apiKey))
        #expect(CodexProtocol.accountPlan(from: apiKey) == "API key")

        let entries: [JSONValue] = [
            [
                "id": "gpt-5.6-sol",
                "model": "gpt-5.6-sol",
                "displayName": "GPT-5.6-Sol",
                "hidden": false,
                "isDefault": true,
                "defaultReasoningEffort": "high",
                "supportedReasoningEfforts": [
                    ["reasoningEffort": "low", "description": "Fast"],
                    ["reasoningEffort": "medium", "description": "Balanced"],
                    ["reasoningEffort": "high", "description": "Thorough"],
                ],
                "serviceTiers": [["id": "fast", "name": "Fast", "description": "Priority"]],
                "additionalSpeedTiers": [],
                "defaultServiceTier": .null,
            ],
            [
                "id": "hidden-model",
                "model": "hidden-model",
                "displayName": "Hidden",
                "hidden": true,
                "isDefault": false,
                "defaultReasoningEffort": "medium",
                "supportedReasoningEfforts": [],
                "serviceTiers": [],
                "additionalSpeedTiers": [],
                "defaultServiceTier": .null,
            ],
        ]
        let models = CodexProtocol.models(from: entries)
        #expect(models.count == 2)
        #expect(models[0].slug == ModelSelection.configuredDefaultModel)
        #expect(models[0].name == "GPT-5.6-Sol · default")
        #expect(models[0].isDefault)
        #expect(models[0].option(ModelOptionID.effort)?.defaultValue == "high")
        #expect(models[0].option(ModelOptionID.fastMode)?.defaultValue == "false")
        #expect(models[1].slug == "gpt-5.6-sol")
    }

    @Test func protocolBuildsTurnParamsWithPlanModeSkillsAndMcpArgs() {
        let mcp = MCPServerSpec(
            name: "soprano-team",
            transport: .stdio(command: "/usr/local/bin/soprano", args: ["mcp", "team"], env: ["TOKEN": "abc"])
        )
        let args = CodexProtocol.arguments(mcpServers: [mcp])
        #expect(args.starts(with: ["app-server", "--stdio"]))
        #expect(args.contains("mcp_servers.soprano-team.command=\"/usr/local/bin/soprano\""))
        #expect(args.contains("mcp_servers.soprano-team.args=[\"mcp\", \"team\"]"))
        #expect(args.contains("mcp_servers.soprano-team.env.TOKEN=\"abc\""))

        let selection = ModelSelection(provider: .codex, model: "gpt-5.6-sol", options: [ModelOptionID.effort: "xhigh", ModelOptionID.fastMode: "true"])
        let input = TurnInput(
            text: "/skill:scan check checkout",
            attachments: [Attachment(kind: .image, name: "shot.png", path: "/tmp/shot.png", mimeType: "image/png", byteSize: 120)],
            modelSelection: selection,
            runtimeMode: .autoAcceptEdits,
            interactionMode: .plan
        )
        let params = CodexProtocol.turnStartParams(
            threadID: "thr-1",
            input: input,
            cwd: "/repo",
            defaultModel: "gpt-5.6-sol",
            defaultEffort: "medium",
            previousModeWasPlan: false,
            skillPaths: ["scan": "/Users/demo/.agents/skills/scan/SKILL.md"]
        )
        #expect(params["model"]?.stringValue == "gpt-5.6-sol")
        #expect(params["effort"]?.stringValue == "xhigh")
        #expect(params["serviceTier"]?.stringValue == "fast")
        #expect(params["approvalPolicy"]?.stringValue == "on-request")
        #expect(params["collaborationMode"]?["mode"]?.stringValue == "plan")
        #expect(params["collaborationMode"]?["settings"]?["model"]?.stringValue == "gpt-5.6-sol")
        let inputs = params["input"]?.arrayValue ?? []
        #expect(inputs.count == 3)
        #expect(inputs[0]["type"]?.stringValue == "skill")
        #expect(inputs[0]["name"]?.stringValue == "scan")
        #expect(inputs[2]["type"]?.stringValue == "localImage")
        #expect(inputs[2]["path"]?.stringValue == "/tmp/shot.png")

        // Leaving Plan mode resets collaborationMode to "default".
        let buildInput = TurnInput(text: "Implement it", attachments: [], modelSelection: selection, runtimeMode: .fullAccess, interactionMode: .standard)
        let buildParams = CodexProtocol.turnStartParams(
            threadID: "thr-1",
            input: buildInput,
            cwd: "/repo",
            defaultModel: "gpt-5.6-sol",
            defaultEffort: "medium",
            previousModeWasPlan: true
        )
        #expect(buildParams["collaborationMode"]?["mode"]?.stringValue == "default")
        #expect(buildParams["approvalPolicy"]?.stringValue == "never")
        #expect(buildParams["sandboxPolicy"]?["type"]?.stringValue == "dangerFullAccess")
    }

    @Test func mapperReplaysRecordedToolTurnFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/codex-tool-turn.jsonl")
        let lines = try String(contentsOf: fixture, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        var mapper = CodexEventMapper(cwd: "/repo")
        var events: [ProviderEvent] = []
        for line in lines {
            let frame = try JSONValue.parse(line)
            let method = frame["method"]?.stringValue ?? ""
            let params = frame["params"] ?? .null
            events += mapper.notification(method: method, params: params)
        }

        #expect(events.contains(.turnStarted(providerTurnID: "turn-1")))
        #expect(events.contains(.reasoningDelta(itemID: "rs-1", delta: "Checking tests first.")))
        #expect(events.contains(.commandOutputDelta(itemID: "cmd-1", delta: "Test Suite 'AuthTests' passed.\n")))
        #expect(events.contains(.tokenUsage(TokenUsage(usedTokens: 2400, contextWindow: 258_000))))
        #expect(events.contains(.turnCompleted(outcome: .completed, error: nil)))

        let items = events.compactMap { event -> TurnItem? in
            if case let .itemUpdated(item) = event { return item }
            return nil
        }
        let fileChange = items.first { $0.id == "fc-1" }
        if case let .fileChange(changes)? = fileChange?.kind {
            #expect(changes.count == 1)
            #expect(changes[0].path == "Sources/Auth.swift")
            #expect(changes[0].kind == .update)
            #expect(changes[0].diff?.contains("+let sameSite = \"Lax\"") == true)
        } else {
            Issue.record("Expected fileChange item")
        }

        let mcp = items.first { $0.id == "mcp-1" }
        if case let .toolCall(call)? = mcp?.kind {
            #expect(call.title == "browser: screenshot")
            #expect(call.output == "Saved screenshot.png")
        } else {
            Issue.record("Expected mcpToolCall item")
        }

        let finalAnswer = items.last { $0.id == "msg-1" }
        if case let .assistantMessage(text, isFinal)? = finalAnswer?.kind {
            #expect(text == "Updated the cookie to `SameSite=Lax`.")
            #expect(isFinal)
        } else {
            Issue.record("Expected final assistant message")
        }
    }

    @Test func mapperTranslatesApprovalsAndUserInputRequests() {
        var mapper = CodexEventMapper(cwd: "/repo")
        let cmdEvents = mapper.serverRequest(
            id: "10",
            method: "item/commandExecution/requestApproval",
            params: ["command": "rm -rf build", "reason": "Clean build folder"]
        )
        if case let .approvalRequested(request)? = cmdEvents.first {
            #expect(request.id == "10")
            #expect(request.kind == .command)
            #expect(request.detail == "rm -rf build")
            #expect(request.reason == "Clean build folder")
        } else {
            Issue.record("Expected command approval")
        }

        let fileEvents = mapper.serverRequest(
            id: "11",
            method: "item/fileChange/requestApproval",
            params: ["grantRoot": "/repo/Sources", "reason": "Write outside sandbox"]
        )
        if case let .approvalRequested(request)? = fileEvents.first {
            #expect(request.kind == .fileChange)
            #expect(request.detail == "Sources")
            #expect(request.reason == "Write outside sandbox")
        } else {
            Issue.record("Expected fileChange approval")
        }

        let inputEvents = mapper.serverRequest(
            id: "12",
            method: "item/tool/requestUserInput",
            params: [
                "questions": [[
                    "id": "db",
                    "header": "Database",
                    "question": "Which backend?",
                    "isOther": true,
                    "isSecret": false,
                    "options": [
                        ["label": "SQLite", "description": "Local file"],
                        ["label": "Postgres", "description": "Network server"],
                    ],
                ]],
            ]
        )
        if case let .userInputRequested(request)? = inputEvents.first {
            #expect(request.id == "12")
            #expect(request.questions.count == 1)
            #expect(request.questions[0].header == "Database")
            #expect(request.questions[0].options.map(\.label) == ["SQLite", "Postgres"])
            #expect(request.questions[0].allowsOther)
        } else {
            Issue.record("Expected userInputRequested")
        }
    }
}
