import AppKit
import Testing
@testable import SopranoAgentsCore

/// `AntigravityEventMapper` against ACP traces recorded from agy 1.5.14 (`Fixtures/antigravity-*.jsonl`:
/// `>>` lines the client sent, `<<` lines agy sent).
struct AntigravityEventMapperTests {
    private static let cwd = "/tmp/agy-native"

    private static func received(_ name: String) throws -> [JSONValue] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.hasPrefix("<< ") }
            .map { try JSONValue.parse(String($0.dropFirst(3))) }
    }

    /// Every `session/update` and permission request of the trace through one mapper, then the
    /// turn's end.
    private static func run(_ name: String) throws -> [ProviderEvent] {
        var mapper = AntigravityEventMapper(cwd: cwd)
        mapper.resetTurn(1)
        var events: [ProviderEvent] = []
        var permissions = 0
        for message in try received(name) {
            switch message["method"]?.stringValue {
            case "session/update":
                events += mapper.update(message["params"]?["update"] ?? .null)
            case "session/request_permission":
                permissions += 1
                events += mapper.permission(id: "approval-\(permissions)", params: message["params"] ?? .null)
            default:
                break
            }
        }
        return events + mapper.finishTurn()
    }

    private static func items(_ events: [ProviderEvent]) -> [String: TurnItem] {
        var items: [String: TurnItem] = [:]
        for case let .itemUpdated(item) in events { items[item.id] = item }
        return items
    }

    @Test func aToolTurnBecomesARead_AnEditWithItsDiff_ACommandWithItsOutput_AndAFinalAnswer() throws {
        let events = try Self.run("antigravity-tool-turn.jsonl")
        let items = Self.items(events)

        let read = try #require(items["call_16575035090776001273"])
        guard case let .toolCall(call) = read.kind else { Issue.record("not a tool row: \(read.kind)"); return }
        #expect(call.category == .read)
        #expect(call.title == "Read notes.txt")
        #expect(read.status == .completed)

        let edit = try #require(items["call_14787403848441754043"])
        guard case let .fileChange(changes) = edit.kind else { Issue.record("not a file change: \(edit.kind)"); return }
        #expect(edit.status == .completed)
        #expect(changes.map(\.path) == ["notes.txt"])
        #expect(changes.first?.kind == .update)
        #expect(changes.first?.diff == "@@ -1,2 +1,2 @@\n hello\n-world\n+Soprano")

        let shell = try #require(items["call_10199597004774062334"])
        guard case let .command(execution) = shell.kind else { Issue.record("not a command: \(shell.kind)"); return }
        #expect(execution.command == "wc -l notes.txt")
        #expect(execution.output == "       2 notes.txt\n")
        #expect(execution.exitCode == 0)

        let answers = items.values.compactMap { item -> String? in
            if case let .assistantMessage(text, true) = item.kind { return text }
            return nil
        }
        #expect(answers.count == 1)
        #expect(answers.first?.contains("2 notes.txt") == true)
        #expect(events.contains { if case .reasoningDelta = $0 { true } else { false } })
    }

    @Test func permissionRequestsBecomeApprovalsNamingTheFileOrCommand() throws {
        let events = try Self.run("antigravity-tool-turn.jsonl")
        let approvals = events.compactMap { event -> ApprovalRequest? in
            if case let .approvalRequested(request) = event { return request }
            return nil
        }
        #expect(approvals.map(\.kind) == [.fileChange, .command])
        #expect(approvals.map(\.detail) == ["notes.txt", "wc -l notes.txt"])
        // agy offers allow_once and reject_once: no "Always allow".
        #expect(approvals.first?.options == [.cancel, .decline, .accept])
    }

    @Test func theContextFillComesFromUsageUpdates() throws {
        let events = try Self.run("antigravity-tool-turn.jsonl")
        let usages = events.compactMap { event -> TokenUsage? in
            if case let .tokenUsage(usage) = event { return usage }
            return nil
        }
        #expect(usages.last == TokenUsage(usedTokens: 10251, contextWindow: 1_048_576))
    }

    @Test func aDeniedCommandEndsFailed() throws {
        let items = Self.items(try Self.run("antigravity-decline-cancel.jsonl"))
        let shell = try #require(items["call_12810448682822598112"])
        guard case let .command(execution) = shell.kind else { Issue.record("not a command: \(shell.kind)"); return }
        #expect(execution.command == "echo hi")
        #expect(shell.status == .failed)
    }

    @Test func messagesSplitAroundToolCallsAndOnlyTheLastIsTheAnswer() {
        var mapper = AntigravityEventMapper(cwd: Self.cwd)
        mapper.resetTurn(2)
        let chunk: (String) -> JSONValue = { ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string($0)]] }
        _ = mapper.update(chunk("Let me look."))
        _ = mapper.update(["sessionUpdate": "tool_call", "toolCallId": "c1", "kind": "read", "status": "completed", "locations": [["path": "/tmp/agy-native/a.txt"]]])
        let second = mapper.update(chunk("Done."))
        let end = mapper.finishTurn()

        #expect(second == [.assistantDelta(itemID: "t2/message-2", delta: "Done.", isFinal: false)])
        guard end.count == 1, case let .itemUpdated(answer) = end[0], case let .assistantMessage(text, isFinal) = answer.kind else {
            Issue.record("no final answer: \(end)")
            return
        }
        #expect(answer.id == "t2/message-2")
        #expect(text == "Done.")
        #expect(isFinal)
    }
}
