import AppKit
import Testing
@testable import SopranoAgentsCore

/// `ClaudeSession` and `ClaudeDriver` against a fake `claude` CLI speaking Claude Code's NDJSON
/// `stream-json` + `control_request` / `control_response` protocol.
@MainActor
struct ClaudeSessionTests {
    private static let fakeClaude = #"""
    #!/usr/bin/env python3
    import json, os, sys, threading

    if "--version" in sys.argv:
        print("2.1.325 (Claude Code)")
        sys.exit(0)

    if len(sys.argv) >= 3 and sys.argv[1] == "auth" and sys.argv[2] == "status":
        if os.environ.get("FAKE_CLAUDE_UNAUTH") == "1":
            print(json.dumps({"loggedIn": False}))
        else:
            print(json.dumps({"loggedIn": True, "subscriptionType": "max"}))
        sys.exit(0)

    if "--json-schema" in sys.argv:
        _ = sys.stdin.read()
        print(json.dumps({"type": "result", "subtype": "success", "structured_output": {"title": "Add Claude Code"}}))
        sys.exit(0)

    log = os.environ["FAKE_CLAUDE_LOG"]
    def record(o):
        with open(log, "a") as f:
            f.write(json.dumps(o) + "\n")
    record({"args": sys.argv[1:]})

    lock = threading.Lock()
    def out(o):
        with lock:
            sys.stdout.write(json.dumps(o) + "\n")
            sys.stdout.flush()

    answers = {}
    answered = threading.Condition()
    interrupted = threading.Event()

    def await_control(rid):
        with answered:
            while rid not in answers and not interrupted.is_set():
                answered.wait(0.05)
            return answers.get(rid)

