import AppKit
import Testing
@testable import SopranoAgentsCore

struct OpencodeProtocolTests {
    private static func input(_ text: String, attachments: [SopranoAgentsCore.Attachment] = []) -> TurnInput {
        TurnInput(text: text, attachments: attachments, modelSelection: .default(for: .opencode), runtimeMode: .fullAccess)
    }

    private static func rules(_ mode: RuntimeMode) -> [String: String] {
        var effects: [String: String] = [:]
        for rule in OpencodeProtocol.permissions(mode).arrayValue ?? [] {
            effects[rule["action"]?.stringValue ?? ""] = rule["effect"]?.stringValue
        }
        return effects
    }

    // MARK: - Permissions

    @Test func eachRuntimeModeSetsTheSessionsPermissionRules() {
        #expect(Self.rules(.approvalRequired) == ["edit": "ask", "shell": "ask", "external_directory": "ask"])
        #expect(Self.rules(.autoAcceptEdits) == ["edit": "allow", "shell": "ask", "external_directory": "ask"])
        #expect(Self.rules(.auto).isEmpty)
        let full = Self.rules(.fullAccess)
        #expect(full["edit"] == "allow" && full["shell"] == "allow" && full["read"] == "allow")
        // Denies the user configured (skills, browser, …) are never lifted.
        #expect(full["*"] == nil && full["skill"] == nil)
    }

    @Test func declineLetsTheAgentCarryOnAndCancelStopsIt() {
        #expect(OpencodeProtocol.permissionReply(.accept) == ["decision": "once"])
        #expect(OpencodeProtocol.permissionReply(.acceptForSession) == ["decision": "always"])
        #expect(OpencodeProtocol.permissionReply(.cancel) == ["decision": "reject"])
        let decline = OpencodeProtocol.permissionReply(.decline)
        #expect(decline["decision"] == "reject")
        #expect(decline["message"]?.nonEmptyString != nil)
    }

