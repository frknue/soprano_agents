import Foundation

/// Side questions (`/btw`): questions about a thread's conversation, answered beside it without
/// steering it or joining it. Providers with native `/btw` (`omp`, `opencode`) run it directly in
/// their session; providers without native `/btw` (`codex`, `claude`, `antigravity`) fall back to
/// an engine-level off-turn answer via `ProviderDriver.generateJSON`. Side questions are persisted
/// per thread under `<data>/side-questions/<threadID>.json` so history survives app restarts across
/// all providers.
extension AgentEngine {
    /// The thread's side questions known this run, newest first.
    public func sideQuestions(_ threadID: String?) -> [SideQuestion] {
        guard let threadID else { return [] }
        return runtime.existingThread(threadID)?.sideQuestions ?? []
    }

    /// A side question of the thread is starting: asked, and not reported by the provider yet
    /// (`cancelSideQuestion` stops it). Changes announce `.sideQuestionsChanged`.
    public func isStartingSideQuestion(_ threadID: String?) -> Bool {
        guard let threadID else { return false }
        return runtime.existingThread(threadID)?.isAskingSideQuestion ?? false
    }

    /// Asks a side question about the thread's conversation, or a follow-up in topic `topicID`.
    /// Runs beside a running turn. Works across all 5 providers.
    @discardableResult
    public func askSideQuestion(_ threadID: String, question: String, topicID: String? = nil) async throws -> String {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw EngineError.emptyMessage }
        guard let thread = thread(threadID) else { throw EngineError.unknownThread(threadID) }
        let rt = runtime.thread(threadID)
        guard !rt.isAskingSideQuestion, !sideQuestions(threadID).contains(where: \.isRunning) else {
            throw EngineError.message("A side question is still being answered. Stop it or wait for its answer.")
        }
        guard hasProviderConversation(thread) || !thread.turns.isEmpty else {
            throw EngineError.message("A side question asks about the conversation, so send the thread a message first.")
        }

        let driver = environment.drivers[thread.modelSelection.provider]
        let supportsNative = driver?.capabilities.supportsNativeSideQuestions ?? true
        if !supportsNative {
            return try await askFallbackSideQuestion(thread, question: question, topicID: topicID)
        }

