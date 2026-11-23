import Foundation

/// One Codex conversation: `codex app-server --stdio` (one process per thread) driven over
/// JSON-RPC 2.0 (`AcpClient`).
///
/// Start: `initialize` → `initialized`, then `thread/resume` for `resumeID` (falling back to
/// `thread/start` if the saved thread no longer exists) or `thread/start` (passing `cwd`, model,
/// approval/sandbox policy, and optional `developerInstructions` from `systemPromptFile`).
/// Also queries `skills/list` to populate the composer's `/` menu with Codex skills.
///
/// Turns: `turn/start` with text, skill blocks, local images, model/effort/fast-mode overrides,
/// and `collaborationMode` when Plan mode is active. Steering uses `turn/steer` with
/// `expectedTurnId`; interruption uses `turn/interrupt` with a 5 s fallback grace. Compaction
/// uses `thread/compact/start`; rollback uses `thread/rollback {threadId, numTurns}`.
public actor CodexSession: ProviderSession {
    public nonisolated let kind = ProviderKind.codex
    public nonisolated let events: AsyncStream<ProviderEvent>

    static let startupTimeout: TimeInterval = 45
    static let requestTimeout: TimeInterval = 30
    private let interruptGrace: Duration

    private struct PendingRequest {
        var rpcID: JSONValue
        var method: String
    }

    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let executablePath: @Sendable () -> String?
    private let launchAdjustments: @Sendable () -> ProviderLaunchAdjustments
    private var config: SessionConfig?
    private var client: AcpClient?
    private var threadID: String?
    private var defaultModel: String?
    private var defaultEffort: String?
    private var mapper = CodexEventMapper()
    private var skillPaths: [String: String] = [:]
    private var runtimeMode: RuntimeMode = .fullAccess
    private var previousModeWasPlan = false
    private var activeTurnID: String?
    private var completedTurnIDs: [String] = []
    private var isCompacting = false
    private var pending: [String: PendingRequest] = [:]
    private var isClosing = false
    private var hasEnded = false

    public init(
        executablePath: @escaping @Sendable () -> String? = { nil },
        launchAdjustments: @escaping @Sendable () -> ProviderLaunchAdjustments = { .none },
        interruptGrace: Duration = .seconds(5)
    ) {
        self.executablePath = executablePath
        self.launchAdjustments = launchAdjustments
        self.interruptGrace = interruptGrace
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .unbounded)
    }

    // MARK: - Lifecycle

    public func start(_ config: SessionConfig) async throws -> String {
        guard self.config == nil, !hasEnded else {
            throw ProviderError.message("The Codex session was already started.")
        }
        try ProviderError.requireWorkspace(config.cwd)
        let explicit = executablePath()
        guard let executable = CodexProtocol.locateExecutable(explicitPath: explicit) else {
            throw ProviderError.notInstalled(.codex, path: explicit)
        }
        self.config = config
        self.runtimeMode = config.runtimeMode
        self.mapper = CodexEventMapper(cwd: config.cwd)

        let adjustments = launchAdjustments()
        let process = LineProcess(LineProcess.Configuration(
            executable: executable,
            arguments: CodexProtocol.arguments(mcpServers: config.mcpServers, adjustments: adjustments),
            environment: CodexProtocol.environment(adjustments: adjustments),
            directory: config.cwd
        ))
        do {
            try process.start()
        } catch {
            throw ProviderError.spawnFailed(error.localizedDescription)
        }
        let client = AcpClient(transport: process, kind: .codex)
        self.client = client
        Task { await self.consume(client.incoming) }

        do {
            let id = try await withProviderTimeout(Self.startupTimeout, label: "Codex startup") {
                _ = try await client.request("initialize", CodexProtocol.initializeParams)
                try await client.notify("initialized")
                return try await self.openThread(client, config: config)
            }
            try requireOpen()
            threadID = id
            continuation.yield(.conversationID(id))
            await loadSkills(client, cwd: config.cwd)
            return id
        } catch {
            isClosing = true
            await client.close()
            finish(error: nil)
            throw error
        }
    }

    private func openThread(_ client: AcpClient, config: SessionConfig) async throws -> String {
        let instructions = config.systemPromptFile.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }

        var shared: [String: JSONValue] = [
            "cwd": .string(config.cwd),
            "approvalPolicy": .string(CodexProtocol.approvalPolicy(for: config.runtimeMode)),
            "sandbox": .string(CodexProtocol.sandboxMode(for: config.runtimeMode)),
        ]
        if let model = CodexProtocol.modelValue(config.modelSelection) {
            shared["model"] = .string(model)
        }
        if config.modelSelection.fastMode {
            shared["serviceTier"] = "fast"
        }
        if let instructions {
            shared["developerInstructions"] = .string(instructions)
        }

        if let resumeID = config.resumeID {
            var resumeParams = shared
            resumeParams["threadId"] = .string(resumeID)
            if let resumed = try? await client.request("thread/resume", .object(resumeParams)),
               let id = resumed["thread"]?["id"]?.nonEmptyString {
                readThreadMetadata(resumed)
                return id
            }
        }

        let started = try await client.request("thread/start", .object(shared))
        guard let id = started["thread"]?["id"]?.nonEmptyString else {
            throw ProviderError.invalidOutput("Codex did not report a thread id.")
        }
        readThreadMetadata(started)
        return id
    }

    private func readThreadMetadata(_ response: JSONValue) {
        if let model = response["model"]?.nonEmptyString {
            defaultModel = model
        }
        if let effort = response["reasoningEffort"]?.nonEmptyString {
            defaultEffort = effort
        }
        let existingTurns = (response["thread"]?["turns"]?.arrayValue ?? []).compactMap { $0["id"]?.nonEmptyString }
        if !existingTurns.isEmpty {
            completedTurnIDs = existingTurns
        }
    }

    private func loadSkills(_ client: AcpClient, cwd: String) async {
        guard let response = try? await withProviderTimeout(10, label: "Codex skills list", {
            try await client.request("skills/list", ["cwds": [.string(cwd)]])
        }) else { return }
        let parsed = CodexProtocol.skills(from: response)
        skillPaths = parsed.paths
        if !parsed.commands.isEmpty {
            continuation.yield(.commands(parsed.commands))
        }
    }

    private func requireOpen() throws {
        if isClosing || hasEnded { throw ProviderError.message("The Codex session was closed.") }
    }

    public func close() async {
        guard !isClosing else { return }
        isClosing = true
        if let client, let threadID, let activeTurnID {
            _ = try? await client.request("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(activeTurnID)])
        }
        await client?.close()
        finish(error: nil)
    }

    // MARK: - Turns

    public func startTurn(_ input: TurnInput) async throws -> String? {
        guard let client, let threadID, let config, !hasEnded else { throw ProviderError.notStarted }
        guard activeTurnID == nil, !isCompacting else {
            throw ProviderError.message("Codex is still working on the previous turn.")
        }
        runtimeMode = input.runtimeMode
        mapper.resetTurn()
        let params = CodexProtocol.turnStartParams(
            threadID: threadID,
            input: input,
            cwd: config.cwd,
            defaultModel: defaultModel,
            defaultEffort: defaultEffort,
            previousModeWasPlan: previousModeWasPlan,
            skillPaths: skillPaths
        )
        let response = try await withProviderTimeout(Self.requestTimeout, label: "Codex turn start") {
            try await client.request("turn/start", params)
        }
        try requireOpen()
        previousModeWasPlan = input.interactionMode == .plan
        let turnID = response["turn"]?["id"]?.nonEmptyString
        activeTurnID = turnID ?? UUID().uuidString
        return turnID
    }

    public func steer(_ input: TurnInput) async throws {
        guard let client, let threadID, let turnID = activeTurnID, !isCompacting, !hasEnded else {
            throw ProviderError.noActiveTurn
        }
        let params: JSONValue = [
            "threadId": .string(threadID),
            "expectedTurnId": .string(turnID),
            "input": .array(CodexProtocol.userInput(input, skillPaths: skillPaths)),
        ]
        do {
            _ = try await withProviderTimeout(Self.requestTimeout, label: "Codex steer") {
                try await client.request("turn/steer", params)
            }
        } catch ProviderError.rpc {
            throw ProviderError.noActiveTurn
        }
    }

    public func interrupt() async {
        guard let client, let threadID, let turnID = activeTurnID, !hasEnded else { return }
        cancelPending(client: client)
        _ = try? await withProviderTimeout(5, label: "Codex interrupt") {
            try await client.request("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turnID)])
        }
        Task { [weak self] in
            try? await Task.sleep(for: self?.interruptGrace ?? .seconds(5))
            await self?.forceEndIfStillActive(turnID: turnID)
        }
    }

    private func forceEndIfStillActive(turnID: String) async {
        guard !hasEnded, activeTurnID == turnID else { return }
        activeTurnID = nil
        isCompacting = false
        continuation.yield(.turnCompleted(outcome: .interrupted, error: nil))
    }

    // MARK: - Approvals and questions

    public func respond(toApproval id: String, decision: ApprovalDecision) async {
        guard let client, let request = pending.removeValue(forKey: id) else { return }
        try? await client.respond(to: request.rpcID, result: CodexProtocol.approvalResponse(decision))
        if decision == .cancel {
            await interrupt()
        }
    }

    public func answer(userInput id: String, answers: [String: [String]]) async {
        guard let client, let request = pending.removeValue(forKey: id) else { return }
        try? await client.respond(to: request.rpcID, result: CodexProtocol.userInputResponse(answers))
    }

    // MARK: - Compaction and rollback

    public func compact() async throws {
        guard let client, let threadID, !hasEnded else { throw ProviderError.notStarted }
        guard activeTurnID == nil, !isCompacting else {
            throw ProviderError.message("Codex is still working; compact the conversation once the turn has ended.")
        }
        mapper.resetTurn()
        isCompacting = true
        do {
            _ = try await withProviderTimeout(Self.requestTimeout, label: "Codex compaction") {
                try await client.request("thread/compact/start", ["threadId": .string(threadID)])
            }
        } catch {
            isCompacting = false
            throw error
        }
    }

    public func rollback(beforeTurn ordinal: Int, providerTurnID: String?) async throws {
        guard let client, let threadID, !hasEnded else { throw ProviderError.notStarted }
        guard activeTurnID == nil, !isCompacting else {
            throw ProviderError.message("Interrupt the running turn before editing earlier messages.")
        }
        let numTurns: Int
        if let providerTurnID, let index = completedTurnIDs.firstIndex(of: providerTurnID) {
            numTurns = completedTurnIDs.count - index
        } else if ordinal >= 1, ordinal <= completedTurnIDs.count {
            numTurns = completedTurnIDs.count - ordinal + 1
        } else {
            throw ProviderError.message("Could not locate turn \(ordinal) in the Codex thread.")
        }
        guard numTurns >= 1 else { return }
        let response = try await withProviderTimeout(Self.requestTimeout, label: "Codex rollback") {
            try await client.request("thread/rollback", ["threadId": .string(threadID), "numTurns": .number(Double(numTurns))])
        }
        let remaining = (response["thread"]?["turns"]?.arrayValue ?? []).compactMap { $0["id"]?.nonEmptyString }
        if !remaining.isEmpty || numTurns == completedTurnIDs.count {
            completedTurnIDs = remaining
        } else {
            completedTurnIDs.removeLast(min(numTurns, completedTurnIDs.count))
        }
    }

    // MARK: - Unsupported optional operations

    public func steerSubagent(_ id: String, text: String) async throws {
        throw ProviderError.message("Codex does not support steering subagents from Soprano Agents yet.")
    }

    public func cancelSubagent(_ id: String) async throws {
        throw ProviderError.message("Codex does not support stopping subagents individually yet.")
    }

    public func askSideQuestion(_ question: String, topicID: String?) async throws -> SideQuestion {
        throw ProviderError.message("Side questions are not supported for Codex yet.")
    }

    public func cancelSideQuestion() async -> Bool { false }

    public func sideQuestions() async throws -> [SideQuestion] { [] }

    // MARK: - Stream consumption

    private func consume(_ stream: AsyncStream<AcpClient.Incoming>) async {
        for await message in stream {
            guard !hasEnded else { return }
            switch message {
            case let .notification(method, params):
                handleNotification(method: method, params: params)
            case let .request(rpcID, method, params):
                await handleServerRequest(rpcID: rpcID, method: method, params: params)
            case .response:
                break
            case let .closed(status, stderr):
                let error = isClosing ? nil : ProviderError.processExited(.codex, status: status, stderr: stderr).localizedDescription
                finish(error: error)
                return
            }
        }
        finish(error: nil)
    }

    private func handleNotification(method: String, params: JSONValue) {
        // Ignore events for other threads (e.g. background/child notifications without our threadId).
        if let notificationThread = params["threadId"]?.nonEmptyString,
           let threadID, notificationThread != threadID {
            return
        }
        if method == "turn/started", let turnID = params["turn"]?["id"]?.nonEmptyString {
            activeTurnID = turnID
        }
        if method == "serverRequest/resolved", let rawID = params["requestId"] {
            pending.removeValue(forKey: CodexProtocol.requestIDString(rawID))
        }
        let mapped = mapper.notification(method: method, params: params)
        if method == "turn/completed" {
            let turnID = params["turn"]?["id"]?.nonEmptyString ?? activeTurnID
            if let turnID, !isCompacting, !completedTurnIDs.contains(turnID) {
                completedTurnIDs.append(turnID)
            }
            activeTurnID = nil
            isCompacting = false
            withdrawPending()
        }
        for event in mapped {
            continuation.yield(event)
        }
    }

    private func handleServerRequest(rpcID: JSONValue, method: String, params: JSONValue) async {
        guard let client else { return }
        let id = CodexProtocol.requestIDString(rpcID)
        switch method {
        case "item/commandExecution/requestApproval":
            if runtimeMode == .fullAccess {
                try? await client.respond(to: rpcID, result: CodexProtocol.approvalResponse(.accept))
                return
            }
            pending[id] = PendingRequest(rpcID: rpcID, method: method)
            for event in mapper.serverRequest(id: id, method: method, params: params) {
                continuation.yield(event)
            }

        case "item/fileChange/requestApproval":
            if runtimeMode == .fullAccess || runtimeMode == .autoAcceptEdits {
                try? await client.respond(to: rpcID, result: CodexProtocol.approvalResponse(.accept))
                return
            }
            pending[id] = PendingRequest(rpcID: rpcID, method: method)
            for event in mapper.serverRequest(id: id, method: method, params: params) {
                continuation.yield(event)
            }

        case "item/tool/requestUserInput":
            let events = mapper.serverRequest(id: id, method: method, params: params)
            if events.isEmpty {
                try? await client.respond(to: rpcID, result: CodexProtocol.userInputResponse([:]))
                return
            }
            pending[id] = PendingRequest(rpcID: rpcID, method: method)
            for event in events {
                continuation.yield(event)
            }

        default:
            try? await client.respond(to: rpcID, errorCode: -32601, message: "Unsupported client method \(method).")
        }
    }

    private func cancelPending(client: AcpClient) {
        let open = pending
        pending.removeAll()
        for (id, request) in open {
            if request.method == "item/tool/requestUserInput" {
                Task { try? await client.respond(to: request.rpcID, result: CodexProtocol.userInputResponse([:])) }
            } else {
                Task { try? await client.respond(to: request.rpcID, result: CodexProtocol.approvalResponse(.cancel)) }
            }
            continuation.yield(.requestResolved(id: id))
        }
    }

    private func withdrawPending() {
        let ids = Array(pending.keys)
        pending.removeAll()
        for id in ids {
            continuation.yield(.requestResolved(id: id))
        }
    }

    private func finish(error: String?) {
        guard !hasEnded else { return }
        hasEnded = true
        activeTurnID = nil
        isCompacting = false
        pending.removeAll()
        continuation.yield(.sessionEnded(error: error))
        continuation.finish()
    }
}