    @Test func approvalsShowTheCommandOrTheFiles() throws {
        let shell = try #require(OpencodeProtocol.approval(["id": "per_1", "action": "shell", "resources": ["cat hello.txt"]], cwd: "/w"))
        #expect(shell.kind == .command)
        #expect(shell.detail == "cat hello.txt")

        let edit = try #require(OpencodeProtocol.approval([
            "id": "per_2", "action": "edit", "resources": ["../../private/tmp/oc-play/hello.txt"],
            "metadata": ["files": [["file": "/w/Sources/App.swift"]]],
        ], cwd: "/w"))
        #expect(edit.kind == .fileChange)
        #expect(edit.detail == "Sources/App.swift")

        let other = try #require(OpencodeProtocol.approval(["id": "per_3", "action": "webfetch", "resources": ["https://example.com"], "message": "Needs the docs"], cwd: nil))
        #expect(other.kind == .other)
        #expect(other.detail == "webfetch: https://example.com")
        #expect(other.reason == "Needs the docs")
    }

    // MARK: - Forms

    /// The form OpenCode 2.2.5 created for a `question` tool call.
    private static let questionForm: JSONValue = [
        "id": "frm_1", "sessionID": "ses_1", "title": "Questions",
        "fields": [
            ["key": "q0", "title": "Color", "description": "Which color do you prefer?", "type": "string", "custom": true,
             "options": [["value": "red", "label": "Red", "description": "Choose red"], ["value": "blue", "label": "Blue"]]],
            ["key": "q1", "title": "Extras", "type": "multiselect", "options": [["value": "a", "label": "A"], ["value": "b", "label": "B"]]],
            ["key": "q2", "title": "Ship it?", "type": "boolean"],
            ["key": "q3", "title": "Retries", "type": "integer"],
            ["key": "secret", "type": "string", "hidden": true],
            ["key": "link", "type": "external", "url": "https://example.com"],
        ],
    ]

    @Test func aFormBecomesQuestions() throws {
        let request = try #require(OpencodeProtocol.userInput(form: Self.questionForm))
        #expect(request.id == "frm_1")
        #expect(request.questions.map(\.id) == ["q0", "q1", "q2", "q3"])
        let color = request.questions[0]
        #expect(color.header == "Color")
        #expect(color.question == "Which color do you prefer?")
        #expect(color.options == [UserInputOption(label: "Red", description: "Choose red"), UserInputOption(label: "Blue")])
        #expect(color.allowsOther && !color.allowsMultiple)
        #expect(request.questions[1].allowsMultiple && !request.questions[1].allowsOther)
        #expect(request.questions[1].question == "Extras")
        #expect(request.questions[2].options.map(\.label) == ["Yes", "No"])
        #expect(request.questions[3].options.isEmpty && request.questions[3].allowsOther)
    }

    @Test func answersBecomeTheFormsValues() {
        let reply = OpencodeProtocol.formReply(form: Self.questionForm, answers: [
            "q0": ["Blue"], "q1": ["A", "B"], "q2": ["No"], "q3": ["3"], "unknown": ["x"],
        ])
        #expect(reply == ["answer": ["q0": "blue", "q1": ["a", "b"], "q2": false, "q3": 3]])
        // A free-text answer passes through; unparsable numbers and blank answers are left out.
        let custom = OpencodeProtocol.formReply(form: Self.questionForm, answers: ["q0": ["Green"], "q3": ["many"], "q1": [" "]])
        #expect(custom == ["answer": ["q0": "Green"]])
    }

    // MARK: - Messages

    @Test func aListedSlashCommandRunsAsACommand() {
        let message = OpencodeProtocol.message(Self.input("  /review branch main"), commands: ["review"], skills: [])
        #expect(message == .command(["name": "review", "text": "branch main"]))
    }

    @Test func aSkillIsAttachedToThePrompt() {
        let message = OpencodeProtocol.message(Self.input("/skill:archify draw the flow"), commands: [], skills: ["archify"])
        #expect(message == .prompt(["text": "draw the flow", "skills": [["id": "archify"]]]))
    }

    @Test func unknownSlashTextIsAnOrdinaryPrompt() {
        #expect(OpencodeProtocol.message(Self.input("/usr/bin is on PATH?"), commands: ["review"], skills: []) == .prompt(["text": "/usr/bin is on PATH?"]))
    }

    @Test func imagesGoAlongAsFileAttachmentsAndEveryPathIsListed() {
        let image = SopranoAgentsCore.Attachment(kind: .image, name: "shot.png", path: "/data/a b/shot.png", mimeType: "image/png", byteSize: 4)
        let log = SopranoAgentsCore.Attachment(kind: .file, name: "log.txt", path: "/data/log.txt", mimeType: "text/plain", byteSize: 4)
        let message = OpencodeProtocol.message(Self.input("Look", attachments: [image, log]), commands: [], skills: [], delivery: "steer")
        guard case let .prompt(body) = message else { Issue.record("not a prompt"); return }
        #expect(body["files"] == [["uri": "file:///data/a%20b/shot.png", "name": "shot.png"]])
        #expect(body["delivery"] == "steer")
        let text = body["text"]?.stringValue ?? ""
        #expect(text.hasPrefix("Look"))
        #expect(text.contains("/data/a b/shot.png") && text.contains("/data/log.txt"))
    }

    @Test func commandsAndSkillsBecomeMenuEntries() {
        let entries = OpencodeProtocol.commands(
            [["name": "review", "description": "review changes"], ["name": "rea:audit"]],
            skills: [["id": "archify", "name": "archify", "description": "Diagrams", "content": "…"]]
        )
        #expect(entries.map(\.insertText) == ["/review ", "/rea:audit ", "/skill:archify "])
        #expect(entries.map(\.kind) == [.command, .command, .skill])
        #expect(entries.map(\.source) == [nil, "MCP", "Skill"])
    }

    // MARK: - Models

    @Test func theCatalogStartsWithTheConfiguredModelAndOffersVariants() {
        let opus: JSONValue = ["id": "opus", "providerID": "claude-agent", "name": "Opus 5.5", "enabled": true,
                               "variants": [["id": "low"], ["id": "high"]], "limit": ["context": 1_000_000]]
        let off: JSONValue = ["id": "old", "providerID": "openai", "name": "Old", "enabled": false]
        let plain: JSONValue = ["id": "deepseek/v4", "providerID": "opengateway", "name": "DeepSeek V4", "variants": [], "limit": ["context": 64000]]
        let models = OpencodeProtocol.models(list: [opus, off, plain], defaultModel: opus)
        #expect(models.map(\.slug) == ["default", "claude-agent/opus", "opengateway/deepseek/v4"])
        #expect(models.map(\.name) == ["Opus 5.5 · configured", "Opus 5.5 · claude-agent", "DeepSeek V4 · opengateway"])
        #expect(models[0].isDefault)
        #expect(models[1].option(ModelOptionID.effort)?.choices.map(\.id) == ["default", "low", "high"])
        #expect(models[1].option(ModelOptionID.effort)?.defaultValue == "default")
        #expect(models[2].options.isEmpty)
        #expect(OpencodeProtocol.contextWindows(list: [opus, plain], defaultModel: opus) == [
            "claude-agent/opus": 1_000_000, "opengateway/deepseek/v4": 64000, "default": 1_000_000,
        ])
        let spec = OpencodeProtocol.modelSpec("opengateway/deepseek/v4")
        #expect(spec?.provider == "opengateway" && spec?.id == "deepseek/v4")
        #expect(OpencodeProtocol.modelSpec("default") == nil)
    }

    @Test func theVersionComesFromTheVersionLine() {
        #expect(OpencodeProtocol.version(fromVersionOutput: "opencode v2.2.5\n") == "2.2.5")
    }

    @Test func theContextFillCountsEverythingTheNextRequestCarries() {
        let usage = OpencodeProtocol.contextUsage(["input": 2, "output": 322, "reasoning": 155, "cache": ["read": 28389, "write": 4452]], contextWindow: 200_000)
        #expect(usage == TokenUsage(usedTokens: 33165, contextWindow: 200_000))
        #expect(OpencodeProtocol.contextUsage(["input": 0, "output": 0, "cache": ["read": 0, "write": 0]], contextWindow: nil) == nil)
    }

    // MARK: - Event stream

    @Test func theEventStreamYieldsOnePayloadPerDataLine() {
        var decoder = OpencodeEventStreamDecoder()
        #expect(decoder.decode(": heartbeat") == nil)
        #expect(decoder.decode("data: {\"type\":\"server.connected\",\"data\":{}}") == ["type": "server.connected", "data": [:]])
        #expect(decoder.decode("") == nil)
        // A payload split over two data lines.
        #expect(decoder.decode("data: {\"type\":\"a\",") == nil)
        #expect(decoder.decode("data: \"data\":{}}") == ["type": "a", "data": [:]])
    }
}