    def run_turn(text):
        interrupted.clear()
        if "approve-cmd" in text:
            out({"type": "control_request", "request_id": "perm-1", "request": {
                "subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "tu-1",
                "input": {"command": "echo hi"}, "permission_suggestions": [{"type": "addRules"}]
            }})
            ans = await_control("perm-1") or {}
            record({"perm_reply": ans})
            out({"type": "assistant", "session_id": "claude-s1", "message": {"id": "m-perm", "role": "assistant", "content": [{"type": "text", "text": "Approved and ran."}], "stop_reason": "end_turn"}})
            out({"type": "result", "subtype": "success", "is_error": False, "session_id": "claude-s1", "result": "Approved and ran."})
            return
        if "ask-user" in text:
            out({"type": "control_request", "request_id": "ask-1", "request": {
                "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "tool_use_id": "tu-ask",
                "input": {"questions": [{"header": "DB", "question": "Pick DB", "multiSelect": False, "options": [{"label": "SQLite", "description": "Local"}]}]}
            }})
            ans = await_control("ask-1") or {}
            record({"ask_reply": ans})
            out({"type": "result", "subtype": "success", "is_error": False, "session_id": "claude-s1", "result": "Using SQLite."})
            return
        if "slow" in text:
            out({"type": "stream_event", "event": {"type": "message_start", "message": {"id": "m-slow"}}})
            out({"type": "stream_event", "event": {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}})
            out({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Working..."}}})
            interrupted.wait(5)
            if interrupted.is_set():
                out({"type": "result", "subtype": "error_during_execution", "is_error": True, "session_id": "claude-s1", "result": "Interrupted by user"})
            else:
                out({"type": "result", "subtype": "success", "is_error": False, "session_id": "claude-s1", "result": "Done"})
            return
        if text.strip() == "/compact":
            out({"type": "system", "subtype": "compact_boundary", "session_id": "claude-s1"})
            out({"type": "result", "subtype": "success", "is_error": False, "session_id": "claude-s1", "result": "Compacted."})
            return
        out({"type": "stream_event", "event": {"type": "message_start", "message": {"id": "m-ok"}}})
        out({"type": "stream_event", "event": {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}})
        out({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello from Claude."}}})
        out({"type": "assistant", "session_id": "claude-s1", "message": {"id": "m-ok", "role": "assistant", "content": [{"type": "text", "text": "Hello from Claude."}], "stop_reason": "end_turn"}})
        out({"type": "result", "subtype": "success", "is_error": False, "session_id": "claude-s1", "result": "Hello from Claude.",
             "usage": {"input_tokens": 500, "output_tokens": 100}, "modelUsage": {"claude-opus-5-5": {"contextWindow": 200000}}})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        record(msg)
        kind = msg.get("type")
        if kind == "control_response":
            resp = msg.get("response") or {}
            with answered:
                answers[str(resp.get("request_id"))] = resp.get("response")
                answered.notify_all()
        elif kind == "control_request":
            rid = msg["request_id"]
            req = msg.get("request") or {}
            sub = req.get("subtype")
            if sub == "initialize":
                out({"type": "system", "subtype": "init", "session_id": "claude-s1"})
                out({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {
                    "claude_code_version": "2.1.325",
                    "account": {"subscriptionType": "max"},
                    "models": [
                        {"value": "default", "displayName": "Default", "description": "Opus 5.5", "supportedEffortLevels": ["low", "high"], "supportsFastMode": True},
                        {"value": "opus", "displayName": "Opus 5.5", "supportedEffortLevels": ["low", "high"], "supportsFastMode": True},
                    ],
                    "commands": [{"name": "ship", "description": "Ship changes (user)", "argumentHint": ""}],
                }}})
            elif sub == "set_model":
                out({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {"model": req.get("model")}}})
            elif sub == "set_permission_mode":
                out({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {"mode": req.get("mode")}}})
            elif sub == "interrupt":
                interrupted.set()
                with answered:
                    answered.notify_all()
                out({"type": "control_response", "response": {"subtype": "success", "request_id": rid, "response": {}}})
        elif kind == "user":
            content = msg.get("message", {}).get("content", "")
            text = content if isinstance(content, str) else " ".join(b.get("text", "") for b in content if b.get("type") == "text")
            if interrupted.is_set() or threading.active_count() == 1:
                threading.Thread(target=run_turn, args=(text,), daemon=True).start()
    """#

    private struct Harness {
        let dir: URL
        let script: URL
        let log: URL
        let workspace: String

        func recorded() -> [JSONValue] {
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).compactMap { try? JSONValue.parse(String($0)) }
        }
    }

    private func makeHarness() throws -> Harness {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sa-claude-test-\(UUID().uuidString)", isDirectory: true)
        let workspace = dir.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake-claude")
        try Self.fakeClaude.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let log = dir.appendingPathComponent("log.jsonl")
        return Harness(dir: dir, script: script, log: log, workspace: workspace.path)
    }

    @Test func driverProbesCatalogAuthCommandsAndGeneratesJSON() async throws {
        let fake = try makeHarness()
        defer { try? FileManager.default.removeItem(at: fake.dir) }

        let driver = ClaudeDriver(
            executablePath: { fake.script.path },
            launchAdjustments: { ProviderLaunchAdjustments(environment: ["FAKE_CLAUDE_LOG": fake.log.path]) }
        )
        let status = await driver.probe()
        #expect(status.health == .ready)
        #expect(status.version == "2.1.325 · Claude Max")
        #expect(status.models.count == 2)
        #expect(status.models[0].slug == ModelSelection.configuredDefaultModel)
        #expect(status.models[1].slug == "opus")

        let commands = await driver.commands(directory: fake.workspace)
        #expect(commands?.count == 1)
        #expect(commands?[0].insertText == "/ship ")

        let json = try await driver.generateJSON(
            prompt: "Title",
            schema: ["type": "object", "properties": ["title": ["type": "string"]]],
            model: "opus",
            cwd: fake.workspace
        )
        #expect(json["title"]?.stringValue == "Add Claude Code")

        let unauthDriver = ClaudeDriver(
            executablePath: { fake.script.path },
            launchAdjustments: { ProviderLaunchAdjustments(environment: ["FAKE_CLAUDE_LOG": fake.log.path, "FAKE_CLAUDE_UNAUTH": "1"]) }
        )
        let unauth = await unauthDriver.probe()
        #expect(unauth.health == .unauthenticated)
    }

    @Test func sessionRunsPlanModeApprovalsQuestionsInterruptAndCompact() async throws {
        let fake = try makeHarness()
        defer { try? FileManager.default.removeItem(at: fake.dir) }

        let session = ClaudeSession(
            executablePath: { fake.script.path },
            launchAdjustments: { ProviderLaunchAdjustments(environment: ["FAKE_CLAUDE_LOG": fake.log.path]) }
        )
        let collector = ClaudeEventCollector()
        let consumer = Task {
            for await event in session.events {
                await collector.append(event)
            }
        }
        defer { consumer.cancel() }

        let selection = ModelSelection(provider: .claude, model: "opus", options: [ModelOptionID.effort: "high"])
        let sessionID = try await session.start(SessionConfig(
            cwd: fake.workspace,
            modelSelection: selection,
            runtimeMode: .autoAcceptEdits,
            mcpServers: [MCPServerSpec(name: "browser", transport: .stdio(command: "/bin/browser"))]
        ))
        #expect(sessionID == "claude-s1")

        // 1. Plan mode switches permission mode to "plan"
        _ = try await session.startTurn(TurnInput(text: "Plan the change", attachments: [], modelSelection: selection, runtimeMode: .autoAcceptEdits, interactionMode: .plan))
        #expect(await collector.waitFor(completions: 1))

        // 2. Approval request
        _ = try await session.startTurn(TurnInput(text: "approve-cmd", attachments: [], modelSelection: selection, runtimeMode: .autoAcceptEdits, interactionMode: .standard))
        let approvalID = try #require(await collector.waitForApprovalID())
        await session.respond(toApproval: approvalID, decision: .acceptForSession)
        #expect(await collector.waitFor(completions: 2))

        // 3. AskUserQuestion
        _ = try await session.startTurn(TurnInput(text: "ask-user", attachments: [], modelSelection: selection, runtimeMode: .autoAcceptEdits))
        let inputID = try #require(await collector.waitForUserInputID())
        await session.answer(userInput: inputID, answers: ["q1": ["SQLite"]])
        #expect(await collector.waitFor(completions: 3))

        // 4. Interrupt slow turn
        _ = try await session.startTurn(TurnInput(text: "slow task", attachments: [], modelSelection: selection, runtimeMode: .autoAcceptEdits))
        await session.interrupt()
        #expect(await collector.waitFor(completions: 4))

        // 5. Compact
        try await session.compact()
        #expect(await collector.waitFor(completions: 5))

        await session.close()

        let recorded = fake.recorded()
        let args = recorded.first?["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(args.contains("--mcp-config"))
        let modeChanges = recorded.compactMap { $0["request"]?["subtype"]?.stringValue == "set_permission_mode" ? $0["request"]?["mode"]?.stringValue : nil }
        #expect(modeChanges.contains("plan"))
        #expect(modeChanges.contains("acceptEdits"))
        #expect(recorded.contains { $0["perm_reply"]?["behavior"]?.stringValue == "allow" })
        #expect(recorded.contains { $0["ask_reply"]?["updatedInput"]?["answers"]?["Pick DB"]?.stringValue == "SQLite" })
    }
}

private actor ClaudeEventCollector {
    private var events: [ProviderEvent] = []

    func append(_ event: ProviderEvent) {
        events.append(event)
    }

    func waitFor(completions target: Int) async -> Bool {
        for _ in 0..<200 {
            let count = events.reduce(into: 0) { sum, event in
                if case .turnCompleted = event { sum += 1 }
            }
            if count >= target { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    func waitForApprovalID() async -> String? {
        for _ in 0..<200 {
            for event in events.reversed() {
                if case let .approvalRequested(request) = event { return request.id }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    func waitForUserInputID() async -> String? {
        for _ in 0..<200 {
            for event in events.reversed() {
                if case let .userInputRequested(request) = event { return request.id }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }
}
