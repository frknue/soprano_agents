import AppKit
import Testing
@testable import SopranoAgentsCore

/// `OpencodeSession` against a fake server: requests are recorded and answered like OpenCode
/// 2.2.5, events are pushed into the stream (recorded traces in `Fixtures/opencode-*.jsonl`).
struct OpencodeSessionTests {
    /// Records requests; `answer` decides responses; `push` feeds the event stream.
    final class FakeServer: OpencodeTransport, @unchecked Sendable {
        struct Request: Sendable, Hashable {
            var method: String
            var path: String
            var body: JSONValue?
        }

        private let lock = NSLock()
        private var recorded: [Request] = []
        private var continuation: AsyncThrowingStream<JSONValue, any Error>.Continuation?
        var answer: @Sendable (Request) throws -> JSONValue = { _ in .null }
        /// Runs before a request is answered (to act while the session awaits it).
        var beforeAnswer: @Sendable (Request) async -> Void = { _ in }

        var requests: [Request] { lock.withLock { recorded } }

        func request(_ method: String, _ path: String, query: [String: String], body: JSONValue?, timeout: TimeInterval) async throws -> JSONValue {
            let request = Request(method: method, path: path, body: body)
            lock.withLock { recorded.append(request) }
            await beforeAnswer(request)
            return try answer(request)
        }

        func list(_ path: String, directory: String, retryWhileEmpty: Bool) async throws -> JSONValue {
            try await request("GET", path, query: [:], body: nil, timeout: 1)["data"] ?? []
        }

        func events() async throws -> AsyncThrowingStream<JSONValue, any Error> {
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: JSONValue.self)
            lock.withLock { self.continuation = continuation }
            continuation.yield(["type": "server.connected", "data": [:]])
            return stream
        }

        func push(_ events: [JSONValue]) {
            let continuation = lock.withLock { self.continuation }
            for event in events { continuation?.yield(event) }
        }

