import Foundation

/// Folds agy's ACP `session/update` notifications and `session/request_permission` requests
/// into `ProviderEvent`s for one turn at a time:
///
/// - `agent_message_chunk` → `assistantDelta` on the turn's current message (a tool call or a
///   thought starts the next one); the turn's last message becomes its final answer at
///   `finishTurn()`.
/// - `agent_thought_chunk` → `reasoningDelta`.
/// - `tool_call` / `tool_call_update` (merged by `toolCallId`) → `itemUpdated`: `execute` →
///   `.command` (output from `rawOutput.output` without agy's "Created At…" preamble, exit code
///   from `rawOutput.exit_code`); `edit` / `delete` / `move` → `.fileChange` with hunks from the
///   `diff` content's old and new text; `read` → a Read row; `search` → a search row; anything
///   else → a tool row with agy's title.
/// - `plan` → one "Plan" tool row per turn (its entries as output).
/// - `usage_update {used, size}` → `tokenUsage`; `available_commands_update` → `commands`.
/// - Replays (`user_message_chunk`), titles, config and mode changes are ignored.
public struct AntigravityEventMapper: Sendable {
    struct Tool: Sendable {
        var name: String?
        var kind: String?
        var title: String?
        var status: String?
        var input: JSONValue?
        var output: JSONValue?
        var content: [JSONValue] = []
        var locations: [String] = []
        var startedAt: Date
    }

    public var cwd: String?
    /// Makes message and thought ids unique per turn ("t3/").
    private var prefix = ""
    private var tools: [String: Tool] = [:]
    private var counter = 0
    private var message: (id: String, text: String)?
    private var thoughtID: String?
    /// The latest message of the turn: its answer once the turn ends.
    private var lastMessage: (id: String, text: String)?
    private var planStarted: Date?

    public init(cwd: String? = nil) {
        self.cwd = cwd
    }

    /// Starts turn `number`: ids restart under a new prefix, the previous turn's state is dropped.
    public mutating func resetTurn(_ number: Int) {
        prefix = "t\(number)/"
        tools = [:]
        counter = 0
        message = nil
        thoughtID = nil
        lastMessage = nil
        planStarted = nil
    }

    /// One `session/update` `update` object.
    public mutating func update(_ update: JSONValue, now: Date = Date()) -> [ProviderEvent] {
        switch update["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            guard let text = update["content"]?["text"]?.stringValue, !text.isEmpty else { return [] }
            thoughtID = nil
            if message == nil {
                counter += 1
                message = ("\(prefix)message-\(counter)", "")
            }
            message!.text += text
            lastMessage = message
            return [.assistantDelta(itemID: message!.id, delta: text, isFinal: false)]
        case "agent_thought_chunk":
            guard let text = update["content"]?["text"]?.stringValue, !text.isEmpty else { return [] }
            message = nil
            if thoughtID == nil {
                counter += 1
                thoughtID = "\(prefix)thought-\(counter)"
            }
            return [.reasoningDelta(itemID: thoughtID!, delta: text)]
        case "tool_call", "tool_call_update":
            guard let id = update["toolCallId"]?.nonEmptyString else { return [] }
            message = nil
            thoughtID = nil
            merge(update, into: id, now: now)
            return item(id, now: now).map { [.itemUpdated($0)] } ?? []
        case "plan":
            let entries = (update["entries"]?.arrayValue ?? []).compactMap { entry -> String? in
                guard let content = entry["content"]?.nonEmptyString else { return nil }
                let mark = switch entry["status"]?.stringValue {
                case "completed": "[x]"
                case "in_progress": "[~]"
                default: "[ ]"
                }
                return "\(mark) \(content)"
            }
            guard !entries.isEmpty else { return [] }
            let started = planStarted ?? now
            planStarted = started
            let call = ToolCall(name: "plan", category: .other, title: "Updated the plan", output: entries.joined(separator: "\n"))
            return [.itemUpdated(TurnItem(id: "\(prefix)plan", kind: .toolCall(call), status: .completed, startedAt: started, completedAt: now))]
        case "usage_update":
            guard let used = update["used"]?.intValue else { return [] }
            return [.tokenUsage(TokenUsage(usedTokens: used, contextWindow: update["size"]?.intValue))]
        case "available_commands_update":
            return [.commands(Self.commands(update["availableCommands"]))]
        default:
            return []
        }
    }

