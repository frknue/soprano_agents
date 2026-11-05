import Foundation

// The team: teammates are threads that carry a `Teammate`. This file creates, edits and
// deletes them, prepares their launch files (persona, memory), exports them to omp, and
// serves the team host tools (`TeamTools`) every omp conversation gets.

extension AgentEngine {
    // MARK: Reading

    /// Teammate threads (not archived), in creation order.
    public var team: [AgentThread] {
        threads.filter { $0.teammate != nil && $0.archivedAt == nil }
    }

    public func teammateThread(handle: String) -> AgentThread? {
        let wanted = handle.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@`"))
        return team.first { $0.teammate?.handle == wanted }
            ?? team.first { $0.teammate?.name.lowercased() == wanted }
    }

    /// The Edit dialog's prefill.
    public func teammateDraft(_ threadID: String) -> TeammateDraft? {
        guard let thread = thread(threadID), let teammate = thread.teammate else { return nil }
        return TeammateDraft(
            name: teammate.name,
            handle: teammate.handle,
            role: teammate.role,
            instructions: teammate.instructions,
            projectID: thread.projectID,
            exportsToOmp: teammate.exportsToOmp
        )
    }

    // MARK: Lifecycle

    /// Creates a teammate: an empty thread on omp (the default omp model and runtime mode)
    /// that carries it. Its home is the project's root, or its own folder.
    public func createTeammate(_ draft: TeammateDraft) throws -> TeammateSaveResult {
        let teammate = try validatedTeammate(draft, threadID: nil)
        let selection = settings.defaultModel.provider == .omp ? settings.defaultModel : .default(for: .omp)
        let thread = AgentThread(
            projectID: draft.projectID,
            title: teammate.name,
            createdAt: environment.now(),
            modelSelection: selection,
            runtimeMode: settings.defaultRuntimeMode,
            teammate: teammate
        )
        insertThread(thread)
        let warning = syncOmpExport(thread.id, previous: nil)
        refreshTeamTools()
        return TeammateSaveResult(threadID: thread.id, warning: warning)
    }

    /// Saves an edited teammate. A new persona or home reaches its conversation with its next
    /// turn (a new process resuming it).
    public func updateTeammate(_ threadID: String, _ draft: TeammateDraft) throws -> TeammateSaveResult {
        guard let thread = thread(threadID), let previous = thread.teammate else { throw EngineError.unknownThread(threadID) }
        let teammate = try validatedTeammate(draft, threadID: threadID)
        let homeChanged = thread.projectID != draft.projectID
        updateThread(threadID) { thread in
            thread.teammate = teammate
            thread.title = teammate.name
            if homeChanged {
                thread.projectID = draft.projectID
                thread.worktreePath = nil
                thread.branch = nil
            }
        }
        if homeChanged || teammate.name != previous.name || teammate.handle != previous.handle
            || teammate.role != previous.role || teammate.instructions != previous.instructions {
            runtime.thread(threadID).relaunchRequested = true
        }
        let warning = syncOmpExport(threadID, previous: previous)
        refreshTeamTools()
        return TeammateSaveResult(threadID: threadID, warning: warning)
    }

    /// `deleteThread` removed a teammate: its export, launch files and memory go too, and
    /// whoever waits for its reply gets an error.
    func teammateDeleted(_ threadID: String, _ teammate: Teammate) {
        removeOmpExport(handle: teammate.handle, threadID: threadID)
        try? FileManager.default.removeItem(at: teammateDirectory(threadID))
        resolveTeamWaits(threadID)
        refreshTeamTools()
    }

    private func validatedTeammate(_ draft: TeammateDraft, threadID: String?) throws -> Teammate {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw EngineError.message("Give the teammate a name.") }
        let handle = draft.handle.trimmingCharacters(in: .whitespaces)
        let taken = Set(threads.filter { $0.id != threadID }.compactMap { $0.teammate?.handle })
        if let problem = Teammate.handleProblem(handle, taken: taken) { throw EngineError.message(problem) }
        if let projectID = draft.projectID, project(projectID) == nil { throw EngineError.unknownProject(projectID) }
        return Teammate(
            name: name,
            handle: handle,
            role: draft.role.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            exportsToOmp: draft.exportsToOmp
        )
    }

    // MARK: Launch settings

    /// `<data>/team/<thread>`: a teammate's persona, memory settings and memory database.
    func teammateDirectory(_ threadID: String) -> URL {
        environment.dataDirectory.appendingPathComponent("team/\(threadID)", isDirectory: true)
    }

    /// The session settings a thread's conversation starts with: its working directory, model
    /// and resume id; for omp also the team tools, and for a teammate its persona and memory
    /// (written fresh on every launch).
    func sessionConfig(for thread: AgentThread) throws -> SessionConfig {
        var config = SessionConfig(
            cwd: workingDirectory(for: thread),
            modelSelection: thread.modelSelection,
            runtimeMode: thread.runtimeMode,
            resumeID: thread.providerThreadID
        )
        guard thread.modelSelection.provider == .omp else { return config }
        config.hostTools = teamToolDefinitions(for: thread)
        guard let teammate = thread.teammate else { return config }
        let directory = teammateDirectory(thread.id)
        let memory = directory.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        let persona = directory.appendingPathComponent("persona.md")
        let overlay = directory.appendingPathComponent("memory.yml")
        let home = (config.cwd as NSString).abbreviatingWithTildeInPath
        try TeamTools.persona(teammate, home: home, hasMemory: true).write(to: persona, atomically: true, encoding: .utf8)
        try TeamTools.memoryOverlay(databasePath: memory.appendingPathComponent("mnemopi.db").path).write(to: overlay, atomically: true, encoding: .utf8)
        config.systemPromptFile = persona.path
        config.configOverlays = [overlay.path]
        return config
    }

    /// The team tools of `thread`'s conversation: the other teammates it can reach.
    func teamToolDefinitions(for thread: AgentThread) -> [HostToolDefinition] {
        let others = team.filter { $0.id != thread.id }.compactMap(\.teammate)
        return TeamTools.definitions(others: others, callerIsTeammate: thread.teammate != nil)
    }

    /// The team changed: every live omp conversation gets the new tools. A session still starting
    /// syncs them itself before its first turn (`ensureSession`); this catches the moment after.
    func refreshTeamTools() {
        for (threadID, rt) in runtime.allThreads {
            guard let session = rt.session, session.kind == .omp else { continue }
            let starting = rt.starting
            runtime.track { [self] in
                if let starting { _ = try? await starting.value }
                guard runtime.existingThread(threadID)?.session === session, let thread = thread(threadID) else { return }
                await session.setHostTools(teamToolDefinitions(for: thread))
            }
        }
    }

    // MARK: omp export

    /// Writes, moves or removes the teammate's `<handle>.md` in omp's agents folder. Returns a
    /// problem worth telling the user (a file Soprano Agents didn't write is in the way, or the
    /// folder can't be written); the teammate is saved either way.
    @discardableResult
    func syncOmpExport(_ threadID: String, previous: Teammate?) -> String? {
        guard environment.ompAgentsDirectory != nil, let thread = thread(threadID), let teammate = thread.teammate else { return nil }
        if let previous, previous.handle != teammate.handle || !teammate.exportsToOmp {
            removeOmpExport(handle: previous.handle, threadID: threadID)
        }
        guard teammate.exportsToOmp else { return nil }
        return writeOmpExport(thread, teammate)
    }

    private func writeOmpExport(_ thread: AgentThread, _ teammate: Teammate) -> String? {
        guard let directory = environment.ompAgentsDirectory else { return nil }
        let file = directory.appendingPathComponent("\(teammate.handle).md")
        let display = (file.path as NSString).abbreviatingWithTildeInPath
        // Anything at the path (a symlink, a file in another encoding, one we can't read) counts as
        // someone else's unless it reads as ours.
        if (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil {
            let owner = (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }.flatMap(TeamTools.exportOwner)
            if owner != thread.id {
                return "\(display) already exists and wasn't written for this teammate, so terminal omp keeps that agent. Rename the handle or remove the file to export \(teammate.name)."
            }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try TeamTools.ompAgentFile(teammate, threadID: thread.id, model: thread.modelSelection.model)
                .write(to: file, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "Couldn't write \(display): \(Self.describe(error))"
        }
    }

    private func removeOmpExport(handle: String, threadID: String) {
        guard let directory = environment.ompAgentsDirectory else { return }
        let file = directory.appendingPathComponent("\(handle).md")
        guard let existing = try? String(contentsOf: file, encoding: .utf8), TeamTools.exportOwner(existing) == threadID else { return }
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Host tools

    static func hostCallKey(_ threadID: String, _ callID: String) -> String { "\(threadID)\n\(callID)" }

    /// Serves a host tool call of `threadID`'s conversation in the background and answers the
    /// session that asked (when it is still the thread's).
    func serveHostTool(_ call: HostToolCall, threadID: String) {
        guard let session = runtime.existingThread(threadID)?.session else { return }
        let key = Self.hostCallKey(threadID, call.id)
        runtime.hostToolTasks[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.runHostTool(call, threadID: threadID)
            guard runtime.hostToolTasks.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
            await session.finishHostTool(call.id, result: result)
        }
    }

    /// The provider gave up on a call (Stop, process gone): stop serving it.
    func cancelHostTool(_ callID: String, threadID: String) {
        runtime.hostToolTasks.removeValue(forKey: Self.hostCallKey(threadID, callID))?.cancel()
    }

    private func runHostTool(_ call: HostToolCall, threadID: String) async -> HostToolResult {
        guard let caller = thread(threadID) else { return HostToolResult(text: "The asking thread is gone.", isError: true) }
        switch call.name {
        case TeamTools.message:
            let to = call.arguments["to"]?.stringValue ?? ""
            let text = call.arguments["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return await messageTeammate(to, text: text, from: caller)
        case TeamTools.list:
            return HostToolResult(text: teamRoster(caller: caller))
        case TeamTools.activity:
            return teamActivity(call.arguments, caller: caller)
        case TeamTools.create where caller.teammate != nil:
            return teamCreate(call.arguments)
        case TeamTools.update where caller.teammate != nil:
            return teamUpdate(call.arguments)
        case TeamTools.delete where caller.teammate != nil:
            return await teamDelete(call.arguments, caller: caller)
        default:
            return HostToolResult(text: "Soprano Agents has no tool named \(call.name).", isError: true)
        }
    }

    private func teamRoster(caller: AgentThread) -> String {
        let entries = team.compactMap { thread -> (teammate: Teammate, status: String, home: String)? in
            guard let teammate = thread.teammate else { return nil }
            var status: String = switch ThreadStatus.of(thread) {
            case .approval: "waiting for the user's approval"
            case .input: "waiting for the user's answers"
            case let .working(since): "working for \(DurationText.compact(environment.now().timeIntervalSince(since)))"
            case .failed: "idle (last request failed)"
            case .done, .idle: "idle"
            }
            if !thread.queue.isEmpty { status += ", \(thread.queue.count) waiting" }
            return (teammate, status, (workingDirectory(for: thread) as NSString).abbreviatingWithTildeInPath)
        }
        return TeamTools.roster(entries, callerHandle: caller.teammate?.handle)
    }

    private func teamActivity(_ arguments: JSONValue, caller: AgentThread) -> HostToolResult {
        let target: AgentThread
        if let handle = arguments["teammate"]?.nonEmptyString {
            guard let found = teammateThread(handle: handle) else { return unknownTeammate(handle) }
            target = found
        } else if caller.teammate != nil {
            target = caller
        } else {
            return HostToolResult(text: "Name the teammate (`teammate`: its handle).", isError: true)
        }
        guard let teammate = target.teammate else { return unknownTeammate("") }
        let now = environment.now()
        guard let period = TeamTools.period(
            since: arguments["since"]?.stringValue, until: arguments["until"]?.stringValue, now: now, calendar: .current
        ) else {
            return HostToolResult(text: "Give `since` as today, yesterday, week or YYYY-MM-DD, and `until` as YYYY-MM-DD on or after it.", isError: true)
        }
        return HostToolResult(text: TeamTools.activityReport(target, teammate: teammate, period: period, now: now))
    }

    private func unknownTeammate(_ handle: String) -> HostToolResult {
        let handles = team.compactMap { $0.teammate?.handle }
        let known = handles.isEmpty ? "Nobody is on the team." : "Teammates: \(handles.joined(separator: ", "))."
        return HostToolResult(text: "There is no teammate “\(handle)”. \(known)", isError: true)
    }

    /// `team_create`: a teammate asked for a new one. Same rules as the New Teammate dialog; the
    /// handle defaults to one derived from the name, the home to its own folder.
    private func teamCreate(_ arguments: JSONValue) -> HostToolResult {
        let name = arguments["name"]?.nonEmptyString ?? ""
        var projectID: String?
        if let home = arguments["home"]?.nonEmptyString {
            switch homeProject(home) {
            case let .success(id): projectID = id
            case let .failure(problem): return HostToolResult(text: problem.text, isError: true)
            }
        }
        let draft = TeammateDraft(
            name: name,
            handle: arguments["handle"]?.nonEmptyString ?? Teammate.suggestedHandle(from: name),
            role: arguments["role"]?.stringValue ?? "",
            instructions: arguments["instructions"]?.stringValue ?? "",
            projectID: projectID
        )
        do {
            let saved = try createTeammate(draft)
            guard let thread = thread(saved.threadID), let teammate = thread.teammate else { return unknownTeammate(draft.handle) }
            let home = (workingDirectory(for: thread) as NSString).abbreviatingWithTildeInPath
            var text = "Added \(teammate.name) (`\(teammate.handle)`) to the team, home \(home). Reach it with `team_message` to `\(teammate.handle)`."
            if let warning = saved.warning { text += "\n\(warning)" }
            return HostToolResult(text: text)
        } catch {
            return HostToolResult(text: Self.describe(error), isError: true)
        }
    }

    /// `team_update`: changes the named fields of a teammate (the others stay); same rules as the
    /// Edit Teammate dialog. A new persona or home reaches its conversation with its next turn.
    private func teamUpdate(_ arguments: JSONValue) -> HostToolResult {
        let handle = arguments["teammate"]?.nonEmptyString ?? ""
        guard let target = teammateThread(handle: handle), var draft = teammateDraft(target.id) else { return unknownTeammate(handle) }
        if let name = arguments["name"]?.nonEmptyString { draft.name = name }
        if let newHandle = arguments["handle"]?.nonEmptyString { draft.handle = newHandle }
        if let role = arguments["role"]?.stringValue { draft.role = role }
        if let instructions = arguments["instructions"]?.stringValue { draft.instructions = instructions }
        if let home = arguments["home"]?.nonEmptyString {
            switch homeProject(home) {
            case let .success(id): draft.projectID = id
            case let .failure(problem): return HostToolResult(text: problem.text, isError: true)
            }
        }
        do {
            let saved = try updateTeammate(target.id, draft)
            guard let thread = thread(saved.threadID), let teammate = thread.teammate else { return unknownTeammate(draft.handle) }
            let home = (workingDirectory(for: thread) as NSString).abbreviatingWithTildeInPath
            var text = "Updated \(teammate.name) (`\(teammate.handle)`), home \(home). The change applies from its next turn."
            if let warning = saved.warning { text += "\n\(warning)" }
            return HostToolResult(text: text)
        } catch {
            return HostToolResult(text: Self.describe(error), isError: true)
        }
    }

    /// `team_delete`: removes a teammate with its conversation, memory and export. Never the caller.
    private func teamDelete(_ arguments: JSONValue, caller: AgentThread) async -> HostToolResult {
        let handle = arguments["teammate"]?.nonEmptyString ?? ""
        guard let target = teammateThread(handle: handle), let teammate = target.teammate else { return unknownTeammate(handle) }
        if target.id == caller.id { return HostToolResult(text: "A teammate can't delete itself; ask the user.", isError: true) }
        await deleteThread(target.id)
        return HostToolResult(text: "Deleted \(teammate.name) (`\(teammate.handle)`) with its conversation and memory.")
    }

    /// The project id a `home` argument names: `own` = the teammate's own folder (nil), else a
    /// project by path or unique title; the failure is the tool's error result.
    private func homeProject(_ home: String) -> Result<String?, HostToolResultError> {
        if home.caseInsensitiveCompare("own") == .orderedSame { return .success(nil) }
        if let project = projectNamed(home) { return .success(project.id) }
        let known = projects.map { "\($0.title) (\(($0.path as NSString).abbreviatingWithTildeInPath))" }
        let list = known.isEmpty ? "There are no projects." : "Projects: \(known.joined(separator: ", "))."
        return .failure(HostToolResultError(text: "No single project matches “\(home)”. \(list) Use `own` for the teammate's own folder."))
    }

    /// The project `text` names: its path (`~` allowed), else its title (case-insensitive); nil
    /// when none or several match.
    private func projectNamed(_ text: String) -> Project? {
        let path = URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL.path
        if let match = projects.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == path }) { return match }
        let titled = projects.filter { $0.title.caseInsensitiveCompare(text) == .orderedSame }
        return titled.count == 1 ? titled[0] : nil
    }

    /// `team_message`: delivers `text` to the teammate as a message of its own turn (queued
    /// behind its current work) and waits for that turn's answer. Refuses messages to oneself
    /// and to a teammate that is (directly or through others) waiting for the caller, which
    /// would never be answered. Cancelling the task (the caller stopped) withdraws the message
    /// or stops the turn working on it.
    private func messageTeammate(_ handle: String, text: String, from caller: AgentThread) async -> HostToolResult {
        guard let target = teammateThread(handle: handle), let teammate = target.teammate else { return unknownTeammate(handle) }
        guard !text.isEmpty else { return HostToolResult(text: "The message is empty.", isError: true) }
        if target.id == caller.id {
            return HostToolResult(text: "That's you: answer it yourself.", isError: true)
        }
        if isWaiting(target.id, on: caller.id) {
            return HostToolResult(
                text: "\(teammate.name) is waiting for your reply to its own message, so it can't answer you now. Put what you need from it in your final answer instead.",
                isError: true
            )
        }
        let sender = MessageSender(kind: caller.teammate == nil ? .thread : .teammate, threadID: caller.id, name: caller.teammate?.name ?? caller.title)
        let message = UserMessage(text: text, createdAt: environment.now(), sender: sender)
        let messageID = message.id
        let targetID = target.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<HostToolResult, Never>) in
                runtime.teamWaits[messageID] = TeamWait(callerThreadID: caller.id, targetThreadID: targetID, continuation: continuation)
                runtime.teamDeliveries.insert(messageID)
                runtime.track { [self] in
                    do {
                        try await deliver(targetID, message: message, mode: .queue) { runtime.teamWaits[messageID] != nil }
                    } catch {
                        finishTeamWait(messageID, HostToolResult(text: "Couldn't reach \(teammate.name): \(Self.describe(error))", isError: true))
                    }
                    runtime.teamDeliveries.remove(messageID)
                    resolveTeamWaits(targetID)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.withdrawTeamMessage(messageID) }
        }
    }

    /// Whether `waiter` waits, directly or through others, for `target`'s reply.
    private func isWaiting(_ waiter: String, on target: String) -> Bool {
        var seen: Set<String> = []
        var frontier = [waiter]
        while let current = frontier.popLast() {
            guard seen.insert(current).inserted else { continue }
            for wait in runtime.teamWaits.values where wait.callerThreadID == current {
                if wait.targetThreadID == target { return true }
                frontier.append(wait.targetThreadID)
            }
        }
        return false
    }

    /// Answers the team messages waiting on `threadID` whose turn ended (or yielded), and fails
    /// those whose message is gone (removed from the queue, rewound, the teammate deleted).
    func resolveTeamWaits(_ threadID: String) {
        let waiting = runtime.teamWaits.filter { $0.value.targetThreadID == threadID }
        guard !waiting.isEmpty else { return }
        let thread = thread(threadID)
        for (messageID, _) in waiting {
            guard let thread, let teammate = thread.teammate else {
                finishTeamWait(messageID, HostToolResult(text: "The teammate was deleted before it answered.", isError: true))
                continue
            }
            if let turn = thread.turns.last(where: { $0.userMessage.id == messageID || $0.steers.contains { $0.id == messageID } }) {
                if let reply = TeamTools.reply(from: turn, teammate: teammate) { finishTeamWait(messageID, reply) }
            } else if !thread.queue.contains(where: { $0.id == messageID }), !isDelivering(messageID) {
                finishTeamWait(messageID, HostToolResult(text: "The message to \(teammate.name) was withdrawn before it was answered.", isError: true))
            }
        }
    }

    /// The message is on its way into the teammate's thread (its `deliver` has not appended it
    /// yet): only the delivery's own resolve may judge it.
    private func isDelivering(_ messageID: String) -> Bool {
        runtime.teamDeliveries.contains(messageID)
    }

    private func finishTeamWait(_ messageID: String, _ result: HostToolResult) {
        runtime.teamWaits.removeValue(forKey: messageID)?.continuation.resume(returning: result)
    }

    /// The caller stopped waiting: a queued message is withdrawn, a turn working on it stopped.
    private func withdrawTeamMessage(_ messageID: String) {
        guard let wait = runtime.teamWaits[messageID] else { return }
        finishTeamWait(messageID, HostToolResult(text: "Stopped.", isError: true))
        let targetID = wait.targetThreadID
        guard let thread = thread(targetID) else { return }
        if thread.queue.contains(where: { $0.id == messageID }) {
            cancelQueued(targetID, messageID: messageID)
        } else if thread.activeTurn?.userMessage.id == messageID {
            runtime.track { [self] in await interrupt(targetID) }
        }
    }
}

/// A team tool argument that can't be used; its `text` becomes the tool's error result.
struct HostToolResultError: Error {
    let text: String
}
