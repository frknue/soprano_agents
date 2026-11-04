import AppKit
import Testing
@testable import SopranoAgentsCore

/// `OpencodeEventMapper` against event traces recorded from OpenCode 2.2.5's `GET /api/event`
/// (`Fixtures/opencode-*.jsonl`, one session's events per turn).
struct OpencodeEventMapperTests {
    private static func trace(_ name: String) throws -> [JSONValue] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONValue.parse(String($0)) }
    }

    private static func run(_ name: String, cwd: String = "/private/tmp/oc-play") throws -> [ProviderEvent] {
        var mapper = OpencodeEventMapper(cwd: cwd, contextWindow: 200_000)
        return try trace(name).flatMap { mapper.map($0) }
    }

    /// The latest version of every item, by id.
    private static func items(_ events: [ProviderEvent]) -> [String: TurnItem] {
        var items: [String: TurnItem] = [:]
        for case let .itemUpdated(item) in events { items[item.id] = item }
        return items
    }

    @Test func aToolTurnBecomesAFileWriteACommandAndAFinalAnswer() throws {
        let events = try Self.run("opencode-tool-turn.jsonl")
        let items = Self.items(events)

        let write = try #require(items["toolu_01PyD6HdCbcjiTN4AnKNEAQF"])
        guard case let .fileChange(changes) = write.kind else { Issue.record("not a file change: \(write.kind)"); return }
        #expect(write.status == .completed)
        #expect(changes.map(\.path) == ["hello.txt"])
        #expect(changes.first?.diff?.contains("+hi") == true)

        let shell = try #require(items["toolu_019c7eUsPw277dnYouFTRMz8"])
        guard case let .command(execution) = shell.kind else { Issue.record("not a command: \(shell.kind)"); return }
        #expect(execution.command == "ls -la")
        #expect(execution.exitCode == 0)
        #expect(execution.output.contains("hello.txt"))
        #expect(execution.cwd == ".")

        let answer = try #require(items["msg_1a849c886001kj4eNf1vK0elir:text:0"])
        guard case let .assistantMessage(text, isFinal) = answer.kind else { Issue.record("not prose"); return }
        #expect(isFinal)
        #expect(text.hasPrefix("I created `hello.txt`"))
        #expect(items["msg_1a849c886001kj4eNf1vK0elir:reasoning:0"] != nil)

        #expect(events.contains { if case let .tokenUsage(usage) = $0 { usage.contextWindow == 200_000 && usage.usedTokens > 0 } else { false } })
        #expect(events.last == .turnCompleted(outcome: .completed, error: nil))
    }

    @Test func anEditShowsTheDiffOpenCodeApplied() throws {
        let items = Self.items(try Self.run("opencode-edit-turn.jsonl"))
        let edit = try #require(items["toolu_012vUhtZqdRTorDFkbdSo5mR"])
        guard case let .fileChange(changes) = edit.kind else { Issue.record("not a file change"); return }
        #expect(changes == [FileChange(path: "hello.txt", kind: .update, diff: "@@ -1,1 +1,1 @@\n-hi\n+hello")])
    }

    @Test func rejectingAllPermissionsInterruptsTheToolsAndTheTurn() throws {
        let events = try Self.run("opencode-permission-turn.jsonl")
        let items = Self.items(events)
        #expect(items["toolu_013ATV4RwdgaWZSpaVG4gjEx"]?.status == .interrupted)
        #expect(items["toolu_0115j6ryBZPuvu3UUCLP1rCv"]?.status == .interrupted)
        // An aborted step is no error worth a row.
        #expect(!items.values.contains { if case .error = $0.kind { true } else { false } })
        #expect(events.last == .turnCompleted(outcome: .interrupted, error: nil))
    }

    @Test func aDeclinedPermissionDeclinesItsToolAndTheTurnCarriesOn() throws {
        let events = try Self.run("opencode-decline-turn.jsonl")
        let items = Self.items(events)
        let shell = try #require(items["toolu_01Gk8ZgRtX3XaQVaUHVxd6vR"])
        #expect(shell.status == .declined)
        guard case let .command(execution) = shell.kind else { Issue.record("not a command"); return }
        #expect(execution.output == "Not now; skip the command and answer anyway.")
        #expect(execution.exitCode == nil)
        #expect(events.last == .turnCompleted(outcome: .completed, error: nil))
    }

    @Test func theQuestionToolLeavesNoToolRow() throws {
        let events = try Self.run("opencode-question-turn.jsonl")
        #expect(Self.items(events)["toolu_01HBCiRwK9gHBaJtVWD71qtn"] == nil)
        #expect(events.last == .turnCompleted(outcome: .completed, error: nil))
    }

    @Test func aCompactionTurnShowsItsNotice() throws {
        let events = try Self.run("opencode-compaction.jsonl")
        let notices = Self.items(events).values.compactMap { item -> String? in
            if case let .notice(text) = item.kind { text } else { nil }
        }
        #expect(notices == ["Context compacted"])
        #expect(events.last == .turnCompleted(outcome: .completed, error: nil))
    }

    @Test func aFailedExecutionFailsTheTurnWithOpenCodesMessage() throws {
        var mapper = OpencodeEventMapper()
        // Recorded: a model the region may not use.
        let failure = try JSONValue.parse(#"{"type":"session.execution.failed","data":{"sessionID":"ses_1","error":{"type":"provider.auth","message":"This model is not available in your country","status":403}}}"#)
        #expect(mapper.map(failure) == [.turnCompleted(outcome: .failed, error: "This model is not available in your country")])
    }

    @Test func shellOutputStreamsIntoTheCommandUntilTheToolEnds() throws {
        var mapper = OpencodeEventMapper(cwd: "/tmp/w")
        _ = mapper.map(try JSONValue.parse(#"{"type":"session.tool.input.started","data":{"id":"t1","name":"shell"}}"#))
        _ = mapper.map(try JSONValue.parse(#"{"type":"session.tool.called","data":{"id":"t1","input":{"command":"make"}}}"#))
        _ = mapper.map(try JSONValue.parse(#"{"type":"session.tool.progress","data":{"id":"t1","metadata":{"shellID":"sh_1"}}}"#))
        #expect(mapper.tool(runningShell: "sh_1") == "t1")
        #expect(mapper.appendOutput(toolID: "t1", "building\n") == [.commandOutputDelta(itemID: "t1", delta: "building\n")])

        let end = mapper.map(try JSONValue.parse(#"{"type":"session.tool.success","data":{"id":"t1","content":[{"type":"text","text":"building\ndone\n"}],"metadata":{"exit":2}}}"#))
        guard case let .itemUpdated(item)? = end.first, case let .command(execution) = item.kind else { Issue.record("no command"); return }
        #expect(execution.output == "building\ndone\n")
        #expect(execution.exitCode == 2)
        // A poll that lands after the end changes nothing.
        #expect(mapper.appendOutput(toolID: "t1", "late") == [])
    }
}
