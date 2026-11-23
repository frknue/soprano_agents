import Foundation

// Cross-provider workflows (`/review-with`, opt-in post-turn Advisor, opt-in Auto-recap) and
// unified multi-provider usage ledger recording.

extension AgentEngine {
    /// Runs `/review-with <provider>[/<model>] [focus]` against the thread's latest changes and
    /// appends the findings as an `.advisory` card on the thread's latest turn.
    func runManualReview(_ threadID: String, request: CrossProviderWorkflows.ReviewRequest) async throws {
        guard let thread = thread(threadID) else { throw EngineError.unknownThread(threadID) }
        guard let targetTurn = thread.turns.last else {
            throw EngineError.message("Send at least one turn before running /review-with.")
        }
        guard let driver = environment.drivers[request.selection.provider] else {
            throw EngineError.providerUnavailable(request.selection.provider, "No driver is configured.")
        }
        let cwd = workingDirectory(for: thread)
        let diff = (try? await turnDiff(threadID, turnOrdinal: nil)) ?? ""
        let summary = Self.turnSummaryText(targetTurn)
        let prompt = CrossProviderWorkflows.reviewPrompt(
            diff: diff,
            summary: summary,
            instructions: request.instructions,
            criteria: settings.workflows.advisorPrompt
        )
        let advisorLabel = Self.reviewLabel(request.selection)
        let itemID = "review-\(UUID().uuidString)"
        let now = environment.now()
        mutateTurn(threadID, targetTurn.id) { turn in
            turn.items.append(TurnItem(
                id: itemID,
                kind: .notice(text: "Reviewing with \(advisorLabel)…"),
                status: .running,
                startedAt: now
            ))
        }

        runtime.track { [self] in
            do {
                let json = try await driver.generateJSON(
                    prompt: prompt,
                    schema: CrossProviderWorkflows.reviewResponseSchema,
                    model: request.selection.model,
                    cwd: cwd
                )
                let notes = CrossProviderWorkflows.parseAdvisorNotes(from: json, advisorLabel: advisorLabel)
                let finalNotes = notes.isEmpty
                    ? [AdvisorNote(text: "No issues flagged.", severity: .nit, advisor: advisorLabel)]
                    : notes
                replaceAdvisoryPlaceholder(threadID: threadID, turnID: targetTurn.id, itemID: itemID, kind: .advisory(finalNotes), status: .completed)
            } catch {
                replaceAdvisoryPlaceholder(
                    threadID: threadID,
                    turnID: targetTurn.id,
                    itemID: itemID,
                    kind: .error(message: "Review with \(advisorLabel) failed: \(Self.describe(error))"),
                    status: .failed
                )
            }
        }
    }

