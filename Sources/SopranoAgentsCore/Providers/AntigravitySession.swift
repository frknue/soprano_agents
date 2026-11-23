import Foundation

/// One Antigravity conversation: `agy acp` (one process per thread) driven over ACP
/// (`AcpClient`), with agy's own agent, system prompt and tools.
///
/// Start: `initialize`, then `session/load {sessionId, cwd}` for `resumeID` (its history replay
/// is ignored; a session agy no longer has starts fresh) or `session/new {cwd, mcpServers: []}`
/// (with `_meta.antigravity.systemPrompt.append` = `SessionConfig.systemPromptFile`'s text when
/// agy offers it). The ACP session id is the conversation id. The thread's selection is applied
/// before every turn with `session/set_config_option`: `model` ("default" = the model agy chose
/// for the new session), `thought_level` (the reasoning effort, when the model offers it) and
/// `mode` (`AntigravityProtocol.modeID`).
///
/// Turns: `session/prompt` (text with attachment paths, image blocks); its answer ends the turn
/// (`stopReason` `cancelled` → interrupted, `refusal` → failed, else completed; an error → failed).
/// Updates go through `AntigravityEventMapper`. ACP has no steering here: `steer` refuses with
/// `noActiveTurn`, so the engine queues follow-ups. Stop sends `session/cancel` (and cancels open
/// permission requests); when agy has not ended the turn after `interruptGrace` (5 s), the turn
/// ends here as interrupted and this agy is terminated (`sessionEnded`): a prompt agy never
/// answered must not be taken for the next turn's, and its late updates must not reach it. The
/// engine resumes the conversation in a new process with the next message.
///
/// Approvals: `session/request_permission` → `approvalRequested`, answered with the offered
/// option of the decision's kind (`AntigravityProtocol.permissionOutcome`; Cancel also stops the
/// turn). Full access answers them itself. The turn's end withdraws unanswered ones.
///
/// Compaction: agy's `/compact` command as a turn of its own; its usage report (the summary
/// call's tokens, not the context fill) is skipped. Rollback, subagents and side questions are
/// not offered: agy cannot rewind an ACP conversation.
public actor AntigravitySession: ProviderSession {
    public nonisolated let kind = ProviderKind.antigravity
    public nonisolated let events: AsyncStream<ProviderEvent>

    static let startupTimeout: TimeInterval = 60
    static let requestTimeout: TimeInterval = 30
    private let interruptGrace: Duration
    private let backgroundSettleDelay: Duration

    private struct PendingPermission {
        var rpcID: JSONValue
        var options: [JSONValue]
    }

    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let executablePath: @Sendable () -> String?
    private let profile: String
    private var config: SessionConfig?
    private var client: AcpClient?
    private var sessionID: String?
    private var mapper = AntigravityEventMapper()
    /// agy's model for a new session: what "default" selects.
    private var defaultModel: String?
    private var currentModel: String?
    private var currentEffort: String?
    private var efforts: Set<String> = []
    private var currentMode: String?
    private var modes: Set<String> = []
    private var autoApproves = false
    private var isTurnActive = false
    private var isBackgroundWakeup = false
    private var backgroundSettleTask: Task<Void, Never>?
    private var isCompacting = false
    private var turnNumber = 0
    /// Turns whose `session/prompt` awaits its answer, in send order.
    private var promptTurns: [Int] = []
    private var pending: [String: PendingPermission] = [:]
    private var permissionCounter = 0
    /// `session/load` replays the conversation as updates: none of them is news.
    private var isLoading = false
    private var isClosing = false
    private var hasEnded = false

    /// `executablePath` returns the settings override (`providers.antigravityPath`), read at
    /// start; `profile` is the app's Antigravity profile (`AntigravityProtocol.profileDirectory`).
    public init(
        executablePath: @escaping @Sendable () -> String? = { nil },
        profile: String,
        interruptGrace: Duration = .seconds(5),
        backgroundSettleDelay: Duration = .seconds(3)
    ) {
        self.executablePath = executablePath
        self.profile = profile
        self.interruptGrace = interruptGrace
        self.backgroundSettleDelay = backgroundSettleDelay
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .unbounded)
    }

    // MARK: - Lifecycle

    public func start(_ config: SessionConfig) async throws -> String {
        guard self.config == nil, !hasEnded else { throw ProviderError.message("The Antigravity session was already started.") }
        try ProviderError.requireWorkspace(config.cwd)
        let explicit = executablePath()
        guard let executable = AntigravityProtocol.locateExecutable(explicitPath: explicit) else {
            throw ProviderError.notInstalled(.antigravity, path: explicit)
        }
        guard AntigravityProtocol.isSignedIn(profile: profile) else {
            throw ProviderError.message("Antigravity is not signed in. Sign in with your Google account in Settings › Providers › Antigravity.")
        }
        self.config = config
        mapper = AntigravityEventMapper(cwd: config.cwd)
        let process = LineProcess(LineProcess.Configuration(
            executable: executable,
            arguments: AntigravityProtocol.arguments(profile: profile),
            environment: AntigravityProtocol.environment(profile: profile),
            directory: config.cwd
        ))
        do {
            try process.start()
        } catch {
            throw ProviderError.spawnFailed(error.localizedDescription)
        }
        let client = AcpClient(transport: process)
        self.client = client
        Task { await self.consume(client.incoming) }
        do {
            let id = try await withProviderTimeout(Self.startupTimeout, label: "Antigravity startup") {
                let initialized = try await client.request("initialize", AntigravityProtocol.initializeParams)
                return try await self.open(client, config: config, initialized: initialized)
            }
            try requireOpen()
            sessionID = id
            try await apply(config.modelSelection, mode: config.runtimeMode)
            continuation.yield(.conversationID(id))
            return id
        } catch {
            isClosing = true
            await client.close()
            finish(error: nil)
            throw error
        }
    }

    /// Loads `resumeID` or creates a session; reads its config options.
    private func open(_ client: AcpClient, config: SessionConfig, initialized: JSONValue) async throws -> String {
        let mcpServers = AntigravityProtocol.mcpServers(config.mcpServers)
        if let resume = config.resumeID {
            isLoading = true
            defer { isLoading = false }
            let params: JSONValue = ["sessionId": .string(resume), "cwd": .string(config.cwd), "mcpServers": mcpServers]
            if let loaded = try? await client.request("session/load", params) {
                read(loaded["configOptions"], isNew: false)
                return resume
            }
        }
        var params: [String: JSONValue] = ["cwd": .string(config.cwd), "mcpServers": mcpServers]
        if let file = config.systemPromptFile,
           initialized["agentCapabilities"]?["_meta"]?["antigravity"]?["systemPrompt"]?["append"]?.boolValue == true,
           let text = try? String(contentsOfFile: file, encoding: .utf8), !text.isEmpty
        {
            params["_meta"] = ["antigravity": ["systemPrompt": ["append": .string(text)]]]
        }
        let created = try await client.request("session/new", .object(params))
        guard let id = created["sessionId"]?.nonEmptyString else {
            throw ProviderError.invalidOutput("Antigravity did not report the new session.")
        }
        read(created["configOptions"], isNew: true)
        return id
    }

    /// The session's current model, reasoning effort and mode, and what it offers.
    private func read(_ options: JSONValue?, isNew: Bool) {
        if let model = AntigravityProtocol.configOption(options, id: "model") {
            currentModel = model["currentValue"]?.stringValue
            if isNew || defaultModel == nil { defaultModel = defaultModel ?? currentModel }
        }
        let level = AntigravityProtocol.configOption(options, id: "thought_level")
        currentEffort = level?["currentValue"]?.stringValue
        efforts = Set(AntigravityProtocol.choices(level).map(\.value))
        if let mode = AntigravityProtocol.configOption(options, id: "mode") {
            currentMode = mode["currentValue"]?.stringValue
            modes = Set(AntigravityProtocol.choices(mode).map(\.value))
        }
    }

    private func requireOpen() throws {
        if isClosing || hasEnded { throw ProviderError.message("The Antigravity session was closed.") }
    }

    public func close() async {
        guard !isClosing else { return }
        isClosing = true
        if isTurnActive, let client, let sessionID {
            try? await client.notify("session/cancel", ["sessionId": .string(sessionID)])
        }
        await client?.close()
        finish(error: nil)
    }

    // MARK: - Selection

    private func apply(_ selection: ModelSelection, mode runtime: RuntimeMode) async throws {
        autoApproves = runtime == .fullAccess
        if let model = AntigravityProtocol.modelValue(selection) ?? defaultModel, model != currentModel {
            try await setOption("model", model)
        }
        if let effort = selection.effort, efforts.contains(effort), effort != currentEffort {
            try await setOption("thought_level", effort)
        }
        let mode = AntigravityProtocol.modeID(runtime)
        if modes.contains(mode), mode != currentMode {
            try await setOption("mode", mode)
        }
    }

    private func setOption(_ id: String, _ value: String) async throws {
        guard let client, let session = sessionID else { throw ProviderError.notStarted }
        let answer = try await withProviderTimeout(Self.requestTimeout, label: "Antigravity \(id) change") {
            try await client.request("session/set_config_option", ["sessionId": .string(session), "configId": .string(id), "value": .string(value)])
        }
        read(answer["configOptions"], isNew: false)
    }

    // MARK: - Turns

    public func startTurn(_ input: TurnInput) async throws -> String? {
        guard client != nil, sessionID != nil, !hasEnded else { throw ProviderError.notStarted }
        if isBackgroundWakeup {
            endTurn(.completed, error: nil)
        }
        guard !isTurnActive else { throw ProviderError.message("Antigravity is still working on the previous turn.") }
        try await apply(input.modelSelection, mode: input.runtimeMode)
        try requireOpen()
        return begin(prompt: AntigravityProtocol.prompt(input), compaction: false)
    }

    /// ACP turns take no messages while they run: the engine queues the follow-up.
    public func steer(_ input: TurnInput) async throws {
        throw ProviderError.noActiveTurn
    }

    public func compact() async throws {
        guard client != nil, sessionID != nil, !hasEnded else { throw ProviderError.notStarted }
        if isBackgroundWakeup {
            endTurn(.completed, error: nil)
        }
        guard !isTurnActive else {
            throw ProviderError.message("Antigravity is still working; compact the conversation once the turn has ended.")
        }
        _ = begin(prompt: [["type": "text", "text": "/compact"]], compaction: true)
    }

    /// Sends `session/prompt` and returns the turn's native id (rollback refuses every one).
    private func begin(prompt: JSONValue, compaction: Bool) -> String {
        turnNumber += 1
        let turn = turnNumber
        mapper.resetTurn(turn)
        isTurnActive = true
        isCompacting = compaction
        promptTurns.append(turn)
        if let client, let sessionID {
            Task { await self.runPrompt(client, session: sessionID, prompt: prompt, turn: turn) }
        }
        return "antigravity-turn-\(turn)"
    }

    /// The answer reaches `consume` behind the turn's updates (an `ordered` request); only a
    /// prompt that never got out ends here.
    private func runPrompt(_ client: AcpClient, session: String, prompt: JSONValue, turn: Int) async {
        do {
            _ = try await client.request("session/prompt", ["sessionId": .string(session), "prompt": prompt], ordered: true)
        } catch ProviderError.rpc {
            // Reported on `incoming` as well.
        } catch {
            guard !hasEnded else { return }
            promptTurns.removeAll { $0 == turn }
            guard isTurnActive, turnNumber == turn else { return }
            endTurn(.failed, error: error.localizedDescription)
        }
    }

    /// A `session/prompt` answer, read in order with the updates before it: it ends the turn it
    /// answers (prompts are answered in the order they were sent), unless that turn already
    /// ended here (an expired Stop).
    private func promptAnswered(result: JSONValue?, error: String?) {
        guard !promptTurns.isEmpty else { return }
        let turn = promptTurns.removeFirst()
        guard isTurnActive, turnNumber == turn else { return }
        if let error {
            endTurn(.failed, error: error)
        } else {
            let outcome = AntigravityProtocol.outcome(stopReason: result?["stopReason"]?.stringValue)
            endTurn(outcome.0, error: outcome.1)
        }
    }

    private func endTurn(_ outcome: ProviderTurnOutcome, error: String?) {
        let compaction = isCompacting
        backgroundSettleTask?.cancel()
        backgroundSettleTask = nil
        isTurnActive = false
        isBackgroundWakeup = false
        isCompacting = false
        for id in pending.keys.sorted() { continuation.yield(.requestResolved(id: id)) }
        pending.removeAll()
        for event in mapper.finishTurn() { continuation.yield(event) }
        if compaction, outcome == .completed {
            continuation.yield(.itemUpdated(TurnItem(id: "t\(turnNumber)/compacted", kind: .notice(text: "Context compacted"), status: .completed, completedAt: Date())))
        }
        continuation.yield(.turnCompleted(outcome: outcome, error: error))
    }

    private func scheduleBackgroundSettle(turn: Int) {
        backgroundSettleTask?.cancel()
        guard pending.isEmpty else { return }
        let delay = backgroundSettleDelay
        backgroundSettleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.settleBackgroundWakeup(turn: turn)
        }
    }

    private func settleBackgroundWakeup(turn: Int) {
        guard !hasEnded, isTurnActive, isBackgroundWakeup, turnNumber == turn, pending.isEmpty else { return }
        endTurn(.completed, error: nil)
    }

    public func interrupt() async {
        guard isTurnActive, let client, let sessionID else { return }
        let turn = turnNumber
        cancelPermissions()
        try? await client.notify("session/cancel", ["sessionId": .string(sessionID)])
        Task {
            try? await Task.sleep(for: self.interruptGrace)
            await self.expireInterrupt(turn)
        }
    }

    /// agy did not end the stopped turn in time: end it here and retire this agy.
    private func expireInterrupt(_ turn: Int) async {
        guard isTurnActive, turnNumber == turn else { return }
        endTurn(.interrupted, error: nil)
        isClosing = true
        await client?.close()
        finish(error: nil)
    }

    /// Answers every open permission request `cancelled`.
    private func cancelPermissions() {
        guard let client else { return }
        for (id, request) in pending.sorted(by: { $0.key < $1.key }) {
            Task { try? await client.respond(to: request.rpcID, result: AntigravityProtocol.permissionOutcome(.cancel, options: request.options)) }
            continuation.yield(.requestResolved(id: id))
        }
        pending.removeAll()
    }

    public func respond(toApproval id: String, decision: ApprovalDecision) async {
        guard let request = pending.removeValue(forKey: id), let client else { return }
        try? await client.respond(to: request.rpcID, result: AntigravityProtocol.permissionOutcome(decision, options: request.options))
        if decision == .cancel {
            await interrupt()
        } else if isBackgroundWakeup, pending.isEmpty {
            scheduleBackgroundSettle(turn: turnNumber)
        }
    }

    /// agy asks no structured questions over ACP.
    public func answer(userInput id: String, answers: [String: [String]]) async {}

    public func rollback(beforeTurn ordinal: Int, providerTurnID: String?) async throws {
        throw ProviderError.message("Antigravity can't rewind its conversation. Continue with a follow-up message or start a new thread.")
    }

    public func steerSubagent(_ id: String, text: String) async throws {
        throw ProviderError.message("Antigravity reports no subagents.")
    }

    public func cancelSubagent(_ id: String) async throws {}

    public func askSideQuestion(_ question: String, topicID: String?) async throws -> SideQuestion {
        throw ProviderError.message("Antigravity has no side questions.")
    }

    public func cancelSideQuestion() async -> Bool { false }

    public func sideQuestions() async throws -> [SideQuestion] { [] }

    // MARK: - Incoming

    private func consume(_ incoming: AsyncStream<AcpClient.Incoming>) async {
        for await message in incoming {
            switch message {
            case let .notification(method, params):
                guard method == "session/update", !isLoading else { continue }
                if let id = params["sessionId"]?.stringValue, let sessionID, id != sessionID { continue }
                let update = params["update"] ?? .null
                let kind = update["sessionUpdate"]?.stringValue ?? ""
                if isCompacting, kind == "usage_update" { continue }
                if !isTurnActive {
                    if ["available_commands_update", "usage_update"].contains(kind) {
                        for event in mapper.update(update) { continuation.yield(event) }
                        continue
                    }
                    // Spontaneous background wakeup (e.g. a background command or subagent finished
                    // after `session/prompt` returned): reopen the turn so updates reach the UI.
                    let wakeupKinds = ["agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update", "plan"]
                    guard wakeupKinds.contains(kind) else { continue }
                    turnNumber += 1
                    mapper.resetTurn(turnNumber)
                    isTurnActive = true
                    isBackgroundWakeup = true
                    continuation.yield(.turnResumed)
                }
                for event in mapper.update(update) { continuation.yield(event) }
                if isBackgroundWakeup {
                    scheduleBackgroundSettle(turn: turnNumber)
                }
            case let .request(id, method, params):
                if isBackgroundWakeup { backgroundSettleTask?.cancel() }
                await handleRequest(id: id, method: method, params: params)
            case let .response(method, result, error):
                if method == "session/prompt" { promptAnswered(result: result, error: error) }
            case let .closed(status, stderr):
                let error = isClosing ? nil : ProviderError.processExited(.antigravity, status: status, stderr: stderr).localizedDescription
                finish(error: error)
            }
        }
    }

    private func handleRequest(id: JSONValue, method: String, params: JSONValue) async {
        guard let client else { return }
        guard method == "session/request_permission" else {
            try? await client.respond(to: id, errorCode: -32601, message: "Soprano Agents does not offer \(method).")
            return
        }
        let options = params["options"]?.arrayValue ?? []
        guard isTurnActive, !autoApproves else {
            let decision: ApprovalDecision = isTurnActive ? .accept : .cancel
            try? await client.respond(to: id, result: AntigravityProtocol.permissionOutcome(decision, options: options))
            return
        }
        permissionCounter += 1
        let approvalID = "antigravity-approval-\(permissionCounter)"
        pending[approvalID] = PendingPermission(rpcID: id, options: options)
        for event in mapper.permission(id: approvalID, params: params) { continuation.yield(event) }
    }

    private func finish(error: String?) {
        guard !hasEnded else { return }
        hasEnded = true
        isTurnActive = false
        pending.removeAll()
        continuation.yield(.sessionEnded(error: error))
        continuation.finish()
    }
}
