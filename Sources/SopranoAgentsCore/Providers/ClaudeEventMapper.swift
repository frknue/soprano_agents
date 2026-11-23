import Foundation

/// Translates Claude Code's NDJSON `stream-json` frames into normalized `ProviderEvent`s.
///
/// No I/O. Handles:
/// - `stream_event` (`message_start`, `content_block_start`, `content_block_delta`, `message_delta`)
///   for live text & thinking streaming.
/// - `assistant` frames (text, thinking, `tool_use` blocks: `Bash`, `Edit`/`MultiEdit`/`Write`,
///   `Read`, `Grep`/`Glob`, `WebSearch`, `Task`/`Agent` subagents, `TodoWrite`, MCP tools).
/// - `user` frames (`tool_result` blocks matching `tool_use_id` to settle commands/edits/tools and
///   close subagent runs).
/// - Subagent frames carrying `parent_tool_use_id` routed to `ProviderEvent.subagent`.
/// - `control_request` (`can_use_tool`): `AskUserQuestion` → `userInputRequested`; everything else
///   → `approvalRequested`.
/// - `system` (`init`, `commands_changed`, `compact_boundary`) and `result` (usage + completion).
public struct ClaudeEventMapper: Sendable {
    private struct ToolState: Sendable {
        var name: String
        var input: JSONValue
        var startedAt: Date
        var isSubagent: Bool
    }

    private struct StreamBlock: Sendable {
        var itemID: String
        var kind: String
    }

    public var cwd: String?
    public var contextWindow: Int?
    private var messageCounter = 0
    private var currentMessageID: String?
    private var streamBlocks: [Int: StreamBlock] = [:]
    private var texts: [String: String] = [:]
    private var lastText: (id: String, text: String)?
    private var tools: [String: ToolState] = [:]
    private var subagentTools: [String: [String: ToolState]] = [:]
    private var declinedTools: Set<String> = []
    private var noticeCount = 0

    public init(cwd: String? = nil) {
        self.cwd = cwd
    }

    public mutating func resetTurn() {
        currentMessageID = nil
        streamBlocks.removeAll()
        texts.removeAll()
        lastText = nil
        tools.removeAll()
        subagentTools.removeAll()
        declinedTools.removeAll()
    }

    public mutating func markDeclined(toolUseID: String) {
        declinedTools.insert(toolUseID)
    }

    // MARK: - Top-level frame dispatch

    public mutating func map(_ frame: JSONValue, now: Date = Date()) -> [ProviderEvent] {
        switch frame["type"]?.stringValue {
        case "system":
            return mapSystem(frame, now: now)
        case "stream_event":
            return mapStreamEvent(frame, now: now)
        case "assistant":
            return mapAssistant(frame, now: now)
        case "user":
            return mapUser(frame, now: now)
        case "result":
            return mapResult(frame, now: now)
        default:
            return []
        }
    }

    /// Translates an incoming `control_request` (`can_use_tool`) into an approval or structured
    /// user-input event. Returns `(events, questionTextByID)` for `AskUserQuestion`.
    public mutating func mapControlRequest(
        id: String,
        request: JSONValue,
        now: Date = Date()
    ) -> (events: [ProviderEvent], questionTextByID: [String: String]) {
        guard request["subtype"]?.stringValue == "can_use_tool" else { return ([], [:]) }
        let toolName = request["tool_name"]?.nonEmptyString ?? "tool"
        let input = request["input"] ?? [:]

        if toolName == "AskUserQuestion" {
            let rawQuestions = input["questions"]?.arrayValue ?? []
            var textByID: [String: String] = [:]
            let questions: [UserInputQuestion] = rawQuestions.enumerated().map { index, entry in
                let qid = "q\(index + 1)"
                let header = entry["header"]?.nonEmptyString ?? "Question"
                let text = entry["question"]?.nonEmptyString ?? header
                textByID[qid] = text
                let options = (entry["options"]?.arrayValue ?? []).compactMap { opt -> UserInputOption? in
                    guard let label = opt["label"]?.nonEmptyString else { return nil }
                    return UserInputOption(label: label, description: opt["description"]?.nonEmptyString)
                }
                let multi = entry["multiSelect"]?.boolValue ?? false
                return UserInputQuestion(
                    id: qid,
                    header: header,
                    question: text,
                    options: options,
                    allowsMultiple: multi,
                    allowsOther: true
                )
            }
            guard !questions.isEmpty else { return ([], [:]) }
            return ([.userInputRequested(UserInputRequest(id: id, questions: questions))], textByID)
        }

        let approvalKind: ApprovalKind = switch toolName {
        case "Bash": .command
        case "Edit", "MultiEdit", "Write", "NotebookEdit": .fileChange
        case "Read", "Grep", "Glob": .fileRead
        default: .other
        }
        let detail = approvalDetail(toolName: toolName, input: input)
        let reason = request["decision_reason"]?.nonEmptyString ?? input["description"]?.nonEmptyString
        let hasSuggestions = !(request["permission_suggestions"]?.arrayValue ?? []).isEmpty
        let options: [ApprovalDecision] = hasSuggestions
            ? [.cancel, .decline, .acceptForSession, .accept]
            : [.cancel, .decline, .accept]
        return ([.approvalRequested(ApprovalRequest(id: id, kind: approvalKind, detail: detail, reason: reason, options: options))], [:])
    }

