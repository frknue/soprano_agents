import Foundation

/// Translates `codex app-server` v2 notifications and server requests into `ProviderEvent`s.
///
/// No I/O. Handles streaming deltas (`item/agentMessage/delta`, `item/plan/delta`,
/// `item/reasoning/*`, `item/commandExecution/outputDelta`), item lifecycle (`item/started`,
/// `item/completed`), plans (`turn/plan/updated`), token usage (`thread/tokenUsage/updated`),
/// compaction (`thread/compacted`, `contextCompaction`), turn completion (`turn/completed`),
/// and server requests (command approval, file-change approval, structured user input).
public struct CodexEventMapper: Sendable {
    public var cwd: String?
    private var texts: [String: String] = [:]
    private var lastText: (id: String, text: String)?
    private var startedAt: [String: Date] = [:]
    private var noticeCount = 0
    private var planStarted: Date?

    public init(cwd: String? = nil) {
        self.cwd = cwd
    }

    /// Resets per-turn tracking for the next turn.
    public mutating func resetTurn() {
        texts.removeAll()
        lastText = nil
        startedAt.removeAll()
        planStarted = nil
    }

    // MARK: - Notifications

    public mutating func notification(method: String, params: JSONValue, now: Date = Date()) -> [ProviderEvent] {
        switch method {
        case "turn/started":
            let turnID = params["turn"]?["id"]?.nonEmptyString
            return [.turnStarted(providerTurnID: turnID)]

        case "item/agentMessage/delta", "item/plan/delta":
            guard let itemID = params["itemId"]?.nonEmptyString,
                  let delta = params["delta"]?.stringValue, !delta.isEmpty else { return [] }
            let text = texts[itemID, default: ""] + delta
            texts[itemID] = text
            lastText = (itemID, text)
            return [.assistantDelta(itemID: itemID, delta: delta, isFinal: false)]

        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            guard let itemID = params["itemId"]?.nonEmptyString,
                  let delta = params["delta"]?.stringValue, !delta.isEmpty else { return [] }
            return [.reasoningDelta(itemID: itemID, delta: delta)]

        case "item/commandExecution/outputDelta":
            guard let itemID = params["itemId"]?.nonEmptyString,
                  let delta = params["delta"]?.stringValue, !delta.isEmpty else { return [] }
            return [.commandOutputDelta(itemID: itemID, delta: delta)]

        case "item/started":
            guard let item = params["item"], item.objectValue != nil else { return [] }
            return mapItem(item, completed: false, now: now)

        case "item/completed":
            guard let item = params["item"], item.objectValue != nil else { return [] }
            return mapItem(item, completed: true, now: now)

        case "turn/plan/updated":
            let steps = (params["plan"]?.arrayValue ?? []).compactMap { step -> String? in
                guard let label = step["step"]?.nonEmptyString else { return nil }
                let mark = switch step["status"]?.stringValue {
                case "completed": "[x]"
                case "inProgress": "[~]"
                default: "[ ]"
                }
                return "\(mark) \(label)"
            }
            guard !steps.isEmpty else { return [] }
            let started = planStarted ?? now
            planStarted = started
            var output = steps.joined(separator: "\n")
            if let explanation = params["explanation"]?.nonEmptyString {
                output = "\(explanation)\n\n\(output)"
            }
            let turnID = params["turnId"]?.nonEmptyString ?? "plan"
            let call = ToolCall(name: "plan", category: .other, title: "Updated the plan", output: output)
            return [.itemUpdated(TurnItem(id: "plan:\(turnID)", kind: .toolCall(call), status: .completed, startedAt: started, completedAt: now))]

        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"], usage.objectValue != nil else { return [] }
            let lastTotal = usage["last"]?["totalTokens"]?.intValue
            let total = usage["total"]?["totalTokens"]?.intValue
            guard let used = lastTotal ?? total, used > 0 else { return [] }
            return [.tokenUsage(TokenUsage(usedTokens: used, contextWindow: usage["modelContextWindow"]?.intValue))]

        case "thread/compacted":
            return [notice("Context compacted", now: now)]

        case "serverRequest/resolved":
            guard let requestID = params["requestId"], requestID != .null else { return [] }
            return [.requestResolved(id: CodexProtocol.requestIDString(requestID))]

        case "error":
            let message = params["error"]?["message"]?.nonEmptyString ?? "Codex encountered an error."
            if params["willRetry"]?.boolValue == true {
                return [notice("Retrying: \(message)", now: now)]
            }
            noticeCount += 1
            return [.itemUpdated(TurnItem(id: "codex-error:\(noticeCount)", kind: .error(message: message), status: .failed, startedAt: now, completedAt: now))]

        case "warning", "configWarning":
            guard let message = params["message"]?.nonEmptyString ?? params["summary"]?.nonEmptyString else { return [] }
            return [notice(message, now: now)]

        case "turn/completed":
            return mapTurnCompleted(params, now: now)

        default:
            return []
        }
    }

