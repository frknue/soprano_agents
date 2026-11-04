import Foundation

/// One OpenCode session (`ses_…`) on OpenCode's background service, driven over its v2 HTTP API
/// with the server-sent event stream (`OpencodeServer`).
///
/// Start: open the event stream (wait for `server.connected`), read the model catalog (context
/// windows, the configured default model), then resume `resumeID` (`GET /api/session/{id}`; a
/// session that is gone starts fresh) or create one (`POST /api/session {location, permissions,
/// model?}`). The session id is the conversation id. The thread's selection is applied in place
/// before every turn: `POST /api/session/{id}/model {model:{id, providerID, variant}}` when the
/// model or variant changed ("default" = OpenCode's configured model), `PATCH
/// /api/session/{id} {permissions}` when the runtime mode changed
/// (`OpencodeProtocol.permissions`).
///
/// Turns: `POST …/prompt {text, files?, skills?}` or, for a listed slash command, `POST
/// …/command {name, text}` (`OpencodeProtocol.message`). The first `session.inbox.enqueued` of
/// the session after that carries the turn's user message id, reported as its native id
/// (`turnStarted`); rollback cuts there. Events of the session go through
/// `OpencodeEventMapper`; `session.execution.succeeded|failed|interrupted` ends the turn. Events
/// that arrive while no turn of this app runs (another client driving the same session) are
/// ignored. Steering is `prompt {delivery:"steer"}`, Stop `POST …/interrupt`. Running shell
/// tools stream their output from `GET /api/shell/{shellID}/output?cursor=` (polled twice a
/// second).
///
/// Approvals: `permission.asked` of the session or one of its subagents → `approvalRequested`,
/// answered with `POST /api/session/{owner}/permission/{id}/reply`
/// (`OpencodeProtocol.permissionReply`). Questions: `form.created` → `userInputRequested`,
/// answered with `POST …/form/{id}/reply {answer}` or dismissed with `DELETE …/form/{id}`.
/// `permission.replied`, `form.replied` and `form.cancelled` (answered elsewhere) withdraw them;
/// the turn's end withdraws the rest.
///
/// Subagents: sessions created with this session (or one of its subagents) as `parentID` are
/// subagents, named by their slug ("clever-planet"). Their events go through a mapper of their
/// own and become `subagent` events: `session.inbox.enqueued` opens a run (its assignment, a
/// steer, a message from the parent), `session.execution.*` ends it. The parent's
/// `session.tool.progress {metadata.sessionID}` links the subagent to the tool call that
/// started it. Messages go to `POST /api/session/{child}/prompt {delivery:"steer"}`, Stop to
/// `POST …/interrupt`.
///
/// Compaction: `POST …/compact` runs as a turn (`session.compaction.*`, then the execution's
/// end). Rollback: `POST …/revert/stage {messageID, files:false}` then `POST …/revert/commit`
/// (the engine restores files from its own checkpoints). Side questions: `POST
/// …/generate {prompt}` (answered from the conversation, never added to it); OpenCode keeps no
/// history of them, so the session keeps this run's topics. Commands: `GET /api/command` and
/// `GET /api/skill`, read again after a turn once OpenCode reported a change. Context: every
/// step's tokens against the model's `limit.context`.
///
/// `close()` stops a running turn (like quitting omp would) and closes the stream; the server
/// keeps the session. The stream's end is the session's end (`sessionEnded`).
public actor OpencodeSession: ProviderSession {
    public nonisolated let kind = ProviderKind.opencode
    public nonisolated let events: AsyncStream<ProviderEvent>

    static let connectTimeout: TimeInterval = 20
    static let shellPollInterval: UInt64 = 500_000_000
    static let generateTimeout: TimeInterval = 300

    private struct Subagent {
        var name: String
        var mapper: OpencodeEventMapper
        var isRunOpen = false
        var hasAssignment = false
        var lastIntent: String?
    }

    private struct PendingRequest {
        /// The session that asked (this one or a subagent's).
        var owner: String
        /// The form, for questions; nil for approvals.
        var form: JSONValue?
    }

    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let server: any OpencodeTransport
    private var config: SessionConfig?
    private var sessionID: String?
    /// The session's directory (shell output is read there).
    private var location = ""
    private var mapper = OpencodeEventMapper()
    private var subagents: [String: Subagent] = [:]
    private var pending: [String: PendingRequest] = [:]
    /// A turn (or compaction) of this app runs.
    private var isTurnActive = false
    /// The next `session.inbox.enqueued` of the session is the turn's user message.
    private var awaitsTurnID = false
    /// The session's model as last applied or read (`Model.Ref`).
    private var currentModel: JSONValue?
    private var currentPermissions: JSONValue?
    /// OpenCode's configured model (`Model.Info`).
    private var defaultModel: JSONValue?
    private var contextWindows: [String: Int] = [:]
    private var commandNames: Set<String> = []
    private var skillIDs: Set<String> = []
    /// OpenCode reported changed commands or skills since the last read.
    private var commandsChanged = false
    private var shellPolls: [String: Task<Void, Never>] = [:]
    private var streamTask: Task<Void, Never>?
    private var isConnected = false
    /// The app run's side questions of every OpenCode session (shared by the driver's sessions,
    /// so a resumed session keeps the topics of the one before it).
    private let sideQuestionStore: OpencodeSideQuestionStore
    private var runningSideQuestion: (id: String, task: Task<Void, Never>)?
    private var isClosing = false
    private var hasEnded = false
    /// Counts turns (and compactions), so a late answer acts only on the turn it was for.
    private var turnGeneration = 0

    public init(server: any OpencodeTransport, sideQuestions: OpencodeSideQuestionStore = OpencodeSideQuestionStore()) {
        self.server = server
        sideQuestionStore = sideQuestions
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self, bufferingPolicy: .unbounded)
    }

    /// This session's side questions, newest first.
    private var sideTopics: [SideQuestion] {
        sessionID.map(sideQuestionStore.topics(in:)) ?? []
    }

    // MARK: - Lifecycle

    public func start(_ config: SessionConfig) async throws -> String {
        guard self.config == nil, !hasEnded else { throw ProviderError.message("The OpenCode session was already started.") }
        try ProviderError.requireWorkspace(config.cwd)
        self.config = config
        mapper = OpencodeEventMapper(cwd: config.cwd)
        location = config.cwd
        do {
            try await openEventStream()
            await readCatalog(directory: config.cwd)
            try requireOpen()
            if let resume = config.resumeID, let info = try await existingSession(resume) {
                adopt(info)
            } else {
                var body: [String: JSONValue] = [
                    "location": ["directory": .string(config.cwd)],
                    "permissions": OpencodeProtocol.permissions(config.runtimeMode),
                ]
                if let model = modelRef(for: config.modelSelection) { body["model"] = model }
                try requireOpen()
                let created = try await server.request("POST", "/api/session", body: .object(body))
                guard let info = created["data"], let id = info["id"]?.nonEmptyString else {
                    throw ProviderError.invalidOutput("OpenCode did not report the new session.")
                }
                if isClosing || hasEnded {
                    // Closed while OpenCode created it: leave no empty session behind.
                    _ = try? await server.request("DELETE", "/api/session/\(id)", timeout: 5)
                }
                try requireOpen()
                adopt(info)
            }
            try await apply(config.modelSelection, mode: config.runtimeMode)
            await readCommands()
            try requireOpen()
        } catch {
            isClosing = true
            teardown()
            finish(error: nil)
            throw error
        }
        guard let sessionID else { throw ProviderError.notStarted }
        continuation.yield(.conversationID(sessionID))
        return sessionID
    }

    /// `close()` (or the stream's end) came while `start`, a turn's `apply` or a request waited:
    /// nothing more goes to the shared server for this session.
    private func requireOpen() throws {
        if isClosing || hasEnded { throw ProviderError.message("The OpenCode session was closed.") }
    }

    public func close() async {
        guard !isClosing else { return }
        isClosing = true
        if !hasEnded, let sessionID {
            // The server keeps the session; stop what it runs for this app, like quitting omp.
            if isTurnActive { _ = try? await server.request("POST", "/api/session/\(sessionID)/interrupt", timeout: 5) }
            for (id, subagent) in subagents where subagent.isRunOpen {
                _ = try? await server.request("POST", "/api/session/\(id)/interrupt", timeout: 5)
            }
        }
        teardown()
        finish(error: nil)
    }

    // MARK: - Turns

    public func startTurn(_ input: TurnInput) async throws -> String? {
        guard let sessionID, !hasEnded else { throw ProviderError.notStarted }
        guard !isTurnActive else { throw ProviderError.message("OpenCode is still working on the previous turn.") }
        try await apply(input.modelSelection, mode: input.runtimeMode)
        try requireOpen()
        mapper.resetTurn()
        turnGeneration += 1
        isTurnActive = true
        awaitsTurnID = true
        do {
            switch OpencodeProtocol.message(input, commands: commandNames, skills: skillIDs) {
            case let .prompt(body):
                let answer = try await server.request("POST", "/api/session/\(sessionID)/prompt", body: body)
                return answer["data"]?["id"]?.nonEmptyString
            case let .command(body):
                _ = try await server.request("POST", "/api/session/\(sessionID)/command", body: body)
                return nil
            }
        } catch {
            isTurnActive = false
            awaitsTurnID = false
            throw error
        }
    }

    public func steer(_ input: TurnInput) async throws {
        guard let sessionID, !hasEnded else { throw ProviderError.notStarted }
        guard isTurnActive else { throw ProviderError.noActiveTurn }
        guard case let .prompt(body) = OpencodeProtocol.message(input, commands: [], skills: [], delivery: "steer") else { return }
        _ = try await server.request("POST", "/api/session/\(sessionID)/prompt", body: body)
    }

    public func interrupt() async {
        guard let sessionID, isTurnActive else { return }
        let turn = turnGeneration
        let answer = try? await server.request("POST", "/api/session/\(sessionID)/interrupt")
        guard answer?["interrupted"]?.boolValue == false else { return }
        // Nothing ran at that moment: the execution never started, or it just ended and its end
        // event is on the way. Give that event a moment, then end this turn (not a newer one).
        for _ in 0..<20 where isTurnActive && turnGeneration == turn {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if isTurnActive, turnGeneration == turn {
            endTurn(with: [.turnCompleted(outcome: .interrupted, error: nil)])
        }
    }

    public func respond(toApproval id: String, decision: ApprovalDecision) async {
        guard let request = pending.removeValue(forKey: id) else { return }
        _ = try? await server.request(
            "POST",
            "/api/session/\(request.owner)/permission/\(id)/reply",
            body: OpencodeProtocol.permissionReply(decision)
        )
    }

    /// Empty `answers` = the user dismissed the questions (the form is cancelled).
    public func answer(userInput id: String, answers: [String: [String]]) async {
        guard let request = pending.removeValue(forKey: id), let form = request.form else { return }
        if answers.isEmpty {
            _ = try? await server.request("DELETE", "/api/session/\(request.owner)/form/\(id)")
        } else {
            _ = try? await server.request(
                "POST",
                "/api/session/\(request.owner)/form/\(id)/reply",
                body: OpencodeProtocol.formReply(form: form, answers: answers)
            )
        }
    }

    public func compact() async throws {
        guard let sessionID, !hasEnded else { throw ProviderError.notStarted }
        guard !isTurnActive else {
            throw ProviderError.message("OpenCode is still working; compact the conversation once the turn has ended.")
        }
        mapper.resetTurn()
        turnGeneration += 1
        isTurnActive = true
        awaitsTurnID = true
        do {
            _ = try await server.request("POST", "/api/session/\(sessionID)/compact", body: [:])
        } catch {
            isTurnActive = false
            awaitsTurnID = false
            throw error
        }
    }

    public func rollback(beforeTurn ordinal: Int, providerTurnID: String?) async throws {
        guard let sessionID, !hasEnded else { throw ProviderError.notStarted }
        guard let messageID = providerTurnID else {
            throw ProviderError.message("OpenCode has no record of where turn \(ordinal) starts, so the conversation cannot be rewound.")
        }
        _ = try await server.request("POST", "/api/session/\(sessionID)/revert/stage", body: ["messageID": .string(messageID), "files": false])
        _ = try await server.request("POST", "/api/session/\(sessionID)/revert/commit")
        mapper.resetTurn()
    }

    // MARK: - Subagents

    public func steerSubagent(_ id: String, text: String) async throws {
        guard let child = subagentSession(named: id) else { throw ProviderError.message("OpenCode has no running subagent \(id).") }
        _ = try await server.request("POST", "/api/session/\(child)/prompt", body: ["text": .string(text), "delivery": "steer"])
    }

    public func cancelSubagent(_ id: String) async throws {
        guard let child = subagentSession(named: id) else { return }
        _ = try await server.request("POST", "/api/session/\(child)/interrupt")
    }

    private func subagentSession(named name: String) -> String? {
        subagents.first { $0.value.name == name }?.key
    }

    // MARK: - Side questions

    public func askSideQuestion(_ question: String, topicID: String?) async throws -> SideQuestion {
        guard let sessionID, !hasEnded else { throw ProviderError.notStarted }
        guard runningSideQuestion == nil else {
            throw ProviderError.message("A side question is still being answered.")
        }
        let exchange = SideQuestionExchange(question: question, status: .running, createdAt: Date())
        var record: SideQuestion
        var earlier: [SideQuestionExchange] = []
        if let topicID, let topic = sideTopics.first(where: { $0.id == topicID }) {
            record = topic
            earlier = topic.exchanges
            record.followUps.append(exchange)
        } else {
            record = SideQuestion(id: "btw-\(UUID().uuidString)", first: exchange)
        }
        storeSideQuestion(record)
        continuation.yield(.sideQuestion(record))
        let prompt = OpencodeProtocol.sideQuestionPrompt(question, earlier: earlier)
        let server = server
        let id = record.id
        let task = Task { [weak self] in
            do {
                let answer = try await server.request(
                    "POST",
                    "/api/session/\(sessionID)/generate",
                    body: ["prompt": .string(prompt)],
                    timeout: Self.generateTimeout
                )
                await self?.finishSideQuestion(id, answer: answer["data"]?["text"]?.stringValue ?? "", error: nil)
            } catch {
                await self?.finishSideQuestion(id, answer: nil, error: error.localizedDescription)
            }
        }
        runningSideQuestion = (id, task)
        return record
    }

    public func cancelSideQuestion() async -> Bool {
        guard let running = runningSideQuestion else { return false }
        runningSideQuestion = nil
        running.task.cancel()
        settleSideQuestion(running.id, status: .cancelled, answer: nil, error: nil)
        return true
    }

    public func sideQuestions() async throws -> [SideQuestion] {
        sideTopics
    }

    private func finishSideQuestion(_ id: String, answer: String?, error: String?) {
        guard runningSideQuestion?.id == id else { return }
        runningSideQuestion = nil
        if let answer, !answer.isEmpty { continuation.yield(.sideQuestionDelta(id: id, delta: answer)) }
        settleSideQuestion(id, status: answer == nil ? .failed : .complete, answer: answer, error: error)
    }

    private func settleSideQuestion(_ id: String, status: SideQuestionStatus, answer: String?, error: String?) {
        guard var record = sideTopics.first(where: { $0.id == id }) else { return }
        if let answer { record.latest.answer = answer }
        record.latest.status = status
        record.latest.error = error
        record.latest.updatedAt = Date()
        storeSideQuestion(record)
        continuation.yield(.sideQuestion(record))
    }

    private func storeSideQuestion(_ record: SideQuestion) {
        guard let sessionID else { return }
        sideQuestionStore.store(record, in: sessionID)
    }

    // MARK: - Setup

    private func openEventStream() async throws {
        let stream = try await server.events()
        streamTask = Task { [weak self] in
            do {
                for try await event in stream {
                    await self?.handle(event)
                }
                await self?.streamEnded(error: nil)
            } catch {
                await self?.streamEnded(error: error)
            }
        }
        let deadline = Date().addingTimeInterval(Self.connectTimeout)
        while !isConnected {
            if hasEnded { throw ProviderError.message("OpenCode closed the event stream.") }
            if Date() > deadline { throw ProviderError.timedOut("Connecting to OpenCode's event stream") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Context windows and the configured model; without them the context meter has no
    /// window and "default" keeps whatever the session runs.
    private func readCatalog(directory: String) async {
        let list = try? await server.list("/api/model", directory: directory, retryWhileEmpty: true)
        let configured = try? await server.request("GET", "/api/model/default", query: ["location[directory]": directory])
        defaultModel = configured?["data"].flatMap { $0.objectValue == nil ? nil : $0 }
        contextWindows = OpencodeProtocol.contextWindows(list: list, defaultModel: defaultModel)
    }

    /// The saved session, or nil when OpenCode no longer has it.
    private func existingSession(_ id: String) async throws -> JSONValue? {
        do {
            return try await server.request("GET", "/api/session/\(id)")["data"]
        } catch let ProviderError.rpc(_, code, _) where code == 404 {
            return nil
        }
    }

    private func adopt(_ info: JSONValue) {
        sessionID = info["id"]?.nonEmptyString
        location = info["location"]?["directory"]?.nonEmptyString ?? location
        currentModel = info["model"]
        currentPermissions = info["permissions"] ?? []
    }

    /// Brings the session to `selection` and `mode` (see the type's comment).
    private func apply(_ selection: ModelSelection, mode: RuntimeMode) async throws {
        guard let sessionID else { throw ProviderError.notStarted }
        try requireOpen()
        if let target = modelRef(for: selection), !Self.sameModel(target, currentModel) {
            _ = try await server.request("POST", "/api/session/\(sessionID)/model", body: ["model": target])
            currentModel = target
            try requireOpen()
        }
        let rules = OpencodeProtocol.permissions(mode)
        if rules != (currentPermissions ?? []) {
            _ = try await server.request("PATCH", "/api/session/\(sessionID)", body: ["permissions": rules])
            currentPermissions = rules
            try requireOpen()
        }
        mapper.contextWindow = contextWindows[selection.model]
    }

    /// `Model.Ref` for a selection: its `provider/id`, or OpenCode's configured model for
    /// "default" (nil while that is unknown).
    private func modelRef(for selection: ModelSelection) -> JSONValue? {
        if let spec = OpencodeProtocol.modelSpec(selection.model) {
            return OpencodeProtocol.modelRef(provider: spec.provider, id: spec.id, effort: selection.effort)
        }
        guard let provider = defaultModel?["providerID"]?.nonEmptyString, let id = defaultModel?["id"]?.nonEmptyString else { return nil }
        return OpencodeProtocol.modelRef(provider: provider, id: id, effort: selection.effort)
    }

    static func sameModel(_ lhs: JSONValue, _ rhs: JSONValue?) -> Bool {
        guard let rhs else { return false }
        func variant(_ ref: JSONValue) -> String { ref["variant"]?.nonEmptyString ?? OpencodeProtocol.defaultVariant }
        return lhs["id"] == rhs["id"] && lhs["providerID"] == rhs["providerID"] && variant(lhs) == variant(rhs)
    }

    /// `GET /api/command` and `GET /api/skill` in the workspace → `commands`.
    private func readCommands() async {
        guard let config else { return }
        commandsChanged = false
        guard let commands = try? await server.list("/api/command", directory: config.cwd, retryWhileEmpty: true) else { return }
        let skills = try? await server.list("/api/skill", directory: config.cwd)
        commandNames = Set((commands.arrayValue ?? []).compactMap { $0["name"]?.nonEmptyString })
        skillIDs = Set((skills?.arrayValue ?? []).compactMap { $0["id"]?.nonEmptyString })
        continuation.yield(.commands(OpencodeProtocol.commands(commands, skills: skills)))
    }

    // MARK: - Events

    private func handle(_ event: JSONValue) async {
        guard !hasEnded else { return }
        let data = event["data"] ?? [:]
        switch event["type"]?.stringValue ?? "" {
        case "server.connected":
            isConnected = true
        case "session.created":
            registerSubagent(data)
        case "session.deleted":
            if let sessionID, data["sessionID"]?.stringValue == sessionID {
                teardown()
                finish(error: "The OpenCode session was deleted.")
            }
        case "permission.asked":
            requestApproval(data)
        case "form.created":
            requestAnswers(data["form"] ?? [:])
        case "permission.replied":
            resolve(data["requestID"]?.stringValue)
        case "form.replied", "form.cancelled":
            resolve(data["id"]?.stringValue)
        case "command.updated", "skill.updated":
            commandsChanged = true
        default:
            guard let owner = data["sessionID"]?.stringValue else { return }
            if owner == sessionID {
                await handleOwn(event, data: data)
            } else if subagents[owner] != nil {
                handleSubagent(owner, event, data: data)
            }
        }
    }

    private func handleOwn(_ event: JSONValue, data: JSONValue) async {
        let type = event["type"]?.stringValue ?? ""
        guard isTurnActive else { return }
        if type == "session.inbox.enqueued" {
            if awaitsTurnID, let id = data["inboxID"]?.nonEmptyString {
                awaitsTurnID = false
                continuation.yield(.turnStarted(providerTurnID: id))
            }
            return
        }
        if type == "session.tool.progress", let toolID = data["id"]?.nonEmptyString, let metadata = data["metadata"] {
            if let shellID = metadata["shellID"]?.nonEmptyString, let sessionID {
                pollShell(shellID, tool: toolID, owner: sessionID)
            }
            if let child = metadata["sessionID"]?.nonEmptyString, let subagent = subagents[child] {
                var info = SubagentInfo(parentToolCallID: toolID)
                info.assignment = mapper.tools[toolID]?.input["prompt"]?.nonEmptyString
                continuation.yield(.subagent(id: subagent.name, .updated(info)))
            }
        }
        let events = mapper.map(event)
        if type == "session.tool.success" || type == "session.tool.failed", let toolID = data["id"]?.stringValue, let sessionID {
            stopShellPoll(tool: toolID, owner: sessionID)
        }
        if events.contains(where: { if case .turnCompleted = $0 { true } else { false } }) {
            endTurn(with: events)
            if commandsChanged { await readCommands() }
        } else {
            for event in events { continuation.yield(event) }
        }
    }

    /// The turn is over: withdraw questions nobody can answer any more, then report `events`
    /// (ending with `turnCompleted`).
    private func endTurn(with events: [ProviderEvent]) {
        isTurnActive = false
        awaitsTurnID = false
        for id in pending.keys.sorted() { continuation.yield(.requestResolved(id: id)) }
        pending.removeAll()
        // A subagent can outlive the turn (a message woke it); its live output keeps flowing.
        if let sessionID {
            for key in shellPolls.keys where key.hasPrefix("\(sessionID)/") {
                shellPolls.removeValue(forKey: key)?.cancel()
            }
        }
        for event in events { continuation.yield(event) }
    }

    // MARK: Subagents

    /// `session.created` of a session whose parent is this session or one of its subagents,
    /// while a turn of this app runs (another client's subagents are not this thread's).
    private func registerSubagent(_ data: JSONValue) {
        guard isTurnActive, let child = data["sessionID"]?.nonEmptyString, subagents[child] == nil,
              let parent = data["parentID"]?.stringValue, parent == sessionID || subagents[parent] != nil else { return }
        let name = data["slug"]?.nonEmptyString ?? child
        subagents[child] = Subagent(name: name, mapper: OpencodeEventMapper(cwd: config?.cwd))
        var info = SubagentInfo(agent: data["agent"]?.nonEmptyString ?? "subagent", status: .running)
        info.description = data["title"]?.nonEmptyString
        if let provider = data["model"]?["providerID"]?.nonEmptyString, let id = data["model"]?["id"]?.nonEmptyString {
            info.model = "\(provider)/\(id)"
        }
        continuation.yield(.subagent(id: name, .updated(info)))
    }

    private func handleSubagent(_ child: String, _ event: JSONValue, data: JSONValue) {
        guard var subagent = subagents[child] else { return }
        defer { subagents[child] = subagent }
        let name = subagent.name
        let type = event["type"]?.stringValue ?? ""
        switch type {
        case "session.inbox.enqueued":
            guard data["item"]?["type"]?.stringValue == "user", let text = data["item"]?["payload"]?["text"]?.stringValue else { return }
            let message = Self.subagentMessage(text)
            if subagent.isRunOpen {
                continuation.yield(.subagent(id: name, .message(message)))
            } else {
                subagent.isRunOpen = true
                var info = SubagentInfo(status: .running)
                if !subagent.hasAssignment {
                    subagent.hasAssignment = true
                    info.assignment = message
                }
                continuation.yield(.subagent(id: name, .updated(info)))
                continuation.yield(.subagent(id: name, .runStarted(message: message)))
            }
            return
        case "session.execution.started":
            guard !subagent.isRunOpen else { return }
            subagent.isRunOpen = true
            continuation.yield(.subagent(id: name, .updated(SubagentInfo(status: .running))))
            continuation.yield(.subagent(id: name, .runStarted(message: nil)))
            return
        case "session.tool.progress":
            if let toolID = data["id"]?.nonEmptyString, let shellID = data["metadata"]?["shellID"]?.nonEmptyString {
                pollShell(shellID, tool: toolID, owner: child)
            }
        case "session.tool.success", "session.tool.failed":
            if let toolID = data["id"]?.nonEmptyString { stopShellPoll(tool: toolID, owner: child) }
        default:
            break
        }
        for mapped in subagent.mapper.map(event) {
            switch mapped {
            case let .itemUpdated(item):
                continuation.yield(.subagent(id: name, .itemUpdated(item)))
                if item.status == .running, let intent = subagent.mapper.title(ofTool: item.id), intent != subagent.lastIntent {
                    subagent.lastIntent = intent
                    continuation.yield(.subagent(id: name, .updated(SubagentInfo(lastIntent: intent))))
                }
            case let .assistantDelta(itemID, delta, _):
                continuation.yield(.subagent(id: name, .assistantDelta(itemID: itemID, delta: delta)))
            case let .reasoningDelta(itemID, delta):
                continuation.yield(.subagent(id: name, .reasoningDelta(itemID: itemID, delta: delta)))
            case let .commandOutputDelta(itemID, delta):
                continuation.yield(.subagent(id: name, .commandOutputDelta(itemID: itemID, delta: delta)))
            case let .turnCompleted(outcome, error):
                subagent.isRunOpen = false
                continuation.yield(.subagent(id: name, .runEnded(outcome: outcome, error: error)))
                let status: SubagentStatus = switch outcome {
                case .completed: .completed
                case .failed: .failed
                case .interrupted: .aborted
                }
                continuation.yield(.subagent(id: name, .updated(SubagentInfo(status: status))))
            default:
                break
            }
        }
    }

    /// OpenCode prefixes a subagent's assignment with a line telling it what it is.
    static func subagentMessage(_ text: String) -> String {
        let preface = "You are a subagent spawned by another session.\n"
        return text.hasPrefix(preface) ? String(text.dropFirst(preface.count)) : text
    }

    // MARK: Requests

    private func requestApproval(_ data: JSONValue) {
        guard let owner = data["sessionID"]?.stringValue, owner == sessionID || subagents[owner] != nil,
              let id = data["id"]?.nonEmptyString else { return }
        guard isTurnActive else {
            // A subagent a message woke after the turn: nobody would see the prompt, so it
            // carries on without the action (omp cancels such dialogs too). The session's own
            // requests then come from another client, which answers them.
            if owner != sessionID { Task { [server] in _ = try? await server.request("POST", "/api/session/\(owner)/permission/\(id)/reply", body: OpencodeProtocol.permissionReply(.decline)) } }
            return
        }
        guard var approval = OpencodeProtocol.approval(data, cwd: config?.cwd) else { return }
        // OpenCode asks per parsed command (`a && b` → [a, b]) and names files relative to its
        // project root; the tool call has the whole line and the absolute path.
        let tools = owner == sessionID ? mapper.tools : subagents[owner]?.mapper.tools
        if let toolID = data["source"]?["id"]?.stringValue, let input = tools?[toolID]?.input {
            if approval.kind == .command, let command = input["command"]?.nonEmptyString {
                approval.detail = command
            } else if approval.kind == .fileChange, let path = (input["path"] ?? input["filePath"])?.nonEmptyString, path.hasPrefix("/") {
                approval.detail = OmpEventMapper.relative(path, to: config?.cwd)
            }
        }
        if let subagent = subagents[owner] {
            approval.reason = approval.reason ?? "Asked by subagent \(subagent.name)."
        }
        pending[approval.id] = PendingRequest(owner: owner)
        continuation.yield(.approvalRequested(approval))
    }

    private func requestAnswers(_ form: JSONValue) {
        guard let owner = form["sessionID"]?.stringValue, owner == sessionID || subagents[owner] != nil,
              let id = form["id"]?.nonEmptyString else { return }
        guard isTurnActive else {
            if owner != sessionID { Task { [server] in _ = try? await server.request("DELETE", "/api/session/\(owner)/form/\(id)") } }
            return
        }
        guard let request = OpencodeProtocol.userInput(form: form) else { return }
        pending[request.id] = PendingRequest(owner: owner, form: form)
        continuation.yield(.userInputRequested(request))
    }

    private func resolve(_ id: String?) {
        guard let id, pending.removeValue(forKey: id) != nil else { return }
        continuation.yield(.requestResolved(id: id))
    }

    // MARK: Shell output

    /// Streams a running shell tool's output into its item until the tool ends.
    private func pollShell(_ shellID: String, tool toolID: String, owner: String) {
        let key = "\(owner)/\(toolID)"
        guard shellPolls[key] == nil else { return }
        let server = server
        let query = ["location[directory]": location]
        shellPolls[key] = Task { [weak self] in
            var cursor = 0
            while !Task.isCancelled {
                var request = query
                request["cursor"] = String(cursor)
                if let data = try? await server.request("GET", "/api/shell/\(shellID)/output", query: request, timeout: 10)["data"] {
                    let output = data["output"]?.stringValue ?? ""
                    cursor = data["cursor"]?.intValue ?? cursor + output.utf8.count
                    if !output.isEmpty { await self?.shellOutput(output, tool: toolID, owner: owner) }
                }
                try? await Task.sleep(nanoseconds: Self.shellPollInterval)
            }
        }
    }

    private func stopShellPoll(tool toolID: String, owner: String) {
        shellPolls.removeValue(forKey: "\(owner)/\(toolID)")?.cancel()
    }

    private func shellOutput(_ output: String, tool toolID: String, owner: String) {
        if owner == sessionID {
            for event in mapper.appendOutput(toolID: toolID, output) { continuation.yield(event) }
        } else if var subagent = subagents[owner] {
            for case let .commandOutputDelta(itemID, delta) in subagent.mapper.appendOutput(toolID: toolID, output) {
                continuation.yield(.subagent(id: subagent.name, .commandOutputDelta(itemID: itemID, delta: delta)))
            }
            subagents[owner] = subagent
        }
    }

    // MARK: - Ending

    private func streamEnded(error: (any Error)?) {
        guard !isClosing, !hasEnded else { return }
        teardown()
        let reason = error.map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription }
        finish(error: "Lost the connection to OpenCode" + (reason.map { ": \($0)" } ?? "."))
    }

    private func teardown() {
        streamTask?.cancel()
        streamTask = nil
        for task in shellPolls.values { task.cancel() }
        shellPolls.removeAll()
        runningSideQuestion?.task.cancel()
    }

    private func finish(error: String?) {
        guard !hasEnded else { return }
        hasEnded = true
        isTurnActive = false
        for (_, subagent) in subagents.sorted(by: { $0.value.name < $1.value.name }) where subagent.isRunOpen {
            continuation.yield(.subagent(id: subagent.name, .runEnded(outcome: .interrupted, error: nil)))
            continuation.yield(.subagent(id: subagent.name, .updated(SubagentInfo(status: .aborted))))
        }
        if let running = runningSideQuestion {
            runningSideQuestion = nil
            settleSideQuestion(running.id, status: .interrupted, answer: nil, error: nil)
        }
        continuation.yield(.sessionEnded(error: error))
        continuation.finish()
    }
}

/// Side questions OpenCode keeps no history of, per OpenCode session id, for the app's run.
public final class OpencodeSideQuestionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var topics: [String: [SideQuestion]] = [:]

    public init() {}

    /// The session's topics, newest first.
    func topics(in sessionID: String) -> [SideQuestion] {
        lock.withLock { topics[sessionID] ?? [] }
    }

    func store(_ record: SideQuestion, in sessionID: String) {
        lock.withLock {
            var list = topics[sessionID] ?? []
            list.removeAll { $0.id == record.id }
            list.append(record)
            list.sort { $0.first.createdAt > $1.first.createdAt }
            topics[sessionID] = list
        }
    }
}