    // MARK: - System frames

    private mutating func mapSystem(_ frame: JSONValue, now: Date) -> [ProviderEvent] {
        switch frame["subtype"]?.stringValue {
        case "commands_changed":
            let commands = ClaudeProtocol.commands(from: frame["commands"])
            return commands.isEmpty ? [] : [.commands(commands)]
        case "compact_boundary":
            return [notice("Context compacted", now: now)]
        default:
            return []
        }
    }

    // MARK: - Partial stream events

    private mutating func mapStreamEvent(_ frame: JSONValue, now: Date) -> [ProviderEvent] {
        guard frame["parent_tool_use_id"]?.nonEmptyString == nil,
              let event = frame["event"] else { return [] }
        switch event["type"]?.stringValue {
        case "message_start":
            messageCounter += 1
            currentMessageID = event["message"]?["id"]?.nonEmptyString ?? "claude-msg-\(messageCounter)"
            streamBlocks.removeAll()
            if let usage = tokenUsage(from: event["message"]?["usage"]) {
                return [.tokenUsage(usage)]
            }
            return []

        case "content_block_start":
            guard let index = event["index"]?.intValue,
                  let block = event["content_block"],
                  let blockType = block["type"]?.stringValue else { return [] }
            let msgID = currentMessageID ?? "claude-msg-\(messageCounter)"
            let itemID = "\(msgID):\(index)"
            streamBlocks[index] = StreamBlock(itemID: itemID, kind: blockType)
            return []

        case "content_block_delta":
            guard let index = event["index"]?.intValue,
                  let block = streamBlocks[index],
                  let delta = event["delta"] else { return [] }
            switch delta["type"]?.stringValue {
            case "text_delta":
                guard let chunk = delta["text"]?.stringValue, !chunk.isEmpty else { return [] }
                let updated = texts[block.itemID, default: ""] + chunk
                texts[block.itemID] = updated
                lastText = (block.itemID, updated)
                return [.assistantDelta(itemID: block.itemID, delta: chunk, isFinal: false)]
            case "thinking_delta":
                guard let chunk = delta["thinking"]?.stringValue, !chunk.isEmpty else { return [] }
                return [.reasoningDelta(itemID: block.itemID, delta: chunk)]
            default:
                return []
            }

        case "content_block_stop":
            guard let index = event["index"]?.intValue else { return [] }
            streamBlocks.removeValue(forKey: index)
            return []

        default:
            return []
        }
    }

    // MARK: - Assistant & User (tool_result) frames

