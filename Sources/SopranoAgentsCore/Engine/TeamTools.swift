import Foundation

/// The team's wire surface, pure so it is testable without a provider: the host tools every omp
/// conversation gets while the team has members (`team_message`, `team_list`, `team_activity`;
/// teammates also `team_create`),
/// the system-prompt appendix and memory overlay of a teammate, the header a teammate's
/// messages carry, the replies and reports the tools return, and the omp agent file a teammate
/// exports.
public enum TeamTools {
    public static let message = "team_message"
    public static let list = "team_list"
    public static let activity = "team_activity"
    public static let create = "team_create"

    /// Marker line in exported omp agent files; a file without it is never touched.
    static let exportMarker = "# soprano-agents-teammate:"

    // MARK: Tool definitions

    /// The host tools of a conversation. `others`: the teammates it can reach (never itself).
    /// A normal thread gets nothing while nobody is on the team; a teammate always gets
    /// `team_list`, `team_activity` (its own activity) and `team_create`, `team_message` once it
    /// has someone to message.
    public static func definitions(others: [Teammate], callerIsTeammate: Bool) -> [HostToolDefinition] {
        guard !others.isEmpty || callerIsTeammate else { return [] }
        var tools: [HostToolDefinition] = []
        if !others.isEmpty {
            let roster = others.map { "- `\($0.handle)`: \($0.name)\($0.role.isEmpty ? "" : " — \($0.role)")" }.joined(separator: "\n")
            tools.append(HostToolDefinition(
                name: message,
                label: "Team message",
                description: """
                Send a message to a teammate and wait for the reply. Teammates are long-lived agents on the user's team, \
                each with its own conversation, memory and home folder; they handle a message like any request (they may \
                read and change files in their home folder) and their final answer comes back as this tool's result. Use \
                it to delegate work, get a review or a decision, or ask what they know. Write a self-contained message: \
                the teammate does not see your conversation. Replies can take minutes.
                Teammates:
                \(roster)
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "to": ["type": "string", "enum": .array(others.map { .string($0.handle) }), "description": "The teammate's handle."],
                        "message": ["type": "string", "description": "What you want from the teammate, with the context it needs."],
                    ],
                    "required": ["to", "message"],
                    "additionalProperties": false,
                ]
            ))
        }
        tools.append(HostToolDefinition(
            name: list,
            label: "Team list",
            description: "List the user's teammates: handle, name, role, home folder and what each is doing right now.",
            parameters: ["type": "object", "properties": [:], "additionalProperties": false]
        ))
        tools.append(HostToolDefinition(
            name: activity,
            label: "Team activity",
            description: """
            What a teammate did in a period: every request it handled (when, from whom, what was asked, its answer, the \
            files it changed, the teammates it messaged). Exact, read from its recorded conversation. \
            \(callerIsTeammate ? "Omit `teammate` for your own activity; use this whenever you are asked what you did." : "")
            """.trimmingCharacters(in: .whitespaces),
            parameters: [
                "type": "object",
                "properties": [
                    "teammate": ["type": "string", "description": callerIsTeammate ? "Handle; omit for yourself." : "Handle of the teammate."],
                    "since": ["type": "string", "description": "\"today\" (default), \"yesterday\", \"week\" (last 7 days) or a date YYYY-MM-DD."],
                    "until": ["type": "string", "description": "Last day to include, YYYY-MM-DD; default: the end of the period."],
                ],
                "additionalProperties": false,
            ]
        ))
        if callerIsTeammate {
            tools.append(HostToolDefinition(
                name: create,
                label: "Team create",
                description: """
                Add a new long-lived teammate to the user's team: its own conversation, memory and home folder, reachable \
                with `team_message` as soon as this returns. Create one when the user asks for it, or when recurring work \
                needs an owner no current teammate covers (check `team_list` first; never a duplicate). For a one-off job \
                use a subagent instead. The teammate starts knowing only its role and instructions, so write them as its \
                standing brief. Tell the user whom you added.
                """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Display name (\"Frontend engineer\")."],
                        "role": ["type": "string", "description": "One line: what it is responsible for."],
                        "instructions": ["type": "string", "description": "Standing instructions: scope, repos, rules, how to report back."],
                        "handle": ["type": "string", "description": "Lowercase address (\"frontend\"); default: derived from the name."],
                        "home": ["type": "string", "description": "Home folder: a Soprano Agents project, by title or path; default: its own folder."],
                    ],
                    "required": ["name", "role"],
                    "additionalProperties": false,
                ]
            ))
        }
        return tools
    }

    // MARK: Teammate files

    /// The system-prompt appendix of a teammate (`--append-system-prompt`): who it is, its
    /// standing instructions and how the team works.
    public static func persona(_ teammate: Teammate, home: String, hasMemory: Bool) -> String {
        var text = """
        # You are \(teammate.name) (`\(teammate.handle)`)
        You are a long-lived member of the user's agent team in Soprano Agents.\(teammate.role.isEmpty ? "" : " Your role: \(teammate.role)")
        Your home folder is \(home).
        """
        let instructions = teammate.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            text += "\n\n## Standing instructions\n\(instructions)"
        }
        text += """


        ## How your team works
        - This conversation is your working life: every request reaches you here, from the user, from the user's threads and from other teammates. Each message starts with a header saying when it arrived and who sent it.
        - When a thread or teammate sent the message, your final answer of that turn goes back to them as your reply: make it complete on its own.
        - Ask a teammate with `team_message`; see who is on the team with `team_list`; add one with `team_create` when the user asks or a long-lived role is missing.
        - Asked what you did (today, yesterday, this week), call `team_activity`: it reads your recorded requests exactly; don't rely on what is left in your context.
        """
        if hasMemory {
            text += "\n- Your long-term memory is yours alone: `recall` before answering from memory, `retain` decisions and facts worth keeping."
        }
        return text + "\n"
    }

    /// omp config overlay giving a teammate its own long-term memory: a Mnemopi database in
    /// its data folder, one bank whatever folder it works in.
    public static func memoryOverlay(databasePath: String) -> String {
        """
        # Written by Soprano Agents: this teammate's own long-term memory.
        memory:
          backend: mnemopi
        mnemopi:
          scoping: global
          dbPath: \(yamlString(databasePath))

        """
    }

    /// `~/.omp/agent/agents/<handle>.md`: the persona as an omp task agent, so terminal omp can
    /// start a fresh copy. `model` is written when the teammate runs a specific model.
    public static func ompAgentFile(_ teammate: Teammate, threadID: String, model: String?) -> String {
        var lines = [
            "---",
            "\(exportMarker) \(threadID)",
            "# Written by Soprano Agents; edit the teammate there, this file is overwritten.",
            "name: \(teammate.handle)",
            "description: \(yamlString(teammate.role.isEmpty ? "\(teammate.name), a teammate from Soprano Agents" : "\(teammate.name): \(teammate.role)"))",
        ]
        if let model, OmpProtocol.modelSpec(model) != nil { lines.append("model: \(yamlString(model))") }
        lines.append("---")
        var body = "You are \(teammate.name).\(teammate.role.isEmpty ? "" : " Your role: \(teammate.role)")"
        let instructions = teammate.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty { body += "\n\n\(instructions)" }
        body += "\n\nYou are a fresh copy started by omp: the long-lived \(teammate.name) with its own conversation and memory lives in Soprano Agents."
        return lines.joined(separator: "\n") + "\n\n" + body + "\n"
    }

    /// The thread id an exported agent file was written for; nil when Soprano Agents didn't write it.
    static func exportOwner(_ contents: String) -> String? {
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false).prefix(4) where line.hasPrefix(exportMarker) {
            return line.dropFirst(exportMarker.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// A double-quoted YAML scalar (JSON string syntax is valid YAML).
    static func yamlString(_ text: String) -> String {
        JSONValue.string(text).jsonString()
    }

    // MARK: Messages

    /// The text a teammate's provider gets for `message`: a header with its arrival time and
    /// sender, and for a message from a thread or teammate a reminder that the answer is the
    /// reply. Slash commands reach the provider unchanged.
    public static func providerText(_ message: UserMessage, teammate: Teammate?) -> String {
        guard teammate != nil, !message.text.drop(while: \.isWhitespace).hasPrefix("/") else { return message.text }
        let from: String = switch message.sender?.kind {
        case .teammate?: "teammate \(message.sender?.name ?? "")"
        case .thread?: "the user's thread “\(message.sender?.name ?? "")”"
        case nil: "the user"
        }
        var text = "[\(timestamp(message.createdAt)) · from \(from)]\n\(message.text)"
        if let sender = message.sender {
            text += "\n\n(Your final answer this turn is sent back to \(sender.name) as your reply.)"
        }
        return text
    }

    /// "Thu 2026-11-05 14:02" in the user's time zone.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// The reply `team_message` returns once the teammate's turn for the message ended (or
    /// yielded: its answer is final). nil while it is still working.
    public static func reply(from turn: Turn, teammate: Teammate) -> HostToolResult? {
        let status = turn.isYielded ? turn.yieldedStatus : turn.status
        switch status {
        case .running:
            return nil
        case .failed:
            return HostToolResult(text: "\(teammate.name) could not answer: \(turn.failureMessage ?? "the turn failed").", isError: true)
        case .completed, .interrupted:
            var text = answer(of: turn) ?? "(\(teammate.name) finished without a written answer.)"
            if status == .interrupted { text = "(\(teammate.name) was stopped before finishing.)\n\n" + text }
            if let files = turn.checkpoint?.files, !files.isEmpty {
                text += "\n\n[\(teammate.name) changed \(files.count) file\(files.count == 1 ? "" : "s"): \(fileList(files.map(\.path)))]"
            }
            return HostToolResult(text: text)
        }
    }

    /// The turn's last answer: its last assistant message with text.
    static func answer(of turn: Turn) -> String? {
        for item in turn.items.reversed() {
            if case let .assistantMessage(text, _) = item.kind {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    // MARK: Reports

    /// `team_list`: one line per teammate.
    public static func roster(_ entries: [(teammate: Teammate, status: String, home: String)], callerHandle: String?) -> String {
        guard !entries.isEmpty else { return "Nobody is on the team yet." }
        return entries.map { entry in
            let you = entry.teammate.handle == callerHandle ? " (you)" : ""
            let role = entry.teammate.role.isEmpty ? "" : " — \(entry.teammate.role)"
            return "- `\(entry.teammate.handle)`\(you): \(entry.teammate.name)\(role) · \(entry.status) · home \(entry.home)"
        }.joined(separator: "\n")
    }

    /// A day range from `team_activity`'s `since` / `until`, in `calendar`. nil = unreadable.
    public static func period(since: String?, until: String?, now: Date, calendar: Calendar) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        func day(_ text: String) -> Date? {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        let start: Date
        var end = now
        switch since?.trimmingCharacters(in: .whitespaces).lowercased() {
        case nil, "", "today":
            start = today
        case "yesterday":
            start = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            end = today
        case "week":
            start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case let text?:
            guard let date = day(text) else { return nil }
            start = date
        }
        if let until = until?.trimmingCharacters(in: .whitespaces), !until.isEmpty {
            guard let last = day(until), let next = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
            end = next
        }
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// `team_activity`: the turns of a teammate's thread that started in `period`.
    public static func activityReport(_ thread: AgentThread, teammate: Teammate, period: DateInterval, now: Date) -> String {
        let turns = thread.turns.filter { $0.startedAt >= period.start && $0.startedAt < period.end }
        let range = "\(timestamp(period.start).prefix(14))–\(timestamp(period.end.addingTimeInterval(-1)).prefix(14))"
        guard !turns.isEmpty else { return "\(teammate.name) (`\(teammate.handle)`) handled no requests \(range)." }
        var lines = ["\(teammate.name) (`\(teammate.handle)`) handled \(turns.count) request\(turns.count == 1 ? "" : "s") \(range):"]
        for turn in turns {
            let from: String = switch turn.userMessage.sender?.kind {
            case .teammate?: "teammate \(turn.userMessage.sender?.name ?? "")"
            case .thread?: "thread “\(turn.userMessage.sender?.name ?? "")”"
            case nil: "the user"
            }
            let status = turn.isYielded ? turn.yieldedStatus : turn.status
            let state: String = switch status {
            case .running: "working"
            case .completed: "done"
            case .interrupted: "stopped"
            case .failed: "failed"
            }
            let minutes = Int((turn.duration(now: now) / 60).rounded())
            lines.append("- \(timestamp(turn.startedAt)) · from \(from) · \(state) · \(minutes < 1 ? "<1" : "\(minutes)") min")
            lines.append("  Asked: \(excerpt(turn.userMessage.text, 240))")
            for steer in turn.steers {
                lines.append("  Added: \(excerpt(steer.text, 160))")
            }
            for item in turn.items {
                if case let .toolCall(call) = item.kind, call.name == message {
                    lines.append("  \(call.title): \(excerpt(call.input ?? "", 160))")
                }
            }
            if let files = turn.checkpoint?.files, !files.isEmpty {
                lines.append("  Changed \(files.count) file\(files.count == 1 ? "" : "s"): \(fileList(files.map(\.path)))")
            }
            if let answer = answer(of: turn) {
                lines.append("  Answered: \(excerpt(answer, 320))")
            } else if let failure = turn.failureMessage {
                lines.append("  Failed: \(excerpt(failure, 200))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One line of at most `limit` characters.
    static func excerpt(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    static func fileList(_ paths: [String]) -> String {
        let shown = paths.prefix(8).joined(separator: ", ")
        return paths.count > 8 ? "\(shown) and \(paths.count - 8) more" : shown
    }
}