    // MARK: - Server requests

    public mutating func serverRequest(id: String, method: String, params: JSONValue, now: Date = Date()) -> [ProviderEvent] {
        switch method {
        case "item/commandExecution/requestApproval":
            let detail = params["command"]?.nonEmptyString
                ?? commandActionSummary(params["commandActions"])
                ?? "Run shell command"
            let reason = params["reason"]?.nonEmptyString
            return [.approvalRequested(ApprovalRequest(
                id: id,
                kind: .command,
                detail: detail,
                reason: reason,
                options: [.cancel, .decline, .acceptForSession, .accept]
            ))]

        case "item/fileChange/requestApproval":
            let detail = params["grantRoot"]?.nonEmptyString.map { relative($0) }
                ?? params["reason"]?.nonEmptyString
                ?? "Apply file changes"
            let reason = params["grantRoot"]?.nonEmptyString != nil ? params["reason"]?.nonEmptyString : nil
            return [.approvalRequested(ApprovalRequest(
                id: id,
                kind: .fileChange,
                detail: detail,
                reason: reason,
                options: [.cancel, .decline, .acceptForSession, .accept]
            ))]

        case "item/tool/requestUserInput":
            let rawQuestions = params["questions"]?.arrayValue ?? []
            let questions: [UserInputQuestion] = rawQuestions.enumerated().map { index, entry in
                let qid = entry["id"]?.nonEmptyString ?? "q\(index + 1)"
                let header = entry["header"]?.nonEmptyString ?? "Question"
                let text = entry["question"]?.nonEmptyString ?? header
                let options = (entry["options"]?.arrayValue ?? []).compactMap { opt -> UserInputOption? in
                    guard let label = opt["label"]?.nonEmptyString else { return nil }
                    return UserInputOption(label: label, description: opt["description"]?.nonEmptyString)
                }
                let allowsOther = entry["isOther"]?.boolValue ?? options.isEmpty
                return UserInputQuestion(
                    id: qid,
                    header: header,
                    question: text,
                    options: options,
                    allowsMultiple: false,
                    allowsOther: allowsOther
                )
            }
            guard !questions.isEmpty else { return [] }
            return [.userInputRequested(UserInputRequest(id: id, questions: questions))]

        default:
            return []
        }
    }

    // MARK: - Item mapping

