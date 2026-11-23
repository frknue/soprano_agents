import Foundation

/// Opt-in cross-provider workflow settings (`workflows` in `settings.json`). Both advisor review
/// and auto-recap ship disabled so out-of-the-box behavior stays quiet until opted into.
public struct WorkflowSettings: Codable, Sendable, Hashable {
    /// Run a cross-provider advisor review automatically after a completed turn changes files.
    public var advisorEnabled: Bool
    /// Reviewer provider; nil falls back to `textGeneration.provider`.
    public var advisorProvider: ProviderKind?
    /// Reviewer model slug; nil uses that provider's configured default model.
    public var advisorModel: String?
    /// Optional custom review checklist or criteria appended to advisor reviews.
    public var advisorPrompt: String
    /// Generate a brief bullet recap card after turns that change files.
    public var autoRecapEnabled: Bool

    public init(
        advisorEnabled: Bool = false,
        advisorProvider: ProviderKind? = nil,
        advisorModel: String? = nil,
        advisorPrompt: String = "",
        autoRecapEnabled: Bool = false
    ) {
        self.advisorEnabled = advisorEnabled
        self.advisorProvider = advisorProvider
        self.advisorModel = advisorModel
        self.advisorPrompt = advisorPrompt
        self.autoRecapEnabled = autoRecapEnabled
    }
}

/// Parses `/review-with <provider>[/<model>] [instructions]` and builds structured prompts/parsers
/// for cross-provider reviews and recaps.
public enum CrossProviderWorkflows {
    public struct ReviewRequest: Sendable, Hashable {
        public var selection: ModelSelection
        public var instructions: String

        public init(selection: ModelSelection, instructions: String) {
            self.selection = selection
            self.instructions = instructions
        }
    }

    public static let reviewCommandName = "review-with"

    public static var builtInCommands: [ProviderCommand] {
        [
            ProviderCommand(
                name: reviewCommandName,
                kind: .command,
                description: "Review the thread's changes with another provider/model (e.g. /review-with codex or /review-with claude/opus focus on tests)",
                argumentHint: "<provider>[/<model>] [focus]",
                source: "Built-in",
                insertText: "/\(reviewCommandName) "
            ),
        ]
    }

    public static let reviewResponseSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "notes": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "severity": .object(["type": .string("string"), "enum": .array([.string("nit"), .string("concern"), .string("blocker")])]),
                        "text": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("severity"), .string("text")]),
                ]),
            ]),
        ]),
        "required": .array([.string("notes")]),
    ])

    public static let recapResponseSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "recap": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("recap")]),
    ])

    public static let sideQuestionResponseSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "answer": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("answer")]),
    ])

    /// Parses `/review-with <provider>[/<model>] [instructions]`; nil if `text` is not a
    /// `/review-with` command. Throws `EngineError.message` when the provider token is unknown.
    public static func parseReviewCommand(_ text: String) throws -> ReviewRequest? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "/\(reviewCommandName)" || trimmed.hasPrefix("/\(reviewCommandName) ") || trimmed.hasPrefix("/\(reviewCommandName)\t") else {
            return nil
        }
        let remainder = String(trimmed.dropFirst(reviewCommandName.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else {
            let names = ProviderKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw EngineError.message("Usage: /review-with <provider>[/<model>] [instructions]. Providers: \(names).")
        }
        let targetToken = String(remainder.prefix { !$0.isWhitespace })
        let instructions = String(remainder.dropFirst(targetToken.count)).trimmingCharacters(in: .whitespacesAndNewlines)

        let providerRaw: String
        let modelSlug: String
        if let slash = targetToken.firstIndex(of: "/") {
            providerRaw = String(targetToken[..<slash]).lowercased()
            let rest = String(targetToken[targetToken.index(after: slash)...])
            modelSlug = rest.isEmpty ? ModelSelection.configuredDefaultModel : rest
        } else {
            providerRaw = targetToken.lowercased()
            modelSlug = ModelSelection.configuredDefaultModel
        }

        guard let provider = ProviderKind(rawValue: providerRaw) else {
            let names = ProviderKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw EngineError.message("Unknown provider \"\(providerRaw)\" for /review-with. Choose one of: \(names).")
        }
        return ReviewRequest(
            selection: ModelSelection(provider: provider, model: modelSlug),
            instructions: instructions
        )
    }

    public static func reviewPrompt(
        diff: String,
        summary: String,
        instructions: String,
        criteria: String
    ) -> String {
        let clippedDiff = diff.count > 24000 ? String(diff.prefix(24000)) + "\n…(truncated)" : diff
        var parts = [
            "You are a senior code reviewer inspecting changes made in another coding agent session.",
            "Return ONLY a JSON object matching this schema:",
            "{\"notes\": [{\"severity\": \"nit\" | \"concern\" | \"blocker\", \"text\": \"concise actionable finding\"}]}",
            "If everything looks clean, return one nit note saying the changes look good.",
        ]
        if !criteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Review criteria:\n\(criteria)")
        }
        if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("Additional focus requested by the user:\n\(instructions)")
        }
        if !summary.isEmpty {
            parts.append("Latest turn summary:\n\(summary)")
        }
        if !clippedDiff.isEmpty {
            parts.append("Unified diff:\n```diff\n\(clippedDiff)\n```")
        }
        return parts.joined(separator: "\n\n")
    }

    public static func recapPrompt(userMessage: String, answer: String, changedFiles: [String]) -> String {
        let filesLine = changedFiles.isEmpty ? "None" : changedFiles.prefix(20).joined(separator: ", ")
        return """
        Summarize what was accomplished in this turn in 2 to 3 crisp bullet points for quick review.
        Return ONLY a JSON object: {"recap": "• ...\\n• ..."}

        User request:
        \(userMessage.prefix(2000))

        Changed files: \(filesLine)

        Agent answer:
        \(answer.prefix(4000))
        """
    }

    public static func parseAdvisorNotes(from json: JSONValue, advisorLabel: String) -> [AdvisorNote] {
        guard let notes = json["notes"]?.arrayValue, !notes.isEmpty else {
            if let summary = json["summary"]?.stringValue, !summary.isEmpty {
                return [AdvisorNote(text: summary, severity: .nit, advisor: advisorLabel)]
            }
            return []
        }
        return notes.compactMap { item in
            guard let text = item["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let severity = item["severity"]?.stringValue.flatMap { AdvisorNote.Severity(rawValue: $0.lowercased()) } ?? .nit
            return AdvisorNote(text: text, severity: severity, advisor: advisorLabel)
        }
    }
}
