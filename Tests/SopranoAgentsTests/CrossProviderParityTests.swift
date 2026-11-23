import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

struct CrossProviderParityTests {
    // MARK: - Portable Teammate Memory & Team MCP Dispatcher

    @Test func teammateMemoryStoreRetainsAndRecallsEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("teammate-mem-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TeammateMemoryStore(databaseURL: root.appendingPathComponent("memory/soprano-memory.db"))

        let first = try store.retain(content: "Always use CDP over loopback 127.0.0.1, never embed WebKit.", tags: ["architecture,browser", "cdp"])
        _ = try store.retain(content: "Deployments run on Friday mornings with canary rollout.", tags: ["ops"])
        #expect(first.id > 0)

        let recalled = try store.recall(query: "webkit browser cdp")
        #expect(recalled.count == 1)
        #expect(recalled[0].content.contains("127.0.0.1"))
        #expect(recalled[0].tags == ["architecture,browser", "cdp"])

        let recent = try store.recall(query: "")
        #expect(recent.count == 2)
    }

    @Test func teamMCPDispatcherListsAndCallsTools() async throws {
        let client = MockTeamBridgeClient(
            tools: TeamTools.definitions(others: [Teammate(name: "CTO", handle: "cto", role: "Architecture", instructions: "")], callerIsTeammate: true)
                + TeamTools.memoryDefinitions()
        )
        let dispatcher = TeamMCPDispatcher(threadID: "t-1", client: client)

        let list = await dispatcher.handleJSONRPC(.object([
            "jsonrpc": .string("2.0"),
            "id": .number(1),
            "method": .string("tools/list"),
        ]))
        let names = (list?["result"]?["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        #expect(names.contains("team_message"))
        #expect(names.contains("team_list"))
        #expect(names.contains("memory_retain"))
        #expect(names.contains("memory_recall"))

        let call = await dispatcher.handleJSONRPC(.object([
            "jsonrpc": .string("2.0"),
            "id": .number(2),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string("team_list"),
                "arguments": .object([:]),
            ]),
        ]))
        let text = call?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        #expect(text == "called team_list on t-1")
    }

    @Test @MainActor func teammatesCanRunOnAnyProviderAndSwitchModelsBeforeFirstTurn() throws {
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("multi-team-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let env = EngineEnvironment(
            drivers: [:],
            git: FixtureGitService(),
            store: InMemoryThreadStore(),
            dataDirectory: dataDir
        )
        let engine = AgentEngine(environment: env, settings: EngineSettings())
        let created = try engine.createTeammate(TeammateDraft(
            name: "Reviewer",
            handle: "reviewer-bot",
            role: "Code review",
            instructions: "Review diffs carefully.",
            projectID: nil,
            exportsToOmp: false,
            provider: .claude
        ))
        #expect(engine.thread(created.threadID)?.modelSelection.provider == .claude)

        engine.setModelSelection(created.threadID, .default(for: .codex))
        #expect(engine.thread(created.threadID)?.modelSelection.provider == .codex)
    }

    // MARK: - Provider-agnostic Side Questions (/btw)