    private mutating func mapItem(_ item: JSONValue, completed: Bool, now: Date) -> [ProviderEvent] {
        guard let type = item["type"]?.stringValue,
              let id = item["id"]?.nonEmptyString else { return [] }
        let start = startedAt[id] ?? now
        if startedAt[id] == nil { startedAt[id] = start }
        let end: Date? = completed ? now : nil

        switch type {
        case "agentMessage":
            let text = item["text"]?.stringValue ?? texts[id] ?? ""
            if !text.isEmpty {
                texts[id] = text
                lastText = (id, text)
            }
            guard completed || !text.isEmpty else { return [] }
            let isFinal = completed && item["phase"]?.stringValue == "final_answer"
            return [.itemUpdated(TurnItem(id: id, kind: .assistantMessage(text: text, isFinal: isFinal), status: completed ? .completed : .running, startedAt: start, completedAt: end))]

        case "plan":
            let text = item["text"]?.stringValue ?? texts[id] ?? ""
            if !text.isEmpty {
                texts[id] = text
                lastText = (id, text)
            }
            guard !text.isEmpty else { return [] }
            return [.itemUpdated(TurnItem(id: id, kind: .assistantMessage(text: text, isFinal: false), status: completed ? .completed : .running, startedAt: start, completedAt: end))]

        case "reasoning":
            let summary = (item["summary"]?.arrayValue ?? []).compactMap(\.nonEmptyString).joined(separator: "\n\n")
            let content = (item["content"]?.arrayValue ?? []).compactMap(\.nonEmptyString).joined(separator: "\n\n")
            let text = !summary.isEmpty ? summary : content
            guard !text.isEmpty else { return [] }
            return [.itemUpdated(TurnItem(id: id, kind: .reasoning(text: text), status: completed ? .completed : .running, startedAt: start, completedAt: end))]

        case "commandExecution":
            let status = itemStatus(item["status"]?.stringValue, completed: completed)
            let command = CommandExecution(
                command: item["command"]?.stringValue ?? "",
                cwd: item["cwd"]?.nonEmptyString,
                output: item["aggregatedOutput"]?.stringValue ?? "",
                exitCode: item["exitCode"]?.intValue,
                durationMs: item["durationMs"]?.intValue
            )
            return [.itemUpdated(TurnItem(id: id, kind: .command(command), status: status, startedAt: start, completedAt: status.isActive ? nil : now))]

        case "fileChange":
            let status = itemStatus(item["status"]?.stringValue, completed: completed)
            let changes: [FileChange] = (item["changes"]?.arrayValue ?? []).compactMap { entry in
                guard let rawPath = entry["path"]?.nonEmptyString else { return nil }
                let kindObj = entry["kind"]
                let movePath = kindObj?["move_path"]?.nonEmptyString.map { relative($0) }
                let kind: FileChange.Kind = switch kindObj?["type"]?.stringValue {
                case "add": .add
                case "delete": .delete
                default: movePath == nil ? .update : .move
                }
                let diff = entry["diff"]?.nonEmptyString
                return FileChange(path: relative(rawPath), kind: kind, movePath: movePath, diff: diff)
            }
            return [.itemUpdated(TurnItem(id: id, kind: .fileChange(changes), status: status, startedAt: start, completedAt: status.isActive ? nil : now))]

        case "mcpToolCall":
            let status = itemStatus(item["status"]?.stringValue, completed: completed)
            let server = item["server"]?.nonEmptyString ?? "mcp"
            let tool = item["tool"]?.nonEmptyString ?? "tool"
            let input = prettyInput(item["arguments"])
            let output = mcpOutput(result: item["result"], error: item["error"])
            let call = ToolCall(name: "\(server)/\(tool)", category: .other, title: "\(server): \(tool)", input: input, output: output)
            return [.itemUpdated(TurnItem(id: id, kind: .toolCall(call), status: status, startedAt: start, completedAt: status.isActive ? nil : now))]

        case "dynamicToolCall":
            let status = itemStatus(item["status"]?.stringValue, completed: completed)
            let tool = item["tool"]?.nonEmptyString ?? "tool"
            let input = prettyInput(item["arguments"])
            let output = dynamicOutput(item["contentItems"])
            let call = ToolCall(name: tool, category: .other, title: tool, input: input, output: output)
            return [.itemUpdated(TurnItem(id: id, kind: .toolCall(call), status: status, startedAt: start, completedAt: status.isActive ? nil : now))]

        case "collabAgentToolCall":
            let status = itemStatus(item["status"]?.stringValue, completed: completed)
            let tool = item["tool"]?.nonEmptyString ?? "subagent"
            let title = switch tool {
            case "spawnAgent": "Spawn subagent"
            case "sendInput": "Message subagent"
            case "resumeAgent": "Resume subagent"
            case "wait": "Wait for subagent"
            case "closeAgent": "Close subagent"
            default: "Subagent: \(tool)"
            }
            let input = item["prompt"]?.nonEmptyString
            let states = item["agentsStates"]?.objectValue ?? [:]
            let summary = states.keys.sorted().compactMap { agentID -> String? in
                guard let state = states[agentID] else { return nil }
                let st = state["status"]?.stringValue ?? ""
                let msg = state["message"]?.nonEmptyString
                return msg.map { "\(agentID) (\(st)): \($0)" } ?? "\(agentID): \(st)"
            }.joined(separator: "\n")
            let call = ToolCall(name: tool, category: .subagent, title: title, input: input, output: summary.isEmpty ? nil : summary)
            return [.itemUpdated(TurnItem(id: id, kind: .toolCall(call), status: status, startedAt: start, completedAt: status.isActive ? nil : now))]

        case "webSearch":
            let query = item["query"]?.stringValue ?? ""
            return [.itemUpdated(TurnItem(id: id, kind: .webSearch(query: query), status: completed ? .completed : .running, startedAt: start, completedAt: end))]

        case "imageView":
            let path = item["path"]?.nonEmptyString.map { relative($0) } ?? "image"
            let call = ToolCall(name: "image_view", category: .read, title: "Viewed \(path)")
            return [.itemUpdated(TurnItem(id: id, kind: .toolCall(call), status: completed ? .completed : .running, startedAt: start, completedAt: end))]

        case "contextCompaction":
            guard completed else { return [] }
            return [notice("Context compacted", id: id, now: now)]

        case "enteredReviewMode":
            let review = item["review"]?.nonEmptyString ?? "Review started"
            return [notice(review, id: id, now: now)]

        case "exitedReviewMode":
            let review = item["review"]?.nonEmptyString ?? "Review completed"
            return [notice(review, id: id, now: now)]

        default:
            return []
        }
    }