        func breakStream() {
            lock.withLock { continuation }?.finish(throwing: URLError(.networkConnectionLost))
        }
    }

    /// Collects a session's events as they arrive.
    actor Recorder {
        private(set) var events: [ProviderEvent] = []
        func add(_ event: ProviderEvent) { events.append(event) }

        func wait(timeout: TimeInterval = 5, until done: @Sendable ([ProviderEvent]) -> Bool) async throws {
            let start = Date()
            while !done(events) {
                guard Date().timeIntervalSince(start) < timeout else {
                    Issue.record("timed out; events: \(events)")
                    return
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    static let cwd = "/private/tmp"
    static let sessionID = "ses_e57b64180ffexxbafir4756K4D"

    /// OpenCode's answers for a fresh session in `cwd`.
    static func standardAnswers(_ request: FakeServer.Request) throws -> JSONValue {
        switch (request.method, request.path) {
        case ("GET", "/api/model"):
            return ["data": [["id": "haiku", "providerID": "claude-agent", "name": "Haiku", "variants": [["id": "high"]], "limit": ["context": 200_000]]]]
        case ("GET", "/api/model/default"):
            return ["data": ["id": "opus", "providerID": "claude-agent", "name": "Opus", "limit": ["context": 1_000_000]]]
        case ("POST", "/api/session"):
            return ["data": ["id": .string(sessionID), "location": ["directory": .string(cwd)], "model": request.body?["model"] ?? .null, "permissions": request.body?["permissions"] ?? []]]
        case ("GET", "/api/command"):
            return ["data": [["name": "review"]]]
        case ("GET", "/api/skill"):
            return ["data": [["id": "archify", "name": "archify"]]]
        case ("POST", "/api/session/\(sessionID)/prompt"):
            return ["data": ["id": "msg_turn", "type": "user"]]
        case ("GET", "/api/session/\(sessionID)"):
            return ["data": ["id": .string(sessionID), "location": ["directory": .string(cwd)], "model": ["id": "haiku", "providerID": "claude-agent", "variant": "default"], "permissions": OpencodeProtocol.permissions(.approvalRequired)]]
        default:
            return .null
        }
    }

    static func trace(_ name: String) throws -> [JSONValue] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONValue.parse(String($0)) }
    }

    static func start(
        _ server: FakeServer,
        model: String = "claude-agent/haiku",
        mode: RuntimeMode = .approvalRequired,
        resume: String? = nil,
        sideQuestions: OpencodeSideQuestionStore = OpencodeSideQuestionStore()
    ) async throws -> (OpencodeSession, Recorder) {
        let session = OpencodeSession(server: server, sideQuestions: sideQuestions)
        let recorder = Recorder()
        let events = session.events
        Task { for await event in events { await recorder.add(event) } }
        _ = try await session.start(SessionConfig(cwd: cwd, modelSelection: ModelSelection(provider: .opencode, model: model), runtimeMode: mode, resumeID: resume))
        return (session, recorder)
    }

    static func input(_ text: String, model: String = "claude-agent/haiku", effort: String? = nil, mode: RuntimeMode = .approvalRequired) -> TurnInput {
        var selection = ModelSelection(provider: .opencode, model: model)
        selection.effort = effort
        return TurnInput(text: text, attachments: [], modelSelection: selection, runtimeMode: mode)
    }

    static func ended(_ events: [ProviderEvent]) -> Bool {
        events.contains { if case .turnCompleted = $0 { true } else { false } }
    }

    // MARK: - Start

    @Test func aNewSessionStartsInTheWorkspaceWithTheModeAndModel() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, recorder) = try await Self.start(server)

        let create = try #require(server.requests.first { $0.method == "POST" && $0.path == "/api/session" })
        #expect(create.body?["location"] == ["directory": .string(Self.cwd)])
        #expect(create.body?["permissions"] == OpencodeProtocol.permissions(.approvalRequired))
        #expect(create.body?["model"] == ["id": "haiku", "providerID": "claude-agent", "variant": "default"])
        // The created session already runs the selection: nothing to switch.
        #expect(!server.requests.contains { $0.path.hasSuffix("/model") && $0.method == "POST" })
        try await recorder.wait { $0.contains(.conversationID(Self.sessionID)) }
        try await recorder.wait { events in
            events.contains { if case let .commands(list) = $0 { list.map(\.insertText) == ["/review ", "/skill:archify "] } else { false } }
        }
        await session.close()
    }

    @Test func aSessionOpenCodeNoLongerHasStartsFresh() async throws {
        let server = FakeServer()
        server.answer = { request in
            if request.method == "GET", request.path == "/api/session/ses_gone" {
                throw ProviderError.rpc(method: "GET /api/session/ses_gone", code: 404, message: "Session not found")
            }
            return try Self.standardAnswers(request)
        }
        let (session, _) = try await Self.start(server, resume: "ses_gone")
        #expect(server.requests.contains { $0.method == "POST" && $0.path == "/api/session" })
        await session.close()
    }

    // MARK: - Turns

    @Test func aTurnReportsItsUserMessageAsNativeIDAndEndsWithItsExecution() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, recorder) = try await Self.start(server)
        _ = try await session.startTurn(Self.input("Create a file"))
        server.push(try Self.trace("opencode-tool-turn.jsonl"))
        try await recorder.wait(until: Self.ended)

        let events = await recorder.events
        #expect(events.contains(.turnStarted(providerTurnID: "msg_1a849bec2001WIxszFqBgNimPX")))
        #expect(events.last == .turnCompleted(outcome: .completed, error: nil))
        #expect(events.contains { if case let .tokenUsage(usage) = $0 { usage.contextWindow == 200_000 } else { false } })
        let prompt = try #require(server.requests.first { $0.path == "/api/session/\(Self.sessionID)/prompt" })
        #expect(prompt.body?["text"] == "Create a file")
        await session.close()
    }

    @Test func aListedSlashCommandRunsAsACommand() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, _) = try await Self.start(server)
        _ = try await session.startTurn(Self.input("/review branch"))
        let command = try #require(server.requests.first { $0.path == "/api/session/\(Self.sessionID)/command" })
        #expect(command.body == ["name": "review", "text": "branch"])
        await session.close()
    }

    @Test func eventsWhileNoTurnOfTheAppRunsAreIgnored() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, recorder) = try await Self.start(server)
        server.push(try Self.trace("opencode-tool-turn.jsonl"))
        try await Task.sleep(nanoseconds: 200_000_000)
        let events = await recorder.events
        #expect(!events.contains { if case .itemUpdated = $0 { true } else { false } })
        #expect(!Self.ended(events))
        await session.close()
    }

    @Test func modelVariantAndModeChangesApplyBeforeTheTurnOnlyWhenTheyChanged() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, recorder) = try await Self.start(server)
        _ = try await session.startTurn(Self.input("one", effort: "high", mode: .fullAccess))
        server.push([["type": "session.execution.succeeded", "data": ["sessionID": .string(Self.sessionID)]]])
        try await recorder.wait(until: Self.ended)
        _ = try await session.startTurn(Self.input("two", effort: "high", mode: .fullAccess))

        let switches = server.requests.filter { $0.method == "POST" && $0.path == "/api/session/\(Self.sessionID)/model" }
        #expect(switches.map(\.body) == [["model": ["id": "haiku", "providerID": "claude-agent", "variant": "high"]]])
        let patches = server.requests.filter { $0.method == "PATCH" }
        #expect(patches.map(\.body) == [["permissions": OpencodeProtocol.permissions(.fullAccess)]])
        await session.close()
    }

    @Test func theConfiguredModelIsUsedForDefault() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, _) = try await Self.start(server, model: ModelSelection.configuredDefaultModel)
        let create = try #require(server.requests.first { $0.method == "POST" && $0.path == "/api/session" })
        #expect(create.body?["model"] == ["id": "opus", "providerID": "claude-agent", "variant": "default"])
        await session.close()
    }

    @Test func stopWithNothingRunningEndsTheTurnHere() async throws {
        let server = FakeServer()
        server.answer = { request in
            if request.path.hasSuffix("/interrupt") { return ["interrupted": false] }
            return try Self.standardAnswers(request)
        }
        let (session, recorder) = try await Self.start(server)
        _ = try await session.startTurn(Self.input("hi"))
        await session.interrupt()
        try await recorder.wait(until: Self.ended)
        #expect(await recorder.events.last == .turnCompleted(outcome: .interrupted, error: nil))
        await session.close()
    }

    // MARK: - Requests

    @Test func aDeclinedApprovalLetsTheAgentCarryOn() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, recorder) = try await Self.start(server)
        _ = try await session.startTurn(Self.input("Run echo first"))
        let trace = try Self.trace("opencode-decline-turn.jsonl")
        let asked = try #require(trace.firstIndex { $0["type"] == "permission.asked" })
        server.push(Array(trace[...asked]))
        try await recorder.wait { events in events.contains { if case .approvalRequested = $0 { true } else { false } } }

        let approval = await recorder.events.compactMap { event -> ApprovalRequest? in
            if case let .approvalRequested(request) = event { request } else { nil }
        }.first
        // The tool call's whole line, not OpenCode's parsed pieces.
        #expect(approval?.detail == "echo first")
        await session.respond(toApproval: "per_1a84b32ac001AeVr86AGAOe51w", decision: .decline)
        let reply = try #require(server.requests.last)
        #expect(reply.path == "/api/session/\(Self.sessionID)/permission/per_1a84b32ac001AeVr86AGAOe51w/reply")
        #expect(reply.body == OpencodeProtocol.permissionReply(.decline))

        server.push(Array(trace[(asked + 1)...]))
        try await recorder.wait(until: Self.ended)
        let events = await recorder.events
        // Answered here: no withdrawal.
        #expect(!events.contains(.requestResolved(id: "per_1a84b32ac001AeVr86AGAOe51w")))
        #expect(events.last == .turnCompleted(outcome: .completed, error: nil))
        await session.close()
    }

    @Test func theTurnsEndWithdrawsQuestionsNobodyAnswered() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, recorder) = try await Self.start(server)
        _ = try await session.startTurn(Self.input("Ask me"))
        let trace = try Self.trace("opencode-question-turn.jsonl")
        let created = try #require(trace.firstIndex { $0["type"] == "form.created" })
        server.push(Array(trace[...created]))
        server.push([["type": "session.execution.interrupted", "data": ["sessionID": .string(Self.sessionID), "reason": "user"]]])
        try await recorder.wait(until: Self.ended)

        let events = await recorder.events
        let resolved = try #require(events.firstIndex(of: .requestResolved(id: "frm_1a84b4dae001ItFvEYX34MjCA6")))
        let ended = try #require(events.lastIndex(of: .turnCompleted(outcome: .interrupted, error: nil)))
        #expect(resolved < ended)
        await session.close()
    }

    @Test func answersGoToTheFormAndDismissingCancelsIt() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, recorder) = try await Self.start(server)
        _ = try await session.startTurn(Self.input("Ask me"))
        let trace = try Self.trace("opencode-question-turn.jsonl")
        server.push(Array(trace[...(try #require(trace.firstIndex { $0["type"] == "form.created" }))]))
        try await recorder.wait { events in events.contains { if case .userInputRequested = $0 { true } else { false } } }

        await session.answer(userInput: "frm_1a84b4dae001ItFvEYX34MjCA6", answers: ["q0": ["Blue"]])
        let reply = try #require(server.requests.last)
        #expect(reply.method == "POST")
        #expect(reply.path == "/api/session/\(Self.sessionID)/form/frm_1a84b4dae001ItFvEYX34MjCA6/reply")
        #expect(reply.body == ["answer": ["q0": "Blue"]])
        await session.close()
    }

    // MARK: - Subagents

    @Test func aSubagentSessionIsReportedAsASubagentWithItsRun() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, recorder) = try await Self.start(server)
        _ = try await session.startTurn(Self.input("Use the explore subagent"))
        server.push(try Self.trace("opencode-subagent-turn.jsonl"))
        try await recorder.wait(until: Self.ended)

        let subagent = await recorder.events.compactMap { event -> SubagentEvent? in
            if case let .subagent(id, change) = event, id == "clever-planet" { change } else { nil }
        }
        let infos = subagent.compactMap { if case let .updated(info) = $0 { info } else { nil } }
        #expect(infos.first?.agent == "explore")
        #expect(infos.first?.description == "List directory files")
        #expect(infos.first?.model == "claude-agent/haiku")
        #expect(infos.contains { $0.parentToolCallID == "toolu_01Ryo1CnKX1BgJcAwgsGFraF" })
        let runs = subagent.compactMap { if case let .runStarted(message) = $0 { message } else { nil } }
        #expect(runs.count == 1)
        #expect(runs.first?.hasPrefix("List the files that exist in /private/tmp/oc-play") == true)
        #expect(subagent.contains { if case let .itemUpdated(item) = $0 { item.id == "toolu_01Hc9fK88sxMWofFAg6KUKVG" } else { false } })
        #expect(subagent.contains(.runEnded(outcome: .completed, error: nil)))
        #expect(infos.last?.status == .completed)

        try await session.steerSubagent("clever-planet", text: "Also count them")
        #expect(server.requests.last == .init(method: "POST", path: "/api/session/ses_e57b363ccffeWNUSB4FZkK4kOj/prompt", body: ["text": "Also count them", "delivery": "steer"]))
        await session.close()
    }

    @Test func aSubagentsApprovalIsAnsweredInItsSession() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, recorder) = try await Self.start(server)
        _ = try await session.startTurn(Self.input("go"))
        server.push([
            ["type": "session.created", "data": ["sessionID": "ses_child", "slug": "quiet-river", "parentID": .string(Self.sessionID), "agent": "general"]],
            ["type": "permission.asked", "data": ["id": "per_9", "sessionID": "ses_child", "action": "shell", "resources": ["make"]]],
        ])
        try await recorder.wait { events in events.contains { if case .approvalRequested = $0 { true } else { false } } }
        let approval = await recorder.events.compactMap { if case let .approvalRequested(request) = $0 { request } else { nil } }.first
        #expect(approval?.reason == "Asked by subagent quiet-river.")
        await session.respond(toApproval: "per_9", decision: .accept)
        #expect(server.requests.last == .init(method: "POST", path: "/api/session/ses_child/permission/per_9/reply", body: ["decision": "once"]))
        await session.close()
    }

    // MARK: - Conversation

    @Test func rollbackRewindsToTheTurnsUserMessage() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, _) = try await Self.start(server)
        try await session.rollback(beforeTurn: 2, providerTurnID: "msg_2")
        #expect(server.requests.suffix(2) == [
            .init(method: "POST", path: "/api/session/\(Self.sessionID)/revert/stage", body: ["messageID": "msg_2", "files": false]),
            .init(method: "POST", path: "/api/session/\(Self.sessionID)/revert/commit", body: nil),
        ])
        await #expect(throws: ProviderError.self) { try await session.rollback(beforeTurn: 1, providerTurnID: nil) }
        await session.close()
    }

    @Test func sideQuestionsAreAnsweredFromTheConversationAndKeptForTheRun() async throws {
        let server = FakeServer()
        server.answer = { request in
            if request.path == "/api/session/\(Self.sessionID)/generate" {
                let prompt = request.body?["prompt"]?.stringValue ?? ""
                return ["data": ["text": .string(prompt.contains("Earlier in this side discussion") ? "Still a.txt." : "We created a.txt.")]]
            }
            return try Self.standardAnswers(request)
        }
        let (session, recorder) = try await Self.start(server)
        let topic = try await session.askSideQuestion("Which file?", topicID: nil)
        try await recorder.wait { events in
            events.contains { if case let .sideQuestion(record) = $0 { record.latest.status == .complete } else { false } }
        }
        #expect(await recorder.events.contains(.sideQuestionDelta(id: topic.id, delta: "We created a.txt.")))

        _ = try await session.askSideQuestion("Sure?", topicID: topic.id)
        try await recorder.wait { events in
            events.contains { if case let .sideQuestion(record) = $0 { record.followUps.first?.status == .complete } else { false } }
        }
        let history = try await session.sideQuestions()
        #expect(history.count == 1)
        #expect(history.first?.exchanges.map(\.answer) == ["We created a.txt.", "Still a.txt."])
        await session.close()
    }

    @Test func aBrokenEventStreamEndsTheSession() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, recorder) = try await Self.start(server)
        server.breakStream()
        try await recorder.wait { events in
            events.contains { if case let .sessionEnded(error) = $0 { error?.hasPrefix("Lost the connection to OpenCode") == true } else { false } }
        }
        withExtendedLifetime(session) {}
    }

    // MARK: - Races and other clients

    @Test func aStopThatFoundNothingLetsTheJustFinishedTurnEndAsItDid() async throws {
        let server = FakeServer()
        server.answer = { request in
            if request.path.hasSuffix("/interrupt") { return ["interrupted": false] }
            return try Self.standardAnswers(request)
        }
        let (session, recorder) = try await Self.start(server)
        _ = try await session.startTurn(Self.input("hi"))
        // The execution ended just before Stop; its event arrives after Stop's answer.
        async let stop: Void = session.interrupt()
        try await Task.sleep(nanoseconds: 100_000_000)
        server.push([["type": "session.execution.succeeded", "data": ["sessionID": .string(Self.sessionID)]]])
        await stop
        try await recorder.wait(until: Self.ended)
        let endings = await recorder.events.filter { if case .turnCompleted = $0 { true } else { false } }
        #expect(endings == [.turnCompleted(outcome: .completed, error: nil)])
        await session.close()
    }

    @Test func closingWhileStartingLeavesNoSessionBehind() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let session = OpencodeSession(server: server)
        server.beforeAnswer = { request in
            if request.method == "POST", request.path == "/api/session" { await session.close() }
        }
        await #expect(throws: ProviderError.self) {
            _ = try await session.start(SessionConfig(cwd: Self.cwd, modelSelection: ModelSelection(provider: .opencode, model: "claude-agent/haiku"), runtimeMode: .fullAccess))
        }
        #expect(server.requests.contains(.init(method: "DELETE", path: "/api/session/\(Self.sessionID)", body: nil)))
        #expect(!server.requests.contains { $0.method == "PATCH" || ($0.method == "POST" && $0.path.hasSuffix("/model")) })
    }

    @Test func anotherClientsSubagentsAreNotThisThreads() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, recorder) = try await Self.start(server)
        server.push([["type": "session.created", "data": ["sessionID": "ses_tui_child", "slug": "loud-owl", "parentID": .string(Self.sessionID), "agent": "general"]]])
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!(await recorder.events).contains { if case .subagent = $0 { true } else { false } })
        await session.close()
    }

    @Test func aSubagentWokenAfterTheTurnCarriesOnWithoutAnUnseenPrompt() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, recorder) = try await Self.start(server)
        _ = try await session.startTurn(Self.input("go"))
        server.push([
            ["type": "session.created", "data": ["sessionID": "ses_child", "slug": "quiet-river", "parentID": .string(Self.sessionID), "agent": "general"]],
            ["type": "session.execution.succeeded", "data": ["sessionID": .string(Self.sessionID)]],
        ])
        try await recorder.wait(until: Self.ended)
        server.push([["type": "permission.asked", "data": ["id": "per_late", "sessionID": "ses_child", "action": "shell", "resources": ["make"]]]])
        let reply = FakeServer.Request(method: "POST", path: "/api/session/ses_child/permission/per_late/reply", body: OpencodeProtocol.permissionReply(.decline))
        let start = Date()
        while !server.requests.contains(reply), Date().timeIntervalSince(start) < 5 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(server.requests.contains(reply))
        #expect(!(await recorder.events).contains { if case .approvalRequested = $0 { true } else { false } })
        await session.close()
    }

    @Test func aResumedSessionKeepsTheSideQuestionTopicsOfTheOneBefore() async throws {
        let server = FakeServer()
        server.answer = { request in
            if request.path == "/api/session/\(Self.sessionID)/generate" {
                let prompt = request.body?["prompt"]?.stringValue ?? ""
                return ["data": ["text": .string(prompt.contains("Answer: We created a.txt.") ? "Still a.txt." : "We created a.txt.")]]
            }
            return try Self.standardAnswers(request)
        }
        let store = OpencodeSideQuestionStore()
        let (first, firstRecorder) = try await Self.start(server, sideQuestions: store)
        let topic = try await first.askSideQuestion("Which file?", topicID: nil)
        try await firstRecorder.wait { events in
            events.contains { if case let .sideQuestion(record) = $0 { record.latest.status == .complete } else { false } }
        }
        await first.close()

        let (second, secondRecorder) = try await Self.start(server, resume: Self.sessionID, sideQuestions: store)
        #expect(try await second.sideQuestions().map(\.id) == [topic.id])
        let followUp = try await second.askSideQuestion("Sure?", topicID: topic.id)
        #expect(followUp.id == topic.id)
        try await secondRecorder.wait { events in
            events.contains { if case let .sideQuestion(record) = $0 { record.followUps.first?.status == .complete } else { false } }
        }
        #expect(try await second.sideQuestions().first?.exchanges.map(\.answer) == ["We created a.txt.", "Still a.txt."])
        await second.close()
    }

    @Test func closingWhileATurnAppliesItsSelectionSendsNoPrompt() async throws {
        let server = FakeServer()
        server.answer = Self.standardAnswers
        let (session, _) = try await Self.start(server)
        server.beforeAnswer = { request in
            if request.method == "POST", request.path.hasSuffix("/model") { await session.close() }
        }
        await #expect(throws: ProviderError.self) {
            _ = try await session.startTurn(Self.input("hi", effort: "high", mode: .fullAccess))
        }
        #expect(!server.requests.contains { $0.method == "PATCH" || ($0.method == "POST" && ($0.path.hasSuffix("/prompt") || $0.path.hasSuffix("/command"))) })
    }
}
