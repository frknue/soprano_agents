import Foundation

/// Translates one OpenCode session's server events (`GET /api/event` payloads `{type, data}`)
/// into `ProviderEvent`s. No I/O; the session routes events by `data.sessionID` and feeds a
/// mapper per session (its own, and one per subagent session).
///
/// Item ids: `<assistantMessageID>:text:<ordinal>` and `…:reasoning:<ordinal>` for prose, the
/// tool call id (`toolu_…`) for tools.
///
/// - `session.text.delta` → `assistantDelta`; `session.text.ended {text}` → the completed message.
/// - `session.reasoning.delta` → `reasoningDelta`; `session.reasoning.ended {text}` → completed.
/// - `session.tool.called {id, input}` → the running item (the tool's name came with
///   `session.tool.input.started`); `session.tool.success {content, metadata}` → completed;
///   `session.tool.failed {error{type, message}}` → failed, or declined
///   (`permission.rejected`), or interrupted (`aborted`). Shell → command (`metadata.exit`),
///   edit/write/patch → file change (`metadata.files[{file, patch, status}]`, while running the
///   code its input carries), read → read, glob/grep/list → search, websearch → web search,
///   subagent/task → subagent, todowrite → "Updated tasks", question → nothing (its form is the
///   user-input item), others → tool call.
/// - `session.step.ended {finish, tokens}` → `tokenUsage`; `finish: "stop"` marks the step's last
///   text final. `session.step.failed` with an error other than an abort → error item.
/// - `session.compaction.ended` → "Context compacted"; `session.compaction.failed` → error item;
///   `session.retry.scheduled` → notice.
/// - `session.execution.succeeded|failed|interrupted` → the last text marked final, then
///   `turnCompleted` (completed, failed with `error.message`, interrupted).
public struct OpencodeEventMapper: Sendable {
    struct Tool: Sendable {
        var name: String
        var input: JSONValue = [:]
        var startedAt: Date
        var output = ""
        var metadata: JSONValue?
        var isFinished = false
    }

    public var cwd: String?
    /// Context window of the session's model.
    public var contextWindow: Int?
    private var texts: [String: String] = [:]
    private var lastText: (id: String, text: String)?
    private(set) var tools: [String: Tool] = [:]
    private var noticeCount = 0

    public init(cwd: String? = nil, contextWindow: Int? = nil) {
        self.cwd = cwd
        self.contextWindow = contextWindow
    }

    /// Forgets the turn's state (new turn, rollback).
    public mutating func resetTurn() {
        texts.removeAll()
        lastText = nil
        tools.removeAll()
    }

    public mutating func map(_ event: JSONValue) -> [ProviderEvent] {
        let data = event["data"] ?? [:]
        switch event["type"]?.stringValue {
        case "session.text.delta":
            guard let itemID = Self.itemID(data, "text"), let delta = data["delta"]?.stringValue, !delta.isEmpty else { return [] }
            let text = texts[itemID, default: ""] + delta
            texts[itemID] = text
            lastText = (itemID, text)
            return [.assistantDelta(itemID: itemID, delta: delta, isFinal: false)]
        case "session.text.ended":
            guard let itemID = Self.itemID(data, "text") else { return [] }
            let text = data["text"]?.stringValue ?? texts[itemID] ?? ""
            texts[itemID] = text
            guard !text.isEmpty else { return [] }
            lastText = (itemID, text)
            return [.itemUpdated(TurnItem(id: itemID, kind: .assistantMessage(text: text, isFinal: false), status: .completed))]
        case "session.reasoning.delta":
            guard let itemID = Self.itemID(data, "reasoning"), let delta = data["delta"]?.stringValue, !delta.isEmpty else { return [] }
            return [.reasoningDelta(itemID: itemID, delta: delta)]
        case "session.reasoning.ended":
            guard let itemID = Self.itemID(data, "reasoning"), let text = data["text"]?.nonEmptyString else { return [] }
            return [.itemUpdated(TurnItem(id: itemID, kind: .reasoning(text: text), status: .completed))]
        case "session.tool.input.started":
            guard let id = data["id"]?.nonEmptyString, let name = data["name"]?.nonEmptyString else { return [] }
            if tools[id] == nil { tools[id] = Tool(name: name, startedAt: Date()) }
            return []
        case "session.tool.called":
            guard let id = data["id"]?.nonEmptyString else { return [] }
            var tool = tools[id] ?? Tool(name: data["name"]?.stringValue ?? "tool", startedAt: Date())
            tool.input = data["input"] ?? [:]
            tools[id] = tool
            return item(id, tool, status: .running).map { [.itemUpdated($0)] } ?? []
        case "session.tool.progress":
            guard let id = data["id"]?.nonEmptyString, var tool = tools[id], !tool.isFinished else { return [] }
            tool.metadata = data["metadata"]
            tools[id] = tool
            return []
        case "session.tool.success":
            return finishTool(data, status: .completed, output: Self.contentText(data["content"]))
        case "session.tool.failed":
            let status: TurnItemStatus = switch data["error"]?["type"]?.stringValue {
            case "permission.rejected": .declined
            case "aborted": .interrupted
            default: .failed
            }
            return finishTool(data, status: status, output: data["error"]?["message"]?.nonEmptyString)
        case "session.step.ended":
            var events: [ProviderEvent] = []
            if data["finish"]?.stringValue == "stop", let messageID = data["assistantMessageID"]?.stringValue,
               let last = lastText, last.id.hasPrefix("\(messageID):") {
                events.append(.itemUpdated(TurnItem(id: last.id, kind: .assistantMessage(text: last.text, isFinal: true), status: .completed)))
            }
            if let usage = OpencodeProtocol.contextUsage(data["tokens"], contextWindow: contextWindow) {
                events.append(.tokenUsage(usage))
            }
            return events
        case "session.step.failed":
            var events: [ProviderEvent] = []
            if data["error"]?["type"]?.stringValue != "aborted", let message = Self.errorMessage(data["error"]) {
                events.append(.itemUpdated(TurnItem(id: "\(data["assistantMessageID"]?.stringValue ?? "step"):error", kind: .error(message: message), status: .failed)))
            }
            if let usage = OpencodeProtocol.contextUsage(data["tokens"], contextWindow: contextWindow) {
                events.append(.tokenUsage(usage))
            }
            return events
        case "session.retry.scheduled":
            let reason = Self.errorMessage(data["error"]) ?? data["message"]?.nonEmptyString
            return [notice(reason.map { "Retrying: \($0)" } ?? "Retrying the request")]
        case "session.compaction.ended":
            return [notice("Context compacted", id: data["inputID"]?.stringValue.map { "\($0):compaction" })]
        case "session.compaction.failed":
            let message = Self.errorMessage(data["error"]) ?? "OpenCode could not compact the conversation."
            noticeCount += 1
            return [.itemUpdated(TurnItem(id: "compaction-error:\(noticeCount)", kind: .error(message: "Compaction failed: \(message)"), status: .failed))]
        case "session.execution.succeeded":
            return complete(.completed, error: nil)
        case "session.execution.failed":
            return complete(.failed, error: Self.errorMessage(data["error"]) ?? "OpenCode ended the turn with an error.")
        case "session.execution.interrupted":
            return complete(.interrupted, error: nil)
        default:
            return []
        }
    }