    /// Runs opt-in post-turn workflows (Advisor review and Auto-recap) once a completed turn's
    /// checkpoint has been captured. Never runs on teammates or turns without changed files.
    func runPostTurnWorkflows(threadID: String, turnID: String) async {
        let workflows = settings.workflows
        guard workflows.advisorEnabled || workflows.autoRecapEnabled else { return }
        guard let thread = thread(threadID),
              thread.teammate == nil,
              let turn = thread.turns.first(where: { $0.id == turnID }),
              turn.status == .completed
        else { return }

        let changedFiles = turn.checkpoint?.files.map(\.path) ?? []
        guard !changedFiles.isEmpty else { return }
        let cwd = workingDirectory(for: thread)

        if workflows.advisorEnabled {
            let provider = workflows.advisorProvider ?? settings.textGenerationModel.provider
            let model = workflows.advisorModel ?? (provider == settings.textGenerationModel.provider ? settings.textGenerationModel.model : ModelSelection.configuredDefaultModel)
            let selection = ModelSelection(provider: provider, model: model)
            if let driver = environment.drivers[provider] {
                let diff = (try? await turnDiff(threadID, turnOrdinal: turn.ordinal)) ?? ""
                let prompt = CrossProviderWorkflows.reviewPrompt(
                    diff: diff,
                    summary: Self.turnSummaryText(turn),
                    instructions: "",
                    criteria: workflows.advisorPrompt
                )
                let label = "Advisor · \(Self.reviewLabel(selection))"
                if let json = try? await driver.generateJSON(
                    prompt: prompt,
                    schema: CrossProviderWorkflows.reviewResponseSchema,
                    model: selection.model,
                    cwd: cwd
                ) {
                    let notes = CrossProviderWorkflows.parseAdvisorNotes(from: json, advisorLabel: label)
                    if !notes.isEmpty {
                        let now = environment.now()
                        mutateTurn(threadID, turnID) { turn in
                            turn.items.append(TurnItem(
                                id: "advisor-\(UUID().uuidString)",
                                kind: .advisory(notes),
                                status: .completed,
                                startedAt: now,
                                completedAt: now
                            ))
                        }
                    }
                }
            }
        }

        if workflows.autoRecapEnabled {
            let selection = settings.textGenerationModel
            if let driver = environment.drivers[selection.provider] {
                let prompt = CrossProviderWorkflows.recapPrompt(
                    userMessage: turn.userMessage.text,
                    answer: Self.turnSummaryText(turn),
                    changedFiles: changedFiles
                )
                if let json = try? await driver.generateJSON(
                    prompt: prompt,
                    schema: CrossProviderWorkflows.recapResponseSchema,
                    model: selection.model,
                    cwd: cwd
                ),
                   let recap = json["recap"]?.stringValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                   !recap.isEmpty {
                    let now = environment.now()
                    mutateTurn(threadID, turnID) { turn in
                        turn.items.append(TurnItem(
                            id: "recap-\(UUID().uuidString)",
                            kind: .advisory([AdvisorNote(text: recap, severity: .nit, advisor: "Recap")]),
                            status: .completed,
                            startedAt: now,
                            completedAt: now
                        ))
                    }
                }
            }
        }
    }

    /// Records a finished turn into `environment.usageLedger` for unified multi-provider usage
    /// statistics across all 5 providers.
    func recordTurnUsage(threadID: String, turnID: String, status: TurnStatus) {
        guard let ledger = environment.usageLedger,
              let thread = thread(threadID),
              let turn = thread.turns.first(where: { $0.id == turnID })
        else { return }
        let usage = turn.tokenUsage
        guard usage != nil || status == .failed else { return }

        let cwd = workingDirectory(for: thread)
        let folder = UsageFolderName.encode(
            cwd,
            home: environment.resourceHome ?? NSHomeDirectory(),
            temporaryDirectory: NSTemporaryDirectory()
        )
        let entry = LocalUsageLedger.Entry(
            timestamp: turn.completedAt ?? environment.now(),
            provider: turn.modelSelection.provider.rawValue,
            model: turn.modelSelection.model,
            agent: thread.teammate != nil ? "teammate" : "main",
            folder: folder,
            inputTokens: usage?.usedTokens ?? 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            costUSD: nil,
            failed: status == .failed
        )
        ledger.record(entry)
    }

    private func replaceAdvisoryPlaceholder(
        threadID: String,
        turnID: String,
        itemID: String,
        kind: TurnItemKind,
        status: TurnItemStatus
    ) {
        let now = environment.now()
        mutateTurn(threadID, turnID) { turn in
            if let index = turn.items.firstIndex(where: { $0.id == itemID }) {
                turn.items[index].kind = kind
                turn.items[index].status = status
                turn.items[index].completedAt = now
            } else {
                turn.items.append(TurnItem(id: itemID, kind: kind, status: status, startedAt: now, completedAt: now))
            }
        }
    }

    private static func reviewLabel(_ selection: ModelSelection) -> String {
        if selection.model == ModelSelection.configuredDefaultModel {
            return selection.provider.displayName
        }
        return "\(selection.provider.displayName) (\(selection.model))"
    }

    private static func turnSummaryText(_ turn: Turn) -> String {
        turn.items.compactMap { item -> String? in
            if case let .assistantMessage(text, isFinal) = item.kind, isFinal { return text }
            return nil
        }.last ?? ""
    }
}