    private mutating func mapAssistant(_ frame: JSONValue, now: Date) -> [ProviderEvent] {
        guard let message = frame["message"],
              let content = message["content"]?.arrayValue else { return [] }
        let msgID = message["id"]?.nonEmptyString ?? currentMessageID ?? {
            messageCounter += 1
            return "claude-msg-\(messageCounter)"
        }()

        if let parentID = frame["parent_tool_use_id"]?.nonEmptyString {
            return mapSubagentAssistant(parentID: parentID, messageID: msgID, content: content, now: now)
        }

        var events: [ProviderEvent] = []
        if let usage = tokenUsage(from: message["usage"]) {
            events.append(.tokenUsage(usage))
        }

        for (index, block) in content.enumerated() {
            let itemID = "\(msgID):\(index)"
            switch block["type"]?.stringValue {
            case "text":
                guard let text = block["text"]?.stringValue, !text.isEmpty else { continue }
                texts[itemID] = text
                lastText = (itemID, text)
                let isFinal = message["stop_reason"]?.stringValue == "end_turn"
                events.append(.itemUpdated(TurnItem(id: itemID, kind: .assistantMessage(text: text, isFinal: isFinal), status: .completed, startedAt: now, completedAt: now)))

            case "thinking":
                guard let thinking = block["thinking"]?.nonEmptyString else { continue }
                events.append(.itemUpdated(TurnItem(id: itemID, kind: .reasoning(text: thinking), status: .completed, startedAt: now, completedAt: now)))

            case "tool_use":
                guard let toolID = block["id"]?.nonEmptyString,
                      let name = block["name"]?.nonEmptyString else { continue }
                let input = block["input"] ?? [:]
                let isSubagent = name == "Task" || name == "Agent"
                let state = ToolState(name: name, input: input, startedAt: now, isSubagent: isSubagent)
                tools[toolID] = state
                if let item = toolItem(id: toolID, state: state, status: .running, output: nil, now: now) {
                    events.append(.itemUpdated(item))
                }
                if isSubagent {
                    let subagentName = input["subagent_type"]?.nonEmptyString ?? input["name"]?.nonEmptyString ?? "Agent"
                    let desc = input["description"]?.nonEmptyString
                    let prompt = input["prompt"]?.nonEmptyString
                    let model = input["model"]?.nonEmptyString
                    events.append(.subagent(id: toolID, .updated(SubagentInfo(
                        agent: subagentName,
                        description: desc,
                        assignment: prompt,
                        status: .running,
                        model: model,
                        parentToolCallID: toolID
                    ))))
                    events.append(.subagent(id: toolID, .runStarted(message: prompt ?? desc)))
                }

            default:
                break
            }
        }
        return events
    }

    private mutating func mapUser(_ frame: JSONValue, now: Date) -> [ProviderEvent] {
        guard let content = frame["message"]?["content"]?.arrayValue else { return [] }
        if let parentID = frame["parent_tool_use_id"]?.nonEmptyString {
            return mapSubagentUser(parentID: parentID, content: content, now: now)
        }

        var events: [ProviderEvent] = []
        for block in content where block["type"]?.stringValue == "tool_result" {
            guard let toolID = block["tool_use_id"]?.nonEmptyString,
                  let state = tools[toolID] else { continue }
            let output = toolResultText(block["content"])
            let isError = block["is_error"]?.boolValue == true
            let status: TurnItemStatus = isError ? (declinedTools.contains(toolID) ? .declined : .failed) : .completed
            if let item = toolItem(id: toolID, state: state, status: status, output: output, now: now) {
                events.append(.itemUpdated(item))
            }
            if state.isSubagent {
                if let output, !output.isEmpty {
                    events.append(.subagent(id: toolID, .itemUpdated(TurnItem(id: "\(toolID):result", kind: .assistantMessage(text: output, isFinal: true), status: .completed, startedAt: now, completedAt: now))))
                }
                events.append(.subagent(id: toolID, .runEnded(outcome: isError ? .failed : .completed, error: isError ? output : nil)))
                events.append(.subagent(id: toolID, .updated(SubagentInfo(status: isError ? .failed : .completed))))
            }
        }
        return events
    }