    /// Live output of a running shell tool (polled from `GET /api/shell/{id}/output`).
    public mutating func appendOutput(toolID: String, _ delta: String) -> [ProviderEvent] {
        guard !delta.isEmpty, var tool = tools[toolID], !tool.isFinished else { return [] }
        tool.output += delta
        tools[toolID] = tool
        return [.commandOutputDelta(itemID: toolID, delta: delta)]
    }

    /// The running tool that runs shell `shellID` (`session.tool.progress {metadata.shellID}`).
    func tool(runningShell shellID: String) -> String? {
        tools.first { !$0.value.isFinished && $0.value.metadata?["shellID"]?.stringValue == shellID }?.key
    }

    /// The tool's one-line label (subagent activity lines).
    func title(ofTool id: String) -> String? {
        guard let tool = tools[id], let item = item(id, tool, status: .running) else { return nil }
        switch item.kind {
        case let .toolCall(call): return call.title
        case let .command(execution): return "Ran \(execution.command)"
        case let .fileChange(changes): return changes.first.map { "Edited \($0.path)" }
        case let .webSearch(query): return "Searched the web for \(query)"
        default: return nil
        }
    }

    // MARK: - Turn end

    private mutating func complete(_ outcome: ProviderTurnOutcome, error: String?) -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        if let last = lastText {
            events.append(.itemUpdated(TurnItem(id: last.id, kind: .assistantMessage(text: last.text, isFinal: true), status: .completed)))
        }
        events.append(.turnCompleted(outcome: outcome, error: error))
        resetTurn()
        return events
    }

    private mutating func notice(_ text: String, id: String? = nil) -> ProviderEvent {
        noticeCount += 1
        return .itemUpdated(TurnItem(id: id ?? "notice:\(noticeCount)", kind: .notice(text: text), status: .completed))
    }

    // MARK: - Tools

    private mutating func finishTool(_ data: JSONValue, status: TurnItemStatus, output: String?) -> [ProviderEvent] {
        guard let id = data["id"]?.nonEmptyString else { return [] }
        var tool = tools[id] ?? Tool(name: data["name"]?.stringValue ?? "tool", startedAt: Date())
        if let output { tool.output = output }
        if let metadata = data["metadata"], metadata.objectValue != nil { tool.metadata = metadata }
        tool.isFinished = true
        tools[id] = tool
        return item(id, tool, status: status).map { [.itemUpdated($0)] } ?? []
    }

    func item(_ id: String, _ tool: Tool, status: TurnItemStatus) -> TurnItem? {
        let input = tool.input
        let output = tool.output.isEmpty ? nil : tool.output
        func item(_ kind: TurnItemKind) -> TurnItem {
            TurnItem(id: id, kind: kind, status: status, startedAt: tool.startedAt, completedAt: status.isActive ? nil : Date())
        }
        let path = (input["path"] ?? input["filePath"])?.nonEmptyString
        switch tool.name {
        case "shell", "bash":
            var exitCode = tool.metadata?["exit"]?.intValue
            if exitCode == nil, status == .completed { exitCode = 0 }
            return item(.command(CommandExecution(
                command: input["command"]?.stringValue ?? "",
                cwd: input["workdir"]?.nonEmptyString.map(relative),
                output: tool.output,
                exitCode: exitCode
            )))
        case "edit", "write", "patch", "apply_patch", "multiedit":
            return item(.fileChange(fileChanges(tool, status: status)))
        case "read":
            return item(.toolCall(ToolCall(name: tool.name, category: .read, title: "Read \(relative(path ?? ""))", input: OmpEventMapper.inputText(input), output: output)))
        case "glob", "grep", "list", "ls", "find", "codesearch":
            let pattern = input["pattern"]?.nonEmptyString ?? input["query"]?.nonEmptyString
            var title: String
            if let pattern {
                title = "Searched \(pattern)"
                if let path { title += " in \(relative(path))" }
            } else {
                title = "Searched \(relative(path ?? "."))"
            }
            return item(.toolCall(ToolCall(name: tool.name, category: .search, title: title, input: OmpEventMapper.inputText(input), output: output)))
        case "websearch":
            return item(.webSearch(query: input["query"]?.stringValue ?? ""))
        case "webfetch":
            let url = input["url"]?.nonEmptyString
            return item(.toolCall(ToolCall(name: tool.name, category: .other, title: url.map { "Fetched \($0)" } ?? "Fetched a page", input: OmpEventMapper.inputText(input), output: output)))
        case "subagent", "task":
            let label = input["description"]?.nonEmptyString ?? input["agent"]?.nonEmptyString
            return item(.toolCall(ToolCall(name: tool.name, category: .subagent, title: label.map { "Subagent: \($0)" } ?? "Subagent", input: OmpEventMapper.inputText(input), output: output)))
        case "todowrite", "todoread", "todo":
            return item(.toolCall(ToolCall(name: tool.name, category: .other, title: "Updated tasks", input: OmpEventMapper.inputText(input), output: output)))
        case "skill":
            let name = input["name"]?.nonEmptyString ?? input["id"]?.nonEmptyString
            return item(.toolCall(ToolCall(name: tool.name, category: .other, title: name.map { "Skill: \($0)" } ?? "Skill", input: OmpEventMapper.inputText(input), output: output)))
        case "question":
            return nil
        default:
            let label = input["description"]?.nonEmptyString ?? tool.name
            return item(.toolCall(ToolCall(name: tool.name, category: .other, title: label, input: OmpEventMapper.inputText(input), output: output)))
        }
    }

    /// The applied diffs (`metadata.files`), else the code the input carries (a running or
    /// declined call shows what it would write; a failed one only names its file).
    private func fileChanges(_ tool: Tool, status: TurnItemStatus) -> [FileChange] {
        let reported = (tool.metadata?["files"]?.arrayValue ?? []).compactMap { file -> FileChange? in
            guard let name = file["file"]?.nonEmptyString else { return nil }
            let kind: FileChange.Kind = switch file["status"]?.stringValue {
            case "added": .add
            case "deleted": .delete
            default: .update
            }
            return FileChange(path: OpencodeProtocol.displayPath(name, cwd: cwd), kind: kind, diff: OpencodeProtocol.hunks(file["patch"]?.stringValue))
        }
        let path = (tool.input["path"] ?? tool.input["filePath"])?.nonEmptyString
        // OpenCode names reported files relative to its project root; a one-file tool's own
        // (absolute) path is exact.
        if reported.count == 1, let path, path.hasPrefix("/") {
            var change = reported[0]
            change.path = relative(path)
            return [change]
        }
        if !reported.isEmpty { return reported }
        if status == .failed {
            return path.map { [FileChange(path: relative($0), kind: .update)] } ?? []
        }
        var args = tool.input
        if case var .object(fields) = args, tool.name == "edit" {
            fields["old_string"] = fields["oldString"]
            fields["new_string"] = fields["newString"]
            if let path { fields["path"] = .string(path) }
            args = .object(fields)
        }
        let preview = OmpEditPreview.changes(tool: tool.name == "write" ? "write" : "edit", args: args, relative: relative)
        if !preview.isEmpty { return preview }
        return path.map { [FileChange(path: relative($0), kind: .update)] } ?? []
    }

    // MARK: - Helpers

    private func relative(_ path: String) -> String {
        OmpEventMapper.relative(path, to: cwd)
    }

    static func itemID(_ data: JSONValue, _ kind: String) -> String? {
        guard let message = data["assistantMessageID"]?.nonEmptyString else { return nil }
        return "\(message):\(kind):\(data["ordinal"]?.intValue ?? 0)"
    }

    static func contentText(_ content: JSONValue?) -> String? {
        OmpEventMapper.contentText(content)
    }

    /// `{type, message}` → message (an `aborted` error has none worth showing).
    static func errorMessage(_ error: JSONValue?) -> String? {
        error?["message"]?.nonEmptyString ?? error?.nonEmptyString
    }
}