        rt.isAskingSideQuestion = true
        rt.sideQuestionCancelRequested = false
        emit(.sideQuestionsChanged(threadID: threadID))
        defer {
            rt.isAskingSideQuestion = false
            rt.sideQuestionCancelRequested = false
            emit(.sideQuestionsChanged(threadID: threadID))
        }
        let session = try await ensureSession(threadID)
        if rt.sideQuestionCancelRequested { throw CancellationError() }
        let record: SideQuestion
        do {
            record = try await session.askSideQuestion(question, topicID: topicID)
        } catch where rt.sideQuestionCancelRequested {
            // The provider refused a question cancelled while it started.
            throw CancellationError()
        }
        if rt.sideQuestionCancelRequested {
            _ = await session.cancelSideQuestion()
        }
        let known = sideQuestions(threadID).first { $0.id == record.id }
        if known.map({ record.followUps.count > $0.followUps.count }) ?? true {
            upsertSideQuestion(record, threadID: threadID)
        }
        return record.id
    }

    /// Cancels the thread's running side question (its partial answer stays), or one still
    /// starting (`askSideQuestion` then throws `CancellationError`). The thread's turn keeps
    /// going. False when none ran or started.
    @discardableResult
    public func cancelSideQuestion(_ threadID: String) async -> Bool {
        guard let rt = runtime.existingThread(threadID) else { return false }
        if let fallbackTask = rt.sideQuestionTask {
            fallbackTask.cancel()
            rt.sideQuestionTask = nil
            interruptSideQuestions(threadID)
            return true
        }
        let starting = rt.isAskingSideQuestion
        guard starting || sideQuestions(threadID).contains(where: \.isRunning) else { return false }
        if starting { rt.sideQuestionCancelRequested = true }
        guard let session = rt.session, rt.starting == nil else { return starting }
        let cancelled = await session.cancelSideQuestion()
        return cancelled || starting
    }

    /// Reads the conversation's side-question history from disk and from the provider (when the
    /// provider supports native side questions).
    public func loadSideQuestions(_ threadID: String) async throws {
        guard let thread = thread(threadID) else { return }
        let rt = runtime.thread(threadID)
        if rt.sideQuestionsLoaded, rt.session == nil || rt.sideQuestions.contains(where: \.isRunning) { return }

        if !rt.sideQuestionsLoaded, rt.sideQuestions.isEmpty {
            let persisted = loadPersistedSideQuestions(threadID)
            if !persisted.isEmpty {
                restoreSideQuestions(persisted, threadID: threadID, persist: false)
            }
        }

        let supportsNative = environment.drivers[thread.modelSelection.provider]?.capabilities.supportsNativeSideQuestions ?? true
        guard supportsNative, hasProviderConversation(thread) else {
            rt.sideQuestionsLoaded = true
            return
        }
        let session = try await ensureSession(threadID)
        restoreSideQuestions(try await session.sideQuestions(), threadID: threadID)
    }

    /// Merges history `records` into the thread's side questions (the snapshot harness seeds it).
    public func restoreSideQuestions(_ records: [SideQuestion], threadID: String, persist: Bool = true) {
        let rt = runtime.thread(threadID)
        let known = Dictionary(rt.sideQuestions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let read = Set(records.map(\.id))
        let merged = records.map { record in known[record.id].map { Self.later($0, record) } ?? record }
            + rt.sideQuestions.filter { !read.contains($0.id) }
        rt.sideQuestions = Self.newestFirst(merged)
        rt.sideQuestionsLoaded = true
        if persist { savePersistedSideQuestions(rt.sideQuestions, threadID: threadID) }
        emit(.sideQuestionsChanged(threadID: threadID))
    }

    private static func later(_ known: SideQuestion, _ record: SideQuestion) -> SideQuestion {
        if known.followUps.count != record.followUps.count {
            return known.followUps.count > record.followUps.count ? known : record
        }
        if record.isRunning, !known.isRunning { return known }
        if record.isRunning, known.latest.answer.count > record.latest.answer.count { return known }
        return record
    }

    // MARK: Engine-level fallback (/btw for Codex, Claude Code, Antigravity)

    private func askFallbackSideQuestion(_ thread: AgentThread, question: String, topicID: String?) async throws -> String {
        let threadID = thread.id
        let now = environment.now()
        let rt = runtime.thread(threadID)

        let exchange = SideQuestionExchange(question: question, answer: "", status: .running, createdAt: now, updatedAt: now)
        let record: SideQuestion
        if let topicID, var existing = rt.sideQuestions.first(where: { $0.id == topicID }) {
            existing.followUps.append(exchange)
            record = existing
        } else {
            record = SideQuestion(id: topicID ?? UUID().uuidString, first: exchange)
        }
        upsertSideQuestion(record, threadID: threadID)

        let selection = environment.drivers[thread.modelSelection.provider] != nil
            ? thread.modelSelection
            : settings.textGenerationModel
        guard let driver = environment.drivers[selection.provider] else {
            var failed = record
            failed.latest.status = .failed
            failed.latest.error = "No provider driver is available to answer this side question."
            failed.latest.updatedAt = environment.now()
            upsertSideQuestion(failed, threadID: threadID)
            return record.id
        }

        let prompt = Self.fallbackSideQuestionPrompt(thread: thread, topic: record, question: question)
        let cwd = workingDirectory(for: thread)
        let topicKey = record.id

        rt.sideQuestionTask = runtime.track { [self] in
            defer {
                if runtime.existingThread(threadID)?.sideQuestionTask != nil {
                    runtime.existingThread(threadID)?.sideQuestionTask = nil
                }
            }
            do {
                let json = try await driver.generateJSON(
                    prompt: prompt,
                    schema: CrossProviderWorkflows.sideQuestionResponseSchema,
                    model: selection.model,
                    cwd: cwd
                )
                guard !Task.isCancelled else { return }
                let answer = json["answer"]?.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                updateSideQuestionLatest(threadID: threadID, topicID: topicKey) { latest in
                    latest.answer = answer.isEmpty ? "(No answer returned.)" : answer
                    latest.status = .complete
                    latest.updatedAt = environment.now()
                }
            } catch is CancellationError {
                updateSideQuestionLatest(threadID: threadID, topicID: topicKey) { latest in
                    latest.status = .interrupted
                    latest.updatedAt = environment.now()
                }
            } catch {
                updateSideQuestionLatest(threadID: threadID, topicID: topicKey) { latest in
                    latest.status = .failed
                    latest.error = Self.describe(error)
                    latest.updatedAt = environment.now()
                }
            }
        }
        return record.id
    }

    private func updateSideQuestionLatest(
        threadID: String,
        topicID: String,
        mutate: (inout SideQuestionExchange) -> Void
    ) {
        guard let rt = runtime.existingThread(threadID),
              let index = rt.sideQuestions.firstIndex(where: { $0.id == topicID }) else { return }
        mutate(&rt.sideQuestions[index].latest)
        savePersistedSideQuestions(rt.sideQuestions, threadID: threadID)
        emit(.sideQuestionsChanged(threadID: threadID))
    }

    private static func fallbackSideQuestionPrompt(thread: AgentThread, topic: SideQuestion, question: String) -> String {
        var historyLines: [String] = []
        for turn in thread.turns.suffix(6) {
            historyLines.append("User: \(turn.userMessage.text.prefix(800))")
            let answer = turn.items.compactMap { item -> String? in
                if case let .assistantMessage(text, isFinal) = item.kind, isFinal { return text }
                return nil
            }.last ?? ""
            if !answer.isEmpty {
                historyLines.append("Assistant: \(answer.prefix(1500))")
            }
        }
        var topicLines: [String] = []
        let priorExchanges = [topic.first] + topic.followUps.dropLast()
        for exchange in priorExchanges where !exchange.answer.isEmpty {
            topicLines.append("Side Q: \(exchange.question)")
            topicLines.append("Side A: \(exchange.answer)")
        }
        return """
        Answer this side question (/btw) about the ongoing conversation below. Be concise, direct, and accurate.
        Return ONLY a JSON object: {"answer": "your markdown answer"}

        Thread title: \(thread.title)

        Recent conversation:
        \(historyLines.joined(separator: "\n"))
        \(topicLines.isEmpty ? "" : "\nPrevious side-question exchanges:\n" + topicLines.joined(separator: "\n"))

        Side question:
        \(question)
        """
    }

    // MARK: Persistence

    private func sideQuestionsURL(_ threadID: String) -> URL {
        environment.dataDirectory
            .appendingPathComponent("side-questions", isDirectory: true)
            .appendingPathComponent("\(threadID).json")
    }

    private func loadPersistedSideQuestions(_ threadID: String) -> [SideQuestion] {
        let url = sideQuestionsURL(threadID)
        guard let data = try? Data(contentsOf: url),
              var decoded = try? JSONDecoder().decode([SideQuestion].self, from: data)
        else { return [] }
        // Any question that was still running when the app last quit becomes interrupted on reload.
        for index in decoded.indices where decoded[index].isRunning {
            decoded[index].latest.status = .interrupted
        }
        return decoded
    }

    private func savePersistedSideQuestions(_ records: [SideQuestion], threadID: String) {
        let url = sideQuestionsURL(threadID)
        if records.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            // Side-question persistence is best-effort.
        }
    }

    func removePersistedSideQuestions(_ threadID: String) {
        try? FileManager.default.removeItem(at: sideQuestionsURL(threadID))
    }

    // MARK: Event folding

    /// `ProviderEvent.sideQuestion`: the topic as the provider has it now.
    func upsertSideQuestion(_ record: SideQuestion, threadID: String) {
        let rt = runtime.thread(threadID)
        if let index = rt.sideQuestions.firstIndex(where: { $0.id == record.id }) {
            guard rt.sideQuestions[index] != record else { return }
            rt.sideQuestions[index] = record
        } else {
            rt.sideQuestions = Self.newestFirst(rt.sideQuestions + [record])
        }
        savePersistedSideQuestions(rt.sideQuestions, threadID: threadID)
        emit(.sideQuestionsChanged(threadID: threadID))
    }

    /// `ProviderEvent.sideQuestionDelta`: streamed answer text of a running topic.
    func appendSideQuestionAnswer(_ id: String, delta: String, threadID: String) {
        guard let rt = runtime.existingThread(threadID),
              let index = rt.sideQuestions.firstIndex(where: { $0.id == id }),
              rt.sideQuestions[index].isRunning else { return }
        rt.sideQuestions[index].latest.answer += delta
        emit(.sideQuestionsChanged(threadID: threadID))
    }

    /// The session ended: a side question still running went with it.
    func interruptSideQuestions(_ threadID: String) {
        guard let rt = runtime.existingThread(threadID), rt.sideQuestions.contains(where: \.isRunning) else { return }
        let now = environment.now()
        for index in rt.sideQuestions.indices where rt.sideQuestions[index].isRunning {
            rt.sideQuestions[index].latest.status = .interrupted
            rt.sideQuestions[index].latest.updatedAt = now
        }
        savePersistedSideQuestions(rt.sideQuestions, threadID: threadID)
        emit(.sideQuestionsChanged(threadID: threadID))
    }

    /// The conversation became another one (a rewind forked or restarted it): its history is
    /// read again when asked for.
    func forgetSideQuestions(_ threadID: String) {
        removePersistedSideQuestions(threadID)
        guard let rt = runtime.existingThread(threadID), rt.sideQuestionsLoaded || !rt.sideQuestions.isEmpty else { return }
        rt.sideQuestionTask?.cancel()
        rt.sideQuestionTask = nil
        rt.sideQuestions = []
        rt.sideQuestionsLoaded = false
        emit(.sideQuestionsChanged(threadID: threadID))
    }

    private static func newestFirst(_ records: [SideQuestion]) -> [SideQuestion] {
        records.sorted { $0.first.createdAt > $1.first.createdAt }
    }
}