    @Test @MainActor func fallbackSideQuestionAnswersWithoutNativeSupportAndPersists() async throws {
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("side-q-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let codexDriver = StubJSONDriver(
            kind: .codex,
            capabilities: ProviderCapabilities(supportsSteer: true, supportsRollback: true, supportsPlanMode: true, supportsNativeSubagents: false, supportsNativeSideQuestions: false, supportsMCPInjection: true, supportsSystemPromptAppend: true, supportsHostTools: false),
            jsonResponse: .object(["answer": .string("It parses JSON-RPC 2.0 lines over stdio.")])
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var thread = AgentThread(id: "codex-1", projectID: nil, title: "Codex thread", createdAt: now, modelSelection: .default(for: .codex))
        thread.turns = [
            Turn(
                ordinal: 1,
                userMessage: UserMessage(text: "Explain AcpClient", createdAt: now),
                modelSelection: .default(for: .codex),
                status: .completed,
                startedAt: now,
                completedAt: now,
                items: [TurnItem(id: "m1", kind: .assistantMessage(text: "AcpClient handles JSON-RPC.", isFinal: true), status: .completed)]
            ),
        ]

        let store = InMemoryThreadStore(StoreSnapshot(threads: [thread]))
        let env = EngineEnvironment(
            drivers: [.codex: codexDriver],
            git: FixtureGitService(),
            store: store,
            dataDirectory: dataDir
        )
        let engine = AgentEngine(environment: env, settings: EngineSettings())
        let topicID = try await engine.askSideQuestion("codex-1", question: "What framing does it use?")
        await engine.runtime.waitForBackgroundWork()

        let questions = engine.sideQuestions("codex-1")
        #expect(questions.count == 1)
        #expect(questions[0].id == topicID)
        #expect(questions[0].first.status == .complete)
        #expect(questions[0].first.answer == "It parses JSON-RPC 2.0 lines over stdio.")

        // A fresh engine instance loads the persisted side question history from disk.
        let reloaded = AgentEngine(environment: env, settings: EngineSettings())
        try await reloaded.loadSideQuestions("codex-1")
        #expect(reloaded.sideQuestions("codex-1").count == 1)
        #expect(reloaded.sideQuestions("codex-1")[0].first.answer == "It parses JSON-RPC 2.0 lines over stdio.")
    }

    // MARK: - Cross-provider /review-with & Workflow settings

    @Test func reviewCommandParserHandlesProviderModelAndFocus() throws {
        let simple = try CrossProviderWorkflows.parseReviewCommand("/review-with codex")
        #expect(simple?.selection == ModelSelection(provider: .codex, model: ModelSelection.configuredDefaultModel))
        #expect(simple?.instructions == "")

        let detailed = try CrossProviderWorkflows.parseReviewCommand("/review-with claude/claude-opus-4-6 check race conditions")
        #expect(detailed?.selection == ModelSelection(provider: .claude, model: "claude-opus-4-6"))
        #expect(detailed?.instructions == "check race conditions")

        #expect(try CrossProviderWorkflows.parseReviewCommand("normal message") == nil)
        #expect(throws: EngineError.self) {
            _ = try CrossProviderWorkflows.parseReviewCommand("/review-with unknown-provider")
        }
    }

