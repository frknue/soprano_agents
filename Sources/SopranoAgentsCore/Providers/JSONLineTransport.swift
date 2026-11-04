import Foundation

/// A bidirectional newline-delimited text channel: `LineProcess` in the app, a fake in tests.
public protocol JSONLineTransport: AnyObject, Sendable {
    /// Lines in arrival order, then exactly one `.exited` when the channel closes.
    var incoming: AsyncStream<LineProcessEvent> { get }
    func send(_ line: String) throws
    /// Closes the channel (terminates the process). Idempotent.
    func close()
}

extension LineProcess: JSONLineTransport {
    public var incoming: AsyncStream<LineProcessEvent> { events }
    public func close() { terminate() }
}

extension JSONValue {
    /// Multi-line, key-sorted JSON for the work log's expanded tool input.
    public func prettyJSONString() -> String {
        if case let .string(text) = self { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return jsonString() }
        return String(decoding: data, as: UTF8.self)
    }

    /// Non-empty trimmed string, else nil.
    var nonEmptyString: String? {
        guard let text = stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// Prompt text sent to the agent CLIs, and the reading of structured answers.
enum ProviderPrompt {
    /// Message text with attachment paths: every attachment is listed after the
    /// text as `[Attached image "shot.png" is saved at: /path]`, so the agent can open it even
    /// when the image block alone is not enough.
    static func text(_ text: String, attachments: [Attachment]) -> String {
        var result = text
        for attachment in attachments {
            let context = "[Attached \(attachment.kind.rawValue) \"\(attachment.name)\" is saved at: \(attachment.path)]"
            result = result.isEmpty ? context : "\(result)\n\n\(context)"
        }
        return result
    }

    // MARK: - Text generation

    /// The generation prompt: the task, then the schema the answer must match.
    static func generationPrompt(_ prompt: String, schema: JSONValue) -> String {
        """
        \(prompt)

        Answer with only one JSON object that matches this JSON Schema. No prose, no Markdown fences.

        \(schema.jsonString(sortedKeys: true))
        """
    }

    /// The first JSON object in model output: Markdown fences are ignored and prose around the
    /// object is skipped (string-aware brace matching).
    static func firstJSONObject(in text: String) throws -> JSONValue {
        let characters = Array(text)
        var start = characters.startIndex
        while let open = characters[start...].firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escaped = false
            var index = open
            while index < characters.endIndex {
                let character = characters[index]
                if inString {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let candidate = String(characters[open...index])
                        if let value = try? JSONValue.parse(candidate), value.objectValue != nil { return value }
                        break
                    }
                }
                index += 1
            }
            start = open + 1
        }
        throw ProviderError.invalidOutput("The model did not return a JSON object.")
    }
}