    /// The turn ended: its last message is the answer.
    public mutating func finishTurn() -> [ProviderEvent] {
        defer {
            message = nil
            thoughtID = nil
            lastMessage = nil
        }
        guard let last = lastMessage, !last.text.isEmpty else { return [] }
        return [.itemUpdated(TurnItem(id: last.id, kind: .assistantMessage(text: last.text, isFinal: true), status: .completed))]
    }

    /// A permission request (`params` of `session/request_permission`) as an approval with
    /// `id`; the tool call it is about is merged and re-reported first.
    public mutating func permission(id: String, params: JSONValue, now: Date = Date()) -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        let call = params["toolCall"] ?? .null
        var kind = call["kind"]?.stringValue
        var detail = call["title"]?.nonEmptyString ?? "Antigravity wants to run a tool."
        if let toolID = call["toolCallId"]?.nonEmptyString {
            message = nil
            thoughtID = nil
            merge(call, into: toolID, now: now)
            if let item = item(toolID, now: now) { events.append(.itemUpdated(item)) }
            if let tool = tools[toolID] {
                kind = tool.kind ?? kind
                detail = approvalDetail(tool) ?? detail
            }
        }
        let approvalKind: ApprovalKind = switch kind {
        case "execute": .command
        case "edit", "delete", "move": .fileChange
        case "read": .fileRead
        default: .other
        }
        let options = params["options"]?.arrayValue ?? []
        events.append(.approvalRequested(ApprovalRequest(id: id, kind: approvalKind, detail: detail, options: AntigravityProtocol.approvalOptions(options))))
        return events
    }

    // MARK: - Tools

    private mutating func merge(_ update: JSONValue, into id: String, now: Date) {
        var tool = tools[id] ?? Tool(startedAt: now)
        tool.name = update["name"]?.nonEmptyString ?? tool.name
        tool.kind = update["kind"]?.nonEmptyString ?? tool.kind
        tool.status = update["status"]?.nonEmptyString ?? tool.status
        if let title = update["title"]?.nonEmptyString { tool.title = title }
        if let input = update["rawInput"], input != .null { tool.input = input }
        if let output = update["rawOutput"], output != .null { tool.output = output }
        if let content = update["content"]?.arrayValue, !content.isEmpty { tool.content = content }
        let locations = (update["locations"]?.arrayValue ?? []).compactMap { $0["path"]?.nonEmptyString }
        if !locations.isEmpty { tool.locations = locations }
        tools[id] = tool
    }

    private func item(_ id: String, now: Date) -> TurnItem? {
        guard let tool = tools[id] else { return nil }
        let status: TurnItemStatus = switch tool.status {
        case "completed": .completed
        case "failed": .failed
        case "pending": .pending
        default: .running
        }
        let kind: TurnItemKind = switch tool.kind {
        case "execute": .command(command(tool))
        case "edit", "delete", "move": .fileChange(fileChanges(tool))
        case "read": .toolCall(ToolCall(name: tool.name ?? "read", category: .read, title: "Read \(path(tool) ?? "a file")", input: inputText(tool), output: outputText(tool)))
        case "search": .toolCall(ToolCall(name: tool.name ?? "search", category: .search, title: tool.title ?? "Searched", input: inputText(tool), output: outputText(tool)))
        default: .toolCall(ToolCall(name: tool.name ?? "tool", category: .other, title: tool.title ?? tool.name ?? "Tool", input: inputText(tool), output: outputText(tool)))
        }
        let ended = status == .completed || status == .failed
        return TurnItem(id: id, kind: kind, status: status, startedAt: tool.startedAt, completedAt: ended ? now : nil)
    }

    private func command(_ tool: Tool) -> CommandExecution {
        let input = tool.input
        let line = input?["CommandLine"]?.nonEmptyString ?? input?["command"]?.nonEmptyString ?? tool.title ?? "command"
        let directory = input?["Cwd"]?.nonEmptyString ?? cwd
        var output = tool.output?["output"]?.stringValue ?? Self.contentText(tool.content) ?? ""
        output = Self.commandOutput(output)
        return CommandExecution(command: line, cwd: directory, output: output, exitCode: tool.output?["exit_code"]?.intValue)
    }

    private func fileChanges(_ tool: Tool) -> [FileChange] {
        let diffs = tool.content.filter { $0["type"]?.stringValue == "diff" }
        let changes: [FileChange] = diffs.compactMap { diff in
            guard let path = diff["path"]?.nonEmptyString else { return nil }
            let old = diff["oldText"]?.stringValue
            let new = diff["newText"]?.stringValue ?? ""
            let kind: FileChange.Kind = tool.kind == "delete" ? .delete : (old == nil ? .add : .update)
            return FileChange(path: relative(path), kind: kind, diff: LineDiff.hunks(old: old ?? "", new: new))
        }
        if !changes.isEmpty { return changes }
        let kind: FileChange.Kind = tool.kind == "delete" ? .delete : tool.kind == "move" ? .move : .update
        return tool.locations.isEmpty ? [] : [FileChange(path: relative(tool.locations[0]), kind: kind)]
    }

    private func approvalDetail(_ tool: Tool) -> String? {
        switch tool.kind {
        case "execute": command(tool).command
        case "edit", "delete", "move", "read": path(tool)
        default: tool.title
        }
    }

    private func path(_ tool: Tool) -> String? {
        let raw = tool.locations.first ?? tool.input?["Path"]?.nonEmptyString ?? tool.input?["AbsolutePath"]?.nonEmptyString
        return raw.map(relative)
    }

    private func relative(_ path: String) -> String {
        OmpEventMapper.relative(path, to: cwd)
    }

    private func inputText(_ tool: Tool) -> String? {
        guard let input = tool.input else { return nil }
        if case let .object(object) = input, object.isEmpty { return nil }
        return input.prettyJSONString()
    }

    private func outputText(_ tool: Tool) -> String? {
        if let text = tool.output?["output"]?.nonEmptyString { return text }
        return Self.contentText(tool.content)
    }

    /// The text of `content` blocks (`{type:"content", content:{type:"text", text}}`).
    static func contentText(_ content: [JSONValue]) -> String? {
        let texts = content.compactMap { block -> String? in
            guard block["type"]?.stringValue == "content" else { return nil }
            return block["content"]?["text"]?.stringValue
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// agy's command result without its "Created At / Completed At / Command exited…" preamble
    /// and with `\r\n` as `\n`.
    static func commandOutput(_ text: String) -> String {
        var output = text.replacingOccurrences(of: "\r\n", with: "\n")
        if let marker = output.range(of: "Command output:\n") {
            output = String(output[marker.upperBound...])
        } else if output.hasPrefix("Created At:"), let blank = output.range(of: "\n\n") {
            output = String(output[blank.upperBound...])
        }
        return output
    }

    /// `availableCommands` → the composer's `/` menu entries.
    static func commands(_ list: JSONValue?) -> [ProviderCommand] {
        (list?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.nonEmptyString else { return nil }
            return ProviderCommand(
                name: name,
                kind: .command,
                description: entry["description"]?.nonEmptyString,
                argumentHint: entry["input"]?["hint"]?.nonEmptyString,
                insertText: "/\(name) "
            )
        }
    }
}