    @Test @MainActor func manualReviewCommandAppendsAdvisoryCardFromTargetProvider() async throws {
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("review-cmd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let reviewer = StubJSONDriver(
            kind: .codex,
            capabilities: ProviderKind.codex.capabilities,
            jsonResponse: .object([
                "notes": .array([
                    .object(["severity": .string("concern"), "text": .string("Add a unit test for empty input.")]),
                ]),
            ])
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var thread = AgentThread(id: "t-review", projectID: nil, title: "Feature", createdAt: now, modelSelection: .default(for: .claude))
        thread.turns = [
            Turn(ordinal: 1, userMessage: UserMessage(text: "Implement parser", createdAt: now), modelSelection: .default(for: .claude), status: .completed, startedAt: now, completedAt: now),
        ]

        let env = EngineEnvironment(
            drivers: [.codex: reviewer],
            git: FixtureGitService(),
            store: InMemoryThreadStore(StoreSnapshot(threads: [thread])),
            dataDirectory: dataDir
        )
        let engine = AgentEngine(environment: env, settings: EngineSettings())
        try await engine.send("t-review", text: "/review-with codex focus on edge cases", attachments: [])
        await engine.runtime.waitForBackgroundWork()

        let items = engine.thread("t-review")?.turns.last?.items ?? []
        let advisory = items.compactMap { item -> [AdvisorNote]? in
            if case let .advisory(notes) = item.kind { return notes }
            return nil
        }.first
        #expect(advisory?.count == 1)
        #expect(advisory?[0].severity == .concern)
        #expect(advisory?[0].text == "Add a unit test for empty input.")
        #expect(advisory?[0].advisor == "Codex")
    }

    @Test func settingsResolverParsesWorkflowsSection() throws {
        let json = """
        {
          "workflows": {
            "advisorEnabled": true,
            "advisorProvider": "codex",
            "advisorModel": "gpt-5.4",
            "advisorPrompt": "Check thread safety",
            "autoRecapEnabled": true
          }
        }
        """
        let resolved = try SettingsResolver.resolve(text: json)
        #expect(resolved.issues.isEmpty)
        #expect(resolved.settings.workflows.advisorEnabled == true)
        #expect(resolved.settings.workflows.advisorProvider == .codex)
        #expect(resolved.settings.workflows.advisorModel == "gpt-5.4")
        #expect(resolved.settings.workflows.advisorPrompt == "Check thread safety")
        #expect(resolved.settings.workflows.autoRecapEnabled == true)
    }

    // MARK: - Unified Usage Ledger & Composite Statistics

    @Test func compositeUsageStatisticsMergesAllProvidersWithoutDoubleCountingOmp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = LocalUsageLedger(fileURL: root.appendingPathComponent("usage-ledger.jsonl"))
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        ledger.record(LocalUsageLedger.Entry(timestamp: now, provider: "omp", model: "claude-opus-4-6", agent: "main", folder: "-app", inputTokens: 1000, outputTokens: 200))
        ledger.record(LocalUsageLedger.Entry(timestamp: now, provider: "codex", model: "gpt-5.4", agent: "main", folder: "-app", inputTokens: 2000, outputTokens: 500))
        ledger.record(LocalUsageLedger.Entry(timestamp: now, provider: "claude", model: "claude-sonnet-4-6", agent: "main", folder: "-app", inputTokens: 3000, outputTokens: 800))

        let ompGroup = UsageGroup(
            start: Calendar.current.startOfDay(for: now),
            provider: "anthropic",
            model: "claude-opus-4-6",
            agent: "main",
            folder: "-app",
            totals: UsageTotals(requests: 1, inputTokens: 1000, outputTokens: 200)
        )
        let composite = CompositeUsageStatistics(omp: StubUsageService(groups: [ompGroup]), ledger: ledger)
        let groups = try await composite.groups(since: nil, granularity: .day)

        // omp row from local ledger is skipped because omp stats returned data; codex + claude + omp stats = 3 groups.
        #expect(groups.count == 3)
        #expect(groups.contains { $0.provider == "codex" && $0.totals.inputTokens == 2000 && $0.totals.cost > 0 })
        #expect(groups.contains { $0.provider == "claude" && $0.totals.inputTokens == 3000 && $0.totals.cost > 0 })
        #expect(!groups.contains { $0.provider == "omp" })
    }

    // MARK: - Security & Spontaneous Background Wakeup Regression Tests

    @Test func teamBridgeRejectsNegativeContentLengthAndIsolatesPerThreadTokens() {
        let malicious = Data("POST /tools/call HTTP/1.1\r\nContent-Length: -1\r\n\r\n{}".utf8)
        if case .invalid = TeamBridgeServer.parseHTTPRequest(malicious) {
            // Expected: rejected safely before trapping on prefix(-1).
        } else {
            Issue.record("Expected negative Content-Length to parse as .invalid")
        }

        let server = TeamBridgeServer(listHandler: { _ in [] }, callHandler: { _, _, _ in HostToolResult(text: "") })
        let tokenA = server.token(for: "thread-a")
        let tokenB = server.token(for: "thread-b")
        #expect(tokenA != tokenB)
        #expect(server.token(for: "thread-a") == tokenA)
        server.revokeToken(for: "thread-a")
        #expect(server.token(for: "thread-a") != tokenA)
    }