    private mutating func mapTurnCompleted(_ params: JSONValue, now: Date) -> [ProviderEvent] {
        let turn = params["turn"] ?? .null
        let status = turn["status"]?.stringValue
        let outcome: ProviderTurnOutcome
        var error: String?
        switch status {
        case "completed", nil:
            outcome = .completed
        case "interrupted":
            outcome = .interrupted
        case "failed":
            outcome = .failed
            error = turn["error"]?["message"]?.nonEmptyString
                ?? turn["error"]?["additionalDetails"]?.nonEmptyString
                ?? "Codex ended the turn with an error."
        default:
            outcome = .completed
        }
        var events: [ProviderEvent] = []
        if let last = lastText, !last.text.isEmpty {
            events.append(.itemUpdated(TurnItem(id: last.id, kind: .assistantMessage(text: last.text, isFinal: true), status: .completed, startedAt: startedAt[last.id] ?? now, completedAt: now)))
        }
        events.append(.turnCompleted(outcome: outcome, error: error))
        resetTurn()
        return events
    }

    // MARK: - Helpers

    private func itemStatus(_ raw: String?, completed: Bool) -> TurnItemStatus {
        switch raw {
        case "completed": .completed
        case "failed": .failed
        case "declined": .declined
        case "inProgress": completed ? .completed : .running
        default: completed ? .completed : .running
        }
    }

    private func relative(_ path: String) -> String {
        OmpEventMapper.relative(path, to: cwd)
    }

    private mutating func notice(_ text: String, id: String? = nil, now: Date = Date()) -> ProviderEvent {
        noticeCount += 1
        return .itemUpdated(TurnItem(id: id ?? "codex-notice:\(noticeCount)", kind: .notice(text: text), status: .completed, startedAt: now, completedAt: now))
    }

    private func prettyInput(_ value: JSONValue?) -> String? {
        guard let value, value != .null else { return nil }
        if case let .object(object) = value, object.isEmpty { return nil }
        return value.prettyJSONString()
    }

    private func mcpOutput(result: JSONValue?, error: JSONValue?) -> String? {
        if let message = error?["message"]?.nonEmptyString { return message }
        guard let result, result != .null else { return nil }
        let blocks = (result["content"]?.arrayValue ?? []).compactMap { block -> String? in
            block["text"]?.nonEmptyString
        }
        if !blocks.isEmpty { return blocks.joined(separator: "\n") }
        if let structured = result["structuredContent"], structured != .null {
            return structured.prettyJSONString()
        }
        return nil
    }

    private func dynamicOutput(_ contentItems: JSONValue?) -> String? {
        let texts = (contentItems?.arrayValue ?? []).compactMap { item -> String? in
            item["text"]?.nonEmptyString
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private func commandActionSummary(_ actions: JSONValue?) -> String? {
        (actions?.arrayValue ?? []).compactMap { $0["command"]?.nonEmptyString }.first
    }
}