    private mutating func mapSubagentAssistant(parentID: String, messageID: String, content: [JSONValue], now: Date) -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        for (index, block) in content.enumerated() {
            let itemID = "\(messageID):\(index)"
            switch block["type"]?.stringValue {
            case "text":
                guard let text = block["text"]?.nonEmptyString else { continue }
                events.append(.subagent(id: parentID, .itemUpdated(TurnItem(id: itemID, kind: .assistantMessage(text: text, isFinal: false), status: .completed, startedAt: now, completedAt: now))))
            case "thinking":
                guard let thinking = block["thinking"]?.nonEmptyString else { continue }
                events.append(.subagent(id: parentID, .itemUpdated(TurnItem(id: itemID, kind: .reasoning(text: thinking), status: .completed, startedAt: now, completedAt: now))))
            case "tool_use":
                guard let toolID = block["id"]?.nonEmptyString,
                      let name = block["name"]?.nonEmptyString else { continue }
                let state = ToolState(name: name, input: block["input"] ?? [:], startedAt: now, isSubagent: false)
                subagentTools[parentID, default: [:]][toolID] = state
                if let item = toolItem(id: toolID, state: state, status: .running, output: nil, now: now) {
                    events.append(.subagent(id: parentID, .itemUpdated(item)))
                }
            default:
                break
            }
        }
        return events
    }

    private mutating func mapSubagentUser(parentID: String, content: [JSONValue], now: Date) -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        for block in content where block["type"]?.stringValue == "tool_result" {
            guard let toolID = block["tool_use_id"]?.nonEmptyString,
                  let state = subagentTools[parentID]?[toolID] else { continue }
            let output = toolResultText(block["content"])
            let isError = block["is_error"]?.boolValue == true
            if let item = toolItem(id: toolID, state: state, status: isError ? .failed : .completed, output: output, now: now) {
                events.append(.subagent(id: parentID, .itemUpdated(item)))
            }
        }
        return events
    }

    // MARK: - Result frame

    private mutating func mapResult(_ frame: JSONValue, now: Date) -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        if let modelUsage = frame["modelUsage"]?.objectValue {
            for entry in modelUsage.values {
                if let window = entry["contextWindow"]?.intValue, window > 0 {
                    contextWindow = window
                    break
                }
            }
        }
        if let usage = tokenUsage(from: frame["usage"]) {
            events.append(.tokenUsage(usage))
        }

        let isError = frame["is_error"]?.boolValue == true
        let subtype = frame["subtype"]?.stringValue
        let outcome: ProviderTurnOutcome
        var errorMessage: String?
        if subtype == "error_during_execution" || subtype == "error_max_turns" || isError {
            let text = frame["errors"]?.arrayValue?.compactMap(\.nonEmptyString).joined(separator: "\n")
                ?? frame["result"]?.nonEmptyString
            if text?.lowercased().contains("interrupt") == true || text?.lowercased().contains("abort") == true {
                outcome = .interrupted
            } else {
                outcome = .failed
                errorMessage = text ?? "Claude Code ended the turn with an error."
            }
        } else {
            outcome = .completed
        }

        if let last = lastText, !last.text.isEmpty {
            events.append(.itemUpdated(TurnItem(id: last.id, kind: .assistantMessage(text: last.text, isFinal: true), status: .completed, startedAt: now, completedAt: now)))
        } else if outcome == .completed, let resultText = frame["result"]?.nonEmptyString {
            messageCounter += 1
            events.append(.itemUpdated(TurnItem(id: "claude-result-\(messageCounter)", kind: .assistantMessage(text: resultText, isFinal: true), status: .completed, startedAt: now, completedAt: now)))
        }
        events.append(.turnCompleted(outcome: outcome, error: errorMessage))
        resetTurn()
        return events
    }

    // MARK: - Tool item helpers

    private func toolItem(id: String, state: ToolState, status: TurnItemStatus, output: String?, now: Date) -> TurnItem? {
        let input = state.input
        let completedAt: Date? = status.isActive ? nil : now
        func wrap(_ kind: TurnItemKind) -> TurnItem {
            TurnItem(id: id, kind: kind, status: status, startedAt: state.startedAt, completedAt: completedAt)
        }

        switch state.name {
        case "AskUserQuestion":
            return nil
        case "Bash":
            let command = input["command"]?.stringValue ?? ""
            let exitCode: Int? = status == .completed ? 0 : (status == .failed ? 1 : nil)
            return wrap(.command(CommandExecution(command: command, cwd: cwd, output: output ?? "", exitCode: exitCode)))
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return wrap(.fileChange(fileChanges(toolName: state.name, input: input)))
        case "Read":
            let path = input["file_path"]?.nonEmptyString.map { relative($0) } ?? "a file"
            return wrap(.toolCall(ToolCall(name: state.name, category: .read, title: "Read \(path)", input: prettyInput(input), output: output)))
        case "Grep", "Glob":
            let pattern = input["pattern"]?.nonEmptyString
            let path = input["path"]?.nonEmptyString.map { relative($0) }
            let title: String = if let pattern, let path {
                "Searched \(pattern) in \(path)"
            } else if let pattern {
                "Searched \(pattern)"
            } else {
                "Searched \(path ?? ".")"
            }
            return wrap(.toolCall(ToolCall(name: state.name, category: .search, title: title, input: prettyInput(input), output: output)))
        case "WebSearch":
            return wrap(.webSearch(query: input["query"]?.stringValue ?? ""))
        case "Task", "Agent":
            let label = input["description"]?.nonEmptyString ?? input["subagent_type"]?.nonEmptyString ?? "Subagent"
            return wrap(.toolCall(ToolCall(name: state.name, category: .subagent, title: "Subagent: \(label)", input: input["prompt"]?.nonEmptyString ?? prettyInput(input), output: output)))
        case "TodoWrite":
            return wrap(.toolCall(ToolCall(name: state.name, category: .other, title: "Updated tasks", input: prettyInput(input), output: output)))
        default:
            let title = input["description"]?.nonEmptyString ?? state.name
            return wrap(.toolCall(ToolCall(name: state.name, category: .other, title: title, input: prettyInput(input), output: output)))
        }
    }

    private func fileChanges(toolName: String, input: JSONValue) -> [FileChange] {
        let rawPath = input["file_path"]?.nonEmptyString ?? input["notebook_path"]?.nonEmptyString ?? ""
        let path = relative(rawPath)
        if toolName == "Write" {
            let content = input["content"]?.stringValue ?? ""
            let diff = content.isEmpty ? nil : LineDiff.hunks(old: "", new: content)
            return [FileChange(path: path, kind: .add, diff: diff, isFullContent: true)]
        }
        if toolName == "Edit", let old = input["old_string"]?.stringValue, let new = input["new_string"]?.stringValue {
            let diff = LineDiff.hunks(old: old, new: new)
            return [FileChange(path: path, kind: .update, diff: diff)]
        }
        if toolName == "MultiEdit", let edits = input["edits"]?.arrayValue, !edits.isEmpty {
            let hunks = edits.compactMap { edit -> String? in
                guard let old = edit["old_string"]?.stringValue, let new = edit["new_string"]?.stringValue else { return nil }
                return LineDiff.hunks(old: old, new: new)
            }
            return [FileChange(path: path, kind: .update, diff: hunks.isEmpty ? nil : hunks.joined(separator: "\n"))]
        }
        return path.isEmpty ? [] : [FileChange(path: path, kind: .update)]
    }

    private func approvalDetail(toolName: String, input: JSONValue) -> String {
        switch toolName {
        case "Bash":
            return input["command"]?.nonEmptyString ?? "Run shell command"
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            if let path = input["file_path"]?.nonEmptyString ?? input["notebook_path"]?.nonEmptyString {
                return relative(path)
            }
            return toolName
        case "ExitPlanMode":
            return input["plan"]?.nonEmptyString.map { "Approve plan:\n\($0.prefix(240))" } ?? "Exit Plan mode and proceed"
        default:
            return input["description"]?.nonEmptyString ?? toolName
        }
    }

    private func tokenUsage(from usage: JSONValue?) -> TokenUsage? {
        guard let usage, usage.objectValue != nil else { return nil }
        let total = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
            .compactMap { usage[$0]?.intValue }
            .reduce(0, +)
        guard total > 0 else { return nil }
        return TokenUsage(usedTokens: total, contextWindow: contextWindow)
    }

    private func toolResultText(_ content: JSONValue?) -> String? {
        if let text = content?.nonEmptyString { return text }
        if let array = content?.arrayValue {
            let texts = array.compactMap { block -> String? in
                block["text"]?.nonEmptyString
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }

    private func prettyInput(_ input: JSONValue) -> String? {
        if case let .object(dict) = input, dict.isEmpty { return nil }
        return input.prettyJSONString()
    }

    private func relative(_ path: String) -> String {
        OmpEventMapper.relative(path, to: cwd)
    }

    private mutating func notice(_ text: String, now: Date) -> ProviderEvent {
        noticeCount += 1
        return .itemUpdated(TurnItem(id: "claude-notice:\(noticeCount)", kind: .notice(text: text), status: .completed, startedAt: now, completedAt: now))
    }
}