    @Test @MainActor func spontaneousBackgroundWakeupReopensCompletedTurnAndDeliversReply() async throws {
        let dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("wakeup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var thread = AgentThread(id: "agy-1", projectID: nil, title: "Background task", createdAt: now, modelSelection: .default(for: .antigravity))
        thread.turns = [
            Turn(
                ordinal: 1,
                userMessage: UserMessage(text: "Run review in background", createdAt: now),
                modelSelection: .default(for: .antigravity),
                status: .completed,
                startedAt: now,
                completedAt: now,
                items: [TurnItem(id: "t1/message-1", kind: .assistantMessage(text: "Started review.", isFinal: true), status: .completed)]
            ),
        ]

        let env = EngineEnvironment(
            drivers: [:],
            git: FixtureGitService(),
            store: InMemoryThreadStore(StoreSnapshot(threads: [thread])),
            dataDirectory: dataDir
        )
        let engine = AgentEngine(environment: env, settings: EngineSettings())

        // Simulate Antigravity waking up from a background task after turn 1 already completed.
        engine.apply(.turnResumed, threadID: "agy-1")
        #expect(engine.thread("agy-1")?.isRunning == true)

        engine.apply(.assistantDelta(itemID: "t2/message-1", delta: "Review finished: 4 blockers found.", isFinal: true), threadID: "agy-1")
        engine.apply(.turnCompleted(outcome: .completed, error: nil), threadID: "agy-1")

        let finalThread = try #require(engine.thread("agy-1"))
        #expect(!finalThread.isRunning)
        #expect(finalThread.turns.last?.status == .completed)
        let messages = finalThread.turns.last?.items.compactMap { item -> String? in
            if case let .assistantMessage(text, _) = item.kind { return text }
            return nil
        } ?? []
        #expect(messages.contains("Started review."))
        #expect(messages.contains("Review finished: 4 blockers found."))
    }
}

private struct MockTeamBridgeClient: TeamBridgeClient {
    let tools: [HostToolDefinition]

    func listTools(threadID: String) async throws -> [HostToolDefinition] { tools }
    func callTool(threadID: String, name: String, arguments: JSONValue) async throws -> HostToolResult {
        HostToolResult(text: "called \(name) on \(threadID)")
    }
}

private struct StubJSONDriver: ProviderDriver {
    let kind: ProviderKind
    let capabilities: ProviderCapabilities
    let jsonResponse: JSONValue

    func probe() async -> ProviderStatus { ProviderStatus(kind: kind, health: .ready) }
    func makeSession() -> any ProviderSession { UnsupportedSession(kind: kind) }
    func generateJSON(prompt: String, schema: JSONValue, model: String, cwd: String) async throws -> JSONValue { jsonResponse }
}

private final class UnsupportedSession: ProviderSession, @unchecked Sendable {
    let kind: ProviderKind
    let events: AsyncStream<ProviderEvent>

    init(kind: ProviderKind) {
        self.kind = kind
        self.events = AsyncStream { $0.finish() }
    }

    func start(_ config: SessionConfig) async throws -> String { "stub" }
    func startTurn(_ input: TurnInput) async throws -> String? { nil }
    func steer(_ input: TurnInput) async throws {}
    func interrupt() async {}
    func respond(toApproval id: String, decision: ApprovalDecision) async {}
    func answer(userInput id: String, answers: [String: [String]]) async {}
    func compact() async throws { throw EngineError.message("unsupported") }
    func rollback(beforeTurn ordinal: Int, providerTurnID: String?) async throws { throw EngineError.message("unsupported") }
    func steerSubagent(_ id: String, text: String) async throws { throw EngineError.message("unsupported") }
    func cancelSubagent(_ id: String) async throws { throw EngineError.message("unsupported") }
    func askSideQuestion(_ question: String, topicID: String?) async throws -> SideQuestion { throw EngineError.message("unsupported") }
    func cancelSideQuestion() async -> Bool { false }
    func sideQuestions() async throws -> [SideQuestion] { [] }
    func close() async {}
}

private struct StubUsageService: UsageStatisticsService {
    let groups: [UsageGroup]
    func sync() async throws {}
    func groups(since: Date?, granularity: UsageGranularity) async throws -> [UsageGroup] { groups }
}
