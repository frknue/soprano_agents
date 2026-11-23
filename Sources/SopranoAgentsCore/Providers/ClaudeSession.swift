import Foundation

/// One Claude Code conversation: `claude --print --output-format stream-json --input-format
/// stream-json --permission-prompt-tool stdio`, driven over `LineProcess`.
///
/// Start: launches Claude Code in `config.cwd` (with optional `--resume`, `--model`, `--effort`,
/// `--append-system-prompt-file`, `--mcp-config`), sends the `initialize` control request, and
/// publishes its slash commands/skills.
///
/// Turns: updates model (`set_model`) and permission/Plan mode (`set_permission_mode`) in place
/// via `control_request` when changed, then writes a `user` frame on stdin. Steering sends an
/// additional `user` frame into the live stream; Stop sends the `interrupt` control request with
/// a 5 s grace. Approvals and `AskUserQuestion` arrive as `control_request` (`can_use_tool`) and
/// are answered with `control_response`.
public actor ClaudeSession: ProviderSession {
    public nonisolated let kind = ProviderKind.claude
    public nonisolated let events: AsyncStream<ProviderEvent>

    static let startupTimeout: TimeInterval = 45
    static let controlTimeout: TimeInterval = 30
    private let interruptGrace: Duration

    private struct PendingControl {
        var originalInput: JSONValue
        var suggestions: JSONValue?
        var toolUseID: String?
        var questionTextByID: [String: String]
        var isQuestion: Bool
    }

    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let executablePath: @Sendable () -> String?
    private let launchAdjustments: @Sendable () -> ProviderLaunchAdjustments
    private var config: SessionConfig?
    private var process: LineProcess?
    private var tempMCPFile: URL?
    private var sessionID: String?
    private var mapper = ClaudeEventMapper()
    private var currentModel: String?
    private var currentPermissionMode: String?
    private var isTurnActive = false
    private var turnNumber = 0
    private var controlCounter = 0
    private var waitingControls: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var pendingRequests: [String: PendingControl] = [:]
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
            throw ProviderError.message("The Claude Code session was already started.")
        }
        try ProviderError.requireWorkspace(config.cwd)
        let explicit = executablePath()
        guard let executable = ClaudeProtocol.locateExecutable(explicitPath: explicit) else {
            throw ProviderError.notInstalled(.claude, path: explicit)
        }
        self.config = config
        self.mapper = ClaudeEventMapper(cwd: config.cwd)
        self.currentModel = ClaudeProtocol.modelValue(config.modelSelection)
        self.currentPermissionMode = ClaudeProtocol.permissionMode(for: config.runtimeMode, interactionMode: .standard)

        let mcpPath = try writeTempMCPConfig(config.mcpServers)
        let adjustments = launchAdjustments()
        let process = LineProcess(LineProcess.Configuration(
            executable: executable,
            arguments: ClaudeProtocol.sessionArguments(config: config, mcpConfigPath: mcpPath, adjustments: adjustments),
            environment: ClaudeProtocol.environment(adjustments: adjustments),
            directory: config.cwd
        ))
        do {
            try process.start()
        } catch {
            cleanupTempMCPFile()
            throw ProviderError.spawnFailed(error.localizedDescription)
        }
        self.process = process
        Task { await self.readLoop(process) }

        do {
            let initResponse = try await withProviderTimeout(Self.startupTimeout, label: "Claude Code startup") {
                try await self.sendControlRequest(["subtype": "initialize"])
            }
            try requireOpen()
            let commands = ClaudeProtocol.commands(from: initResponse["commands"])
            if !commands.isEmpty {
                continuation.yield(.commands(commands))
            }
            let id = sessionID ?? config.resumeID ?? UUID().uuidString
            sessionID = id
            continuation.yield(.conversationID(id))
            return id
        } catch {
            isClosing = true
            process.close()
            finish(error: nil)
            throw error
        }
    }

    private func writeTempMCPConfig(_ servers: [MCPServerSpec]) throws -> String? {
        guard !servers.isEmpty else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("soprano-claude-mcp-\(UUID().uuidString).json")
        let json = ClaudeProtocol.mcpConfigJSON(servers).jsonString()
        try json.write(to: file, atomically: true, encoding: .utf8)
        tempMCPFile = file
        return file.path
    }

    private func cleanupTempMCPFile() {
        if let tempMCPFile {
            try? FileManager.default.removeItem(at: tempMCPFile)
            self.tempMCPFile = nil
        }
    }

    private func requireOpen() throws {
        if isClosing || hasEnded { throw ProviderError.message("The Claude Code session was closed.") }
    }

    public func close() async {
        guard !isClosing else { return }
        isClosing = true
        if isTurnActive {
            _ = try? await sendControlRequest(["subtype": "interrupt"])
        }
        process?.close()
        finish(error: nil)
    }

    // MARK: - Turns

    public func startTurn(_ input: TurnInput) async throws -> String? {
        guard process != nil, !hasEnded else { throw ProviderError.notStarted }
        guard !isTurnActive else {
            throw ProviderError.message("Claude Code is still working on the previous turn.")
        }
        try await apply(input.modelSelection, runtimeMode: input.runtimeMode, interactionMode: input.interactionMode)
        try requireOpen()
        mapper.resetTurn()
        turnNumber += 1
        let turnID = "claude-turn-\(turnNumber)"
        isTurnActive = true
        try sendFrame(ClaudeProtocol.userMessageFrame(input))
        continuation.yield(.turnStarted(providerTurnID: turnID))
        return turnID
    }

    public func steer(_ input: TurnInput) async throws {
        guard process != nil, isTurnActive, !hasEnded else { throw ProviderError.noActiveTurn }
        try sendFrame(ClaudeProtocol.userMessageFrame(input))
    }

    public func interrupt() async {
        guard process != nil, isTurnActive, !hasEnded else { return }
        let currentTurn = turnNumber
        cancelPending()
        _ = try? await withProviderTimeout(5, label: "Claude Code interrupt") {
            try await self.sendControlRequest(["subtype": "interrupt"])
        }
        Task { [weak self] in
            try? await Task.sleep(for: self?.interruptGrace ?? .seconds(5))
            await self?.forceEndIfStillActive(turn: currentTurn)
        }
    }

    private func forceEndIfStillActive(turn: Int) {
        guard !hasEnded, isTurnActive, turnNumber == turn else { return }
        isTurnActive = false
        continuation.yield(.turnCompleted(outcome: .interrupted, error: nil))
    }

    private func apply(_ selection: ModelSelection, runtimeMode: RuntimeMode, interactionMode: InteractionMode) async throws {
        let wantedModel = ClaudeProtocol.modelValue(selection)
        if let wantedModel, wantedModel != currentModel {
            _ = try await withProviderTimeout(Self.controlTimeout, label: "Claude Code model change") {
                try await self.sendControlRequest(["subtype": "set_model", "model": .string(wantedModel)])
            }
            currentModel = wantedModel
        }
        let wantedMode = ClaudeProtocol.permissionMode(for: runtimeMode, interactionMode: interactionMode)
        if wantedMode != currentPermissionMode {
            _ = try await withProviderTimeout(Self.controlTimeout, label: "Claude Code mode change") {
                try await self.sendControlRequest(["subtype": "set_permission_mode", "mode": .string(wantedMode)])
            }
            currentPermissionMode = wantedMode
        }
    }

    // MARK: - Approvals and questions

    public func respond(toApproval id: String, decision: ApprovalDecision) async {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        if decision == .decline || decision == .cancel, let toolUseID = pending.toolUseID {
            mapper.markDeclined(toolUseID: toolUseID)
        }
        let response = ClaudeProtocol.permissionResponse(
            decision: decision,
            originalInput: pending.originalInput,
            suggestions: pending.suggestions
        )
        try? sendFrame(ClaudeProtocol.controlSuccess(requestID: id, response: response))
        if decision == .cancel {
            await interrupt()
        }
    }

    public func answer(userInput id: String, answers: [String: [String]]) async {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        let response = ClaudeProtocol.askUserQuestionResponse(
            answers: answers,
            questionTextByID: pending.questionTextByID,
            originalInput: pending.originalInput
        )
        try? sendFrame(ClaudeProtocol.controlSuccess(requestID: id, response: response))
    }

    // MARK: - Compaction and rollback

    public func compact() async throws {
        guard process != nil, !hasEnded else { throw ProviderError.notStarted }
        guard !isTurnActive else {
            throw ProviderError.message("Claude Code is still working; compact the conversation once the turn has ended.")
        }
        mapper.resetTurn()
        turnNumber += 1
        let turnID = "claude-compact-\(turnNumber)"
        isTurnActive = true
        try sendFrame(["type": "user", "message": ["role": "user", "content": "/compact"]])
        continuation.yield(.turnStarted(providerTurnID: turnID))
    }

    public func rollback(beforeTurn ordinal: Int, providerTurnID: String?) async throws {
        guard !hasEnded else { throw ProviderError.notStarted }
        guard !isTurnActive else {
            throw ProviderError.message("Interrupt the running turn before editing earlier messages.")
        }
        // Start a clean conversation on next turn when rolling back to the very first turn;
        // mid-conversation rollbacks require closing the current process (files are restored by git).
        if ordinal <= 1 {
            sessionID = nil
            isClosing = true
            process?.close()
            finish(error: nil)
            return
        }
        throw ProviderError.message("Claude Code cannot rewind mid-conversation yet; edit from the first message or start a new thread.")
    }

    // MARK: - Unsupported optional operations

    public func steerSubagent(_ id: String, text: String) async throws {
        throw ProviderError.message("Claude Code does not support steering subagents individually.")
    }

    public func cancelSubagent(_ id: String) async throws {
        throw ProviderError.message("Claude Code does not support stopping subagents individually.")
    }

    public func askSideQuestion(_ question: String, topicID: String?) async throws -> SideQuestion {
        throw ProviderError.message("Side questions are not supported for Claude Code yet.")
    }

    public func cancelSideQuestion() async -> Bool { false }

    public func sideQuestions() async throws -> [SideQuestion] { [] }

    // MARK: - Wire I/O

    private func sendFrame(_ frame: JSONValue) throws {
        guard let process, !hasEnded else { throw ProviderError.notStarted }
        try process.send(frame.jsonString())
    }

    private func sendControlRequest(_ request: JSONValue) async throws -> JSONValue {
        controlCounter += 1
        let id = "sa-ctrl-\(controlCounter)"
        let frame = ClaudeProtocol.controlRequest(id: id, request: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !hasEnded, let process else {
                    continuation.resume(throwing: ProviderError.notStarted)
                    return
                }
                waitingControls[id] = continuation
                do {
                    try process.send(frame.jsonString())
                } catch {
                    waitingControls[id] = nil
                    continuation.resume(throwing: ProviderError.notStarted)
                }
            }
        } onCancel: {
            Task { await self.abandonControl(id) }
        }
    }

    private func abandonControl(_ id: String) {
        waitingControls.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func readLoop(_ process: LineProcess) async {
        for await event in process.incoming {
            guard !hasEnded else { return }
            switch event {
            case let .line(line):
                guard let frame = try? JSONValue.parse(line), frame.objectValue != nil else { continue }
                handle(frame)
            case let .exited(status, stderr):
                let error = isClosing ? nil : ProviderError.processExited(.claude, status: status, stderr: stderr).localizedDescription
                finish(error: error)
                return
            }
        }
        finish(error: nil)
    }

    private func handle(_ frame: JSONValue) {
        if let reportedID = frame["session_id"]?.nonEmptyString, sessionID != reportedID {
            sessionID = reportedID
            continuation.yield(.conversationID(reportedID))
        }

        switch frame["type"]?.stringValue {
        case "control_response":
            handleControlResponse(frame)
            return
        case "control_request":
            handleIncomingControlRequest(frame)
            return
        default:
            break
        }

        let mapped = mapper.map(frame)
        if frame["type"]?.stringValue == "result" {
            isTurnActive = false
            withdrawPending()
        }
        for event in mapped {
            continuation.yield(event)
        }
    }

    private func handleControlResponse(_ frame: JSONValue) {
        guard let response = frame["response"],
              let requestID = response["request_id"]?.nonEmptyString,
              let continuation = waitingControls.removeValue(forKey: requestID) else { return }
        if response["subtype"]?.stringValue == "error" {
            let message = response["error"]?.nonEmptyString ?? "Claude Code rejected the control request."
            continuation.resume(throwing: ProviderError.rpc(method: "control_request", code: 0, message: message))
        } else {
            continuation.resume(returning: response["response"] ?? .null)
        }
    }

    private func handleIncomingControlRequest(_ frame: JSONValue) {
        guard let requestID = frame["request_id"]?.nonEmptyString,
              let request = frame["request"] else { return }
        guard request["subtype"]?.stringValue == "can_use_tool" else {
            try? sendFrame(ClaudeProtocol.controlSuccess(requestID: requestID, response: [:]))
            return
        }
        let originalInput = request["input"] ?? [:]
        let suggestions = request["permission_suggestions"]
        let toolUseID = request["tool_use_id"]?.nonEmptyString
        let (events, questionTextByID) = mapper.mapControlRequest(id: requestID, request: request)
        if events.isEmpty {
            try? sendFrame(ClaudeProtocol.controlSuccess(requestID: requestID, response: ClaudeProtocol.permissionResponse(decision: .accept, originalInput: originalInput, suggestions: nil)))
            return
        }
        pendingRequests[requestID] = PendingControl(
            originalInput: originalInput,
            suggestions: suggestions,
            toolUseID: toolUseID,
            questionTextByID: questionTextByID,
            isQuestion: !questionTextByID.isEmpty
        )
        for event in events {
            continuation.yield(event)
        }
    }

    private func cancelPending() {
        let open = pendingRequests
        pendingRequests.removeAll()
        for (id, item) in open {
            let payload: JSONValue = item.isQuestion
                ? ClaudeProtocol.askUserQuestionResponse(answers: [:], questionTextByID: item.questionTextByID, originalInput: item.originalInput)
                : ClaudeProtocol.permissionResponse(decision: .cancel, originalInput: item.originalInput, suggestions: nil)
            try? sendFrame(ClaudeProtocol.controlSuccess(requestID: id, response: payload))
            continuation.yield(.requestResolved(id: id))
        }
    }

    private func withdrawPending() {
        let ids = Array(pendingRequests.keys)
        pendingRequests.removeAll()
        for id in ids {
            continuation.yield(.requestResolved(id: id))
        }
    }

    private func finish(error: String?) {
        guard !hasEnded else { return }
        hasEnded = true
        isTurnActive = false
        cleanupTempMCPFile()
        let pendingControls = waitingControls.values
        waitingControls.removeAll()
        for waiter in pendingControls {
            waiter.resume(throwing: ProviderError.message(error ?? "Claude Code session ended."))
        }
        pendingRequests.removeAll()
        continuation.yield(.sessionEnded(error: error))
        continuation.finish()
    }
}
