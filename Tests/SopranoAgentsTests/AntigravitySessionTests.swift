import AppKit
import Testing
@testable import SopranoAgentsCore

/// `AntigravitySession` against a fake `agy acp` that answers like agy 1.5.14 (recorded live):
/// `initialize`, `session/new` with model / thought_level / mode config options, `session/load`
/// for a known session (replaying a history update first), `session/set_config_option`, and
/// prompts that answer with text, ask permission for an edit, or run until `session/cancel`.
/// Every message the fake receives is logged.
@MainActor
struct AntigravitySessionTests {
    private static let fakeAgy = #"""
    #!/usr/bin/env python3
    import json, os, sys, threading
    log = os.environ["FAKE_AGY_LOG"]
    def record(o):
        with open(log, "a") as f:
            f.write(json.dumps(o) + "\n")
    record({"args": sys.argv[1:], "home": os.environ.get("GEMINI_HOME")})
    lock = threading.Lock()
    def out(o):
        with lock:
            sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    state = {"model": "gemini-4-neon", "thought_level": "high", "mode": "default"}
    def options():
        return [
            {"id": "model", "category": "model", "type": "select", "currentValue": state["model"],
             "options": [{"value": "gemini-4-neon", "name": "Gemini 4 Neon"}, {"value": "gemini-3.8-flash", "name": "Gemini 3.8 Flash"}]},
            {"id": "thought_level", "category": "thought_level", "type": "select", "currentValue": state["thought_level"],
             "options": [{"value": v, "name": v} for v in ["low", "medium", "high"]]},
            {"id": "mode", "category": "mode", "type": "select", "currentValue": state["mode"],
             "options": [{"value": v, "name": v} for v in ["default", "accept-edits", "auto", "plan"]]},
        ]
    def update(sid, u):
        out({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": u}})
    def chunk(sid, text):
        update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})
    answers = {}
    answered = threading.Condition()
    cancelled = threading.Event()
    def await_answer(rid):
        with answered:
            while rid not in answers and not cancelled.is_set():
                answered.wait(0.05)
            return answers.get(rid)
    def prompt(msg):
        sid = msg["params"]["sessionId"]
        text = msg["params"]["prompt"][0]["text"]
        cancelled.clear()
        stop = "end_turn"
        if "edit" in text:
            call = {"toolCallId": "call_edit", "kind": "edit", "title": "File notes.txt", "rawInput": {"Path": "/w/notes.txt"},
                    "locations": [{"path": "/w/notes.txt"}]}
            update(sid, dict(call, sessionUpdate="tool_call", status="in_progress"))
            out({"jsonrpc": "2.0", "id": "1", "method": "session/request_permission",
                 "params": {"sessionId": sid, "toolCall": dict(call, sessionUpdate="tool_call", status="pending"),
                            "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                                        {"optionId": "deny", "name": "Deny", "kind": "reject_once"}]}})
            outcome = (await_answer("1") or {}).get("outcome", {})
            if outcome.get("optionId") == "allow":
                update(sid, dict(call, sessionUpdate="tool_call_update", status="completed",
                                 content=[{"type": "diff", "path": "/w/notes.txt", "oldText": "a\n", "newText": "b\n"}]))
                chunk(sid, "Edited.")
            elif outcome.get("outcome") == "cancelled":
                stop = "cancelled"
            else:
                update(sid, dict(call, sessionUpdate="tool_call_update", status="failed"))
                chunk(sid, "Skipped.")
        elif "burst" in text:
            # Many chunks and the answer in one write: the reader is far behind when it arrives.
            lines = [json.dumps({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid,
                     "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "x"}}}}) for _ in range(2000)]
            lines.append(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"stopReason": stop}}))
            with lock:
                sys.stdout.write("\n".join(lines) + "\n"); sys.stdout.flush()
            return
        elif "stubborn" in text:
            # Ignores session/cancel and never answers this prompt; the process stays alive.
            chunk(sid, "Still going")
            threading.Event().wait(60)
            return
        elif "slow" in text:
            chunk(sid, "Working")
            cancelled.wait(10)
            stop = "cancelled"
        else:
            chunk(sid, "Hello")
            chunk(sid, " there")
        update(sid, {"sessionUpdate": "usage_update", "used": 1200, "size": 1048576})
        out({"jsonrpc": "2.0", "id": msg["id"], "result": {"stopReason": stop}})
    for line in sys.stdin:
        msg = json.loads(line)
        record({"recv": msg})
        method = msg.get("method")
        if method is None:
            with answered:
                answers[msg["id"]] = msg.get("result", {})
                answered.notify_all()
        elif method == "initialize":
            out({"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}}})
        elif method == "session/new":
            out({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "s-new", "configOptions": options()}})
        elif method == "session/load":
            sid = msg["params"]["sessionId"]
            if sid == "s-known":
                update(sid, {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "old question"}})
                chunk(sid, "old answer")
                out({"jsonrpc": "2.0", "id": msg["id"], "result": {"configOptions": options()}})
            else:
                out({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32002, "message": "conversation not found"}})
        elif method == "session/set_config_option":
            state[msg["params"]["configId"]] = msg["params"]["value"]
            out({"jsonrpc": "2.0", "id": msg["id"], "result": {"configOptions": options()}})
        elif method == "session/prompt":
            threading.Thread(target=prompt, args=(msg,), daemon=True).start()
        elif method == "session/cancel":
            cancelled.set()
            with answered:
                answered.notify_all()
    """#

    private struct Fake {
        let executable: String
        let log: String
        let profile: String
        let workspace: String

        func received(_ method: String) -> [JSONValue] {
            guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }
                .compactMap { $0["recv"] }
                .filter { $0["method"]?.stringValue == method }
        }

        func answers() -> [JSONValue] {
            guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }
                .compactMap { $0["recv"] }
                .filter { $0["method"] == nil }
        }
    }

    private func makeFake(signedIn: Bool = true) throws -> Fake {
        let directory = EngineHarness.temporaryDirectory()
        let script = directory.appendingPathComponent("fakeagy.py")
        let log = directory.appendingPathComponent("agy.log").path
        try Self.fakeAgy.write(to: script, atomically: true, encoding: .utf8)
        let wrapper = directory.appendingPathComponent("agy")
        try "#!/bin/sh\nFAKE_AGY_LOG='\(log)' exec /usr/bin/env python3 '\(script.path)' \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let profile = directory.appendingPathComponent("profile", isDirectory: true)
        if signedIn {
            try FileManager.default.createDirectory(at: profile.appendingPathComponent("antigravity-acp"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: AntigravityProtocol.tokenPath(profile: profile.path), contents: Data("{}".utf8))
        }
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return Fake(executable: wrapper.path, log: log, profile: profile.path, workspace: workspace.path)
    }

    private func session(_ fake: Fake, interruptGrace: Duration = .seconds(5)) -> AntigravitySession {
        let executable = fake.executable
        return AntigravitySession(executablePath: { executable }, profile: fake.profile, interruptGrace: interruptGrace, mcpWarmupDelay: .zero)
    }

    private func config(_ fake: Fake, model: String = ModelSelection.configuredDefaultModel, runtime: RuntimeMode = .approvalRequired, resumeID: String? = nil) -> SessionConfig {
        SessionConfig(cwd: fake.workspace, modelSelection: ModelSelection(provider: .antigravity, model: model), runtimeMode: runtime, resumeID: resumeID)
    }

    private func input(_ text: String, model: String = ModelSelection.configuredDefaultModel, effort: String? = nil, runtime: RuntimeMode = .approvalRequired) -> TurnInput {
        var selection = ModelSelection(provider: .antigravity, model: model)
        if let effort { selection.options[ModelOptionID.effort] = effort }
        return TurnInput(text: text, attachments: [], modelSelection: selection, runtimeMode: runtime)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ProviderEvent] = []

        init(_ session: AntigravitySession) {
            Task { for await event in session.events { self.append(event) } }
        }

        var events: [ProviderEvent] { lock.withLock { stored } }
        private func append(_ event: ProviderEvent) { lock.withLock { stored.append(event) } }

        func wait(_ seconds: Double = 10, until condition: @Sendable ([ProviderEvent]) -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while !condition(events) {
                if ContinuousClock.now > deadline { return false }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return true
        }

        var outcome: ProviderTurnOutcome? {
            for case let .turnCompleted(outcome, _) in events { return outcome }
            return nil
        }

        var approvals: [ApprovalRequest] {
            events.compactMap { if case let .approvalRequested(request) = $0 { request } else { nil } }
        }

        var answer: String? {
            for case let .itemUpdated(item) in events {
                if case let .assistantMessage(text, true) = item.kind { return text }
            }
            return nil
        }
    }

    nonisolated private static func completed(_ events: [ProviderEvent]) -> Bool {
        events.contains { if case .turnCompleted = $0 { true } else { false } }
    }

    @Test func aTurnStreamsItsAnswerAndEndsCompleted() async throws {
        let fake = try makeFake()
        let session = session(fake)
        let recorder = Recorder(session)
        let id = try await session.start(config(fake))
        #expect(id == "s-new")

        _ = try await session.startTurn(input("hi"))
        #expect(await recorder.wait(until: Self.completed))
        #expect(recorder.outcome == .completed)
        #expect(recorder.answer == "Hello there")
        #expect(recorder.events.contains(.tokenUsage(TokenUsage(usedTokens: 1200, contextWindow: 1_048_576))))
        await session.close()
    }

    @Test func anAnswerArrivingRightBehindManyChunksKeepsEveryChunk() async throws {
        let fake = try makeFake()
        let session = session(fake)
        let recorder = Recorder(session)
        _ = try await session.start(config(fake))

        _ = try await session.startTurn(input("burst"))
        #expect(await recorder.wait(until: Self.completed))
        #expect(recorder.answer == String(repeating: "x", count: 2000))
        await session.close()
    }

    @Test func theSelectionReachesAgyAsConfigOptionsOnlyWhenItChanges() async throws {
        let fake = try makeFake()
        let session = session(fake)
        let recorder = Recorder(session)
        _ = try await session.start(config(fake, runtime: .autoAcceptEdits))
        _ = try await session.startTurn(input("hi", model: "gemini-3.8-flash", effort: "low", runtime: .autoAcceptEdits))
        #expect(await recorder.wait(until: Self.completed))

        let changes = fake.received("session/set_config_option").compactMap { message -> String? in
            guard let id = message["params"]?["configId"]?.stringValue, let value = message["params"]?["value"]?.stringValue else { return nil }
            return "\(id)=\(value)"
        }
        // "default" keeps agy's model; the mode is set at start, the model and effort with the turn.
        #expect(changes == ["mode=accept-edits", "model=gemini-3.8-flash", "thought_level=low"])
        #expect(fake.received("session/new").first?["params"]?["cwd"]?.stringValue == fake.workspace)
        await session.close()
    }

    @Test func anApprovedEditCompletesWithItsDiff() async throws {
        let fake = try makeFake()
        let session = session(fake)
        let recorder = Recorder(session)
        _ = try await session.start(config(fake))
        _ = try await session.startTurn(input("please edit"))

        #expect(await recorder.wait { events in events.contains { if case .approvalRequested = $0 { true } else { false } } })
        let approval = try #require(recorder.approvals.first)
        #expect(approval.kind == .fileChange)
        await session.respond(toApproval: approval.id, decision: .accept)

        #expect(await recorder.wait(until: Self.completed))
        #expect(recorder.outcome == .completed)
        #expect(fake.answers().first?["result"]?["outcome"]?["optionId"] == "allow")
        let edit = recorder.events.compactMap { event -> TurnItem? in
            if case let .itemUpdated(item) = event, item.id == "call_edit" { return item }
            return nil
        }.last
        guard case let .fileChange(changes)? = edit?.kind else { Issue.record("no edit item"); return }
        #expect(changes.first?.diff == "@@ -1,1 +1,1 @@\n-a\n+b")
        await session.close()
    }

    @Test func cancellingAnApprovalStopsTheTurn() async throws {
        let fake = try makeFake()
        let session = session(fake)
        let recorder = Recorder(session)
        _ = try await session.start(config(fake))
        _ = try await session.startTurn(input("please edit"))
        #expect(await recorder.wait { events in events.contains { if case .approvalRequested = $0 { true } else { false } } })

        await session.respond(toApproval: try #require(recorder.approvals.first).id, decision: .cancel)

        #expect(await recorder.wait(until: Self.completed))
        #expect(recorder.outcome == .interrupted)
        #expect(fake.answers().first?["result"]?["outcome"]?["outcome"] == "cancelled")
        await session.close()
    }

    @Test func fullAccessApprovesWithoutAsking() async throws {
        let fake = try makeFake()
        let session = session(fake)
        let recorder = Recorder(session)
        _ = try await session.start(config(fake, runtime: .fullAccess))
        _ = try await session.startTurn(input("please edit", runtime: .fullAccess))

        #expect(await recorder.wait(until: Self.completed))
        #expect(recorder.approvals.isEmpty)
        #expect(recorder.answer == "Edited.")
        await session.close()
    }

    @Test func stopSendsCancelAndEndsTheTurnInterrupted() async throws {
        let fake = try makeFake()
        let session = session(fake)
        let recorder = Recorder(session)
        _ = try await session.start(config(fake))
        _ = try await session.startTurn(input("slow work"))
        #expect(await recorder.wait { events in events.contains { if case .assistantDelta = $0 { true } else { false } } })

        await session.interrupt()

        #expect(await recorder.wait(until: Self.completed))
        #expect(recorder.outcome == .interrupted)
        #expect(fake.received("session/cancel").count == 1)
        await session.close()
    }

    @Test func anAgyThatIgnoresStopIsRetiredSoTheNextTurnRunsInAFreshProcess() async throws {
        let fake = try makeFake()
        let session = session(fake, interruptGrace: .milliseconds(200))
        let recorder = Recorder(session)
        _ = try await session.start(config(fake))
        _ = try await session.startTurn(input("stubborn work"))
        #expect(await recorder.wait { events in events.contains { if case .assistantDelta = $0 { true } else { false } } })

        await session.interrupt()

        let ended = await recorder.wait { events in events.contains { if case .sessionEnded = $0 { true } else { false } } }
        #expect(ended)
        #expect(recorder.outcome == .interrupted)
        // The unanswered prompt is gone with its process: this session takes no further turns.
        await #expect(throws: ProviderError.notStarted) {
            try await session.startTurn(input("hi"))
        }

        // What the engine does next: a new session resumes the conversation and answers normally.
        let next = self.session(fake)
        let nextRecorder = Recorder(next)
        _ = try await next.start(config(fake, resumeID: "s-known"))
        _ = try await next.startTurn(input("hi"))
        #expect(await nextRecorder.wait(until: Self.completed))
        #expect(nextRecorder.answer == "Hello there")
        await next.close()
    }

    @Test func aResumedConversationLoadsWithoutReplayingItsHistory() async throws {
        let fake = try makeFake()
        let session = session(fake)
        let recorder = Recorder(session)
        let id = try await session.start(config(fake, resumeID: "s-known"))
        #expect(id == "s-known")
        try await Task.sleep(for: .milliseconds(100))
        #expect(!recorder.events.contains { if case .assistantDelta = $0 { true } else { false } })
        #expect(fake.received("session/new").isEmpty)
        await session.close()
    }

    @Test func aConversationAgyNoLongerHasStartsFresh() async throws {
        let fake = try makeFake()
        let session = session(fake)
        let id = try await session.start(config(fake, resumeID: "s-gone"))
        #expect(id == "s-new")
        await session.close()
    }

    @Test func withoutAGoogleSignInNothingStarts() async throws {
        let fake = try makeFake(signedIn: false)
        await #expect(throws: ProviderError.self) {
            try await session(fake).start(config(fake))
        }
        #expect(fake.received("initialize").isEmpty)
    }

    @Test func followUpsAreQueuedAndRewindIsRefused() async throws {
        let fake = try makeFake()
        let session = session(fake)
        _ = try await session.start(config(fake))
        await #expect(throws: ProviderError.noActiveTurn) {
            try await session.steer(input("more"))
        }
        await #expect(throws: ProviderError.self) {
            try await session.rollback(beforeTurn: 1, providerTurnID: "antigravity-turn-1")
        }
        await session.close()
    }

    @Test func startingWritesResolvedMCPServersToProfileMCPConfigJSON() async throws {
        let fake = try makeFake()
        let session = session(fake)
        var sessionConfig = config(fake)
        sessionConfig.mcpServers = [
            MCPServerSpec(name: "asana", transport: .stdio(command: "/app/SopranoAgents", args: ["mcp", "http-proxy", "--url", "https://mcp.asana.com/v2/mcp"])),
            MCPServerSpec(name: "knip", transport: .stdio(command: "npx", args: ["-y", "@knip/mcp"], env: ["PATH": "/opt/homebrew/bin"])),
        ]
        _ = try await session.start(sessionConfig)
        await session.close()

        let mcpPath = AntigravityProtocol.mcpConfigPath(profile: fake.profile)
        let text = try String(contentsOfFile: mcpPath, encoding: .utf8)
        let parsed = try JSONValue.parse(text)
        let servers = parsed["mcpServers"]?.objectValue ?? [:]
        #expect(servers["asana"]?["command"]?.stringValue == "/app/SopranoAgents")
        #expect(servers["knip"]?["command"]?.stringValue == "npx")
        #expect(servers["knip"]?["env"]?["PATH"]?.stringValue == "/opt/homebrew/bin")
    }
}
