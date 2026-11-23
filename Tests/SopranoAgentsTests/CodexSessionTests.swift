import AppKit
import Testing
@testable import SopranoAgentsCore

/// `CodexSession` and `CodexDriver` against a fake `codex` CLI speaking `codex app-server --stdio`
/// (initialize → initialized, account/read, model/list, skills/list, thread/start & resume,
/// turn/start with Plan mode, turn/steer, turn/interrupt, approvals, user input, compact, rollback).
@MainActor
struct CodexSessionTests {
    private static let fakeCodex = #"""
    #!/usr/bin/env python3
    import json, os, sys, threading

    if "--version" in sys.argv:
        print("codex-cli 0.144.6")
        sys.exit(0)

    log = os.environ["FAKE_CODEX_LOG"]
    def record(o):
        with open(log, "a") as f:
            f.write(json.dumps(o) + "\n")
    record({"args": sys.argv[1:], "codex_home": os.environ.get("CODEX_HOME")})

    lock = threading.Lock()
    def out(o):
        with lock:
            sys.stdout.write(json.dumps(o) + "\n")
            sys.stdout.flush()

    def notify(method, params):
        out({"jsonrpc": "2.0", "method": method, "params": params})

    answers = {}
    answered = threading.Condition()
    interrupted = threading.Event()
    turn_counter = 0
    turns = []

    def await_answer(rid):
        with answered:
            while rid not in answers and not interrupted.is_set():
                answered.wait(0.05)
            return answers.get(rid)

    def run_turn(tid, turn_id, text, output_schema):
        interrupted.clear()
        notify("turn/started", {"threadId": tid, "turn": {"id": turn_id, "items": [], "status": "inProgress"}})
        if output_schema is not None:
            notify("item/agentMessage/delta", {"threadId": tid, "turnId": turn_id, "itemId": "gen-1", "delta": '{"title":"Fix login"}'})
            notify("item/completed", {"threadId": tid, "turnId": turn_id, "item": {"type": "agentMessage", "id": "gen-1", "text": '{"title":"Fix login"}', "phase": "final_answer"}})
            notify("turn/completed", {"threadId": tid, "turn": {"id": turn_id, "items": [], "status": "completed"}})
            return
        if "approve-cmd" in text:
            out({"jsonrpc": "2.0", "id": "req-cmd", "method": "item/commandExecution/requestApproval",
                 "params": {"threadId": tid, "turnId": turn_id, "itemId": "cmd-1", "command": "rm -rf tmp", "reason": "Cleanup"}})
            ans = await_answer("req-cmd") or {}
            if ans.get("decision") == "accept":
                notify("item/agentMessage/delta", {"threadId": tid, "turnId": turn_id, "itemId": "m-cmd", "delta": "Cleaned."})
                notify("turn/completed", {"threadId": tid, "turn": {"id": turn_id, "items": [], "status": "completed"}})
            else:
                notify("turn/completed", {"threadId": tid, "turn": {"id": turn_id, "items": [], "status": "interrupted"}})
            return
        if "approve-edit" in text:
            out({"jsonrpc": "2.0", "id": "req-edit", "method": "item/fileChange/requestApproval",
                 "params": {"threadId": tid, "turnId": turn_id, "itemId": "fc-1", "reason": "Edit file"}})
            ans = await_answer("req-edit") or {}
            record({"edit_decision": ans.get("decision")})
            notify("item/agentMessage/delta", {"threadId": tid, "turnId": turn_id, "itemId": "m-edit", "delta": "Edited."})
            notify("turn/completed", {"threadId": tid, "turn": {"id": turn_id, "items": [], "status": "completed"}})
            return
        if "ask-user" in text:
            out({"jsonrpc": "2.0", "id": "req-ask", "method": "item/tool/requestUserInput",
                 "params": {"threadId": tid, "turnId": turn_id, "itemId": "u-1", "questions": [
                     {"id": "q1", "header": "Mode", "question": "Fast or safe?", "isOther": False, "isSecret": False,
                      "options": [{"label": "Fast", "description": "Quick"}, {"label": "Safe", "description": "Careful"}]}
                 ], "autoResolutionMs": None}})
            ans = await_answer("req-ask") or {}
            record({"user_answers": ans})
            notify("item/agentMessage/delta", {"threadId": tid, "turnId": turn_id, "itemId": "m-ask", "delta": "Got it."})
            notify("turn/completed", {"threadId": tid, "turn": {"id": turn_id, "items": [], "status": "completed"}})
            return
        if "slow" in text:
            notify("item/agentMessage/delta", {"threadId": tid, "turnId": turn_id, "itemId": "m-slow", "delta": "Working"})
            interrupted.wait(5)
            status = "interrupted" if interrupted.is_set() else "completed"
            notify("turn/completed", {"threadId": tid, "turn": {"id": turn_id, "items": [], "status": status}})
            return
        notify("item/agentMessage/delta", {"threadId": tid, "turnId": turn_id, "itemId": f"m-{turn_id}", "delta": "Hello from Codex."})
        notify("thread/tokenUsage/updated", {"threadId": tid, "turnId": turn_id, "tokenUsage": {
            "total": {"totalTokens": 1200, "inputTokens": 1000, "cachedInputTokens": 0, "outputTokens": 200, "reasoningOutputTokens": 0},
            "last": {"totalTokens": 1200, "inputTokens": 1000, "cachedInputTokens": 0, "outputTokens": 200, "reasoningOutputTokens": 0},
            "modelContextWindow": 258000
        }})
        notify("turn/completed", {"threadId": tid, "turn": {"id": turn_id, "items": [], "status": "completed"}})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        record(msg)
        if "method" not in msg:
            with answered:
                answers[str(msg.get("id"))] = msg.get("result")
                answered.notify_all()
            continue
        method = msg["method"]
        params = msg.get("params") or {}
        if method == "initialize":
            out({"jsonrpc": "2.0", "id": msg["id"], "result": {"userAgent": "codex-test", "codexHome": "/tmp", "platformFamily": "unix", "platformOs": "macos"}})
        elif method == "initialized":
            pass
        elif method == "account/read":
            if os.environ.get("FAKE_CODEX_UNAUTH") == "1":
                out({"jsonrpc": "2.0", "id": msg["id"], "result": {"account": None, "requiresOpenaiAuth": True}})
            else:
                out({"jsonrpc": "2.0", "id": msg["id"], "result": {"account": {"type": "chatgpt", "email": "dev@example.com", "planType": "pro"}, "requiresOpenaiAuth": True}})
        elif method == "model/list":
            out({"jsonrpc": "2.0", "id": msg["id"], "result": {"data": [
                {"id": "gpt-5.6-sol", "model": "gpt-5.6-sol", "displayName": "GPT-5.6-Sol", "hidden": False, "isDefault": True,
                 "defaultReasoningEffort": "high",
                 "supportedReasoningEfforts": [{"reasoningEffort": "low", "description": "Fast"}, {"reasoningEffort": "high", "description": "Deep"}],
                 "serviceTiers": [{"id": "fast", "name": "Fast", "description": "Fast"}], "additionalSpeedTiers": [], "defaultServiceTier": None}
            ], "nextCursor": None}})
        elif method == "skills/list":
            out({"jsonrpc": "2.0", "id": msg["id"], "result": {"data": [
                {"cwd": (params.get("cwds") or [""])[0], "skills": [
                    {"name": "scan", "description": "Scan page", "path": "/skills/scan/SKILL.md", "scope": "user", "enabled": True}
                ], "errors": []}
            ]}})
        elif method == "thread/start":
            out({"jsonrpc": "2.0", "id": msg["id"], "result": {
                "thread": {"id": "thr-new", "turns": []}, "model": "gpt-5.6-sol", "modelProvider": "openai", "reasoningEffort": "high"
            }})
        elif method == "thread/resume":
            tid = params.get("threadId", "thr-resumed")
            out({"jsonrpc": "2.0", "id": msg["id"], "result": {
                "thread": {"id": tid, "turns": [{"id": "turn-prev"}]}, "model": "gpt-5.6-sol", "modelProvider": "openai", "reasoningEffort": "high"
            }})
        elif method == "turn/start":
            turn_counter += 1
            turn_id = f"turn-{turn_counter}"
            turns.append(turn_id)
            out({"jsonrpc": "2.0", "id": msg["id"], "result": {"turn": {"id": turn_id, "items": [], "status": "inProgress"}}})
            text = " ".join(i.get("text", "") for i in params.get("input", []) if i.get("type") == "text")
            threading.Thread(target=run_turn, args=(params["threadId"], turn_id, text, params.get("outputSchema")), daemon=True).start()
        elif method == "turn/steer":
            out({"jsonrpc": "2.0", "id": msg["id"], "result": {"turnId": params.get("expectedTurnId")}})
        elif method == "turn/interrupt":
            interrupted.set()
            with answered:
                answered.notify_all()
            out({"jsonrpc": "2.0", "id": msg["id"], "result": {}})
        elif method == "thread/compact/start":
            out({"jsonrpc": "2.0", "id": msg["id"], "result": {}})
            notify("thread/compacted", {"threadId": params["threadId"], "turnId": "compact-1"})
            notify("turn/completed", {"threadId": params["threadId"], "turn": {"id": "compact-1", "items": [], "status": "completed"}})
        elif method == "thread/rollback":
            n = int(params.get("numTurns", 1))
            kept = turns[:-n] if n < len(turns) else []
            out({"jsonrpc": "2.0", "id": msg["id"], "result": {"thread": {"id": params["threadId"], "turns": [{"id": t} for t in kept]}}})
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sa-codex-test-\(UUID().uuidString)", isDirectory: true)
        let workspace = dir.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake-codex")
        try Self.fakeCodex.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let log = dir.appendingPathComponent("log.jsonl")
        return Harness(dir: dir, script: script, log: log, workspace: workspace.path)
    }

    @Test func driverProbesCatalogAuthAndGeneratesJSON() async throws {
        let fake = try makeHarness()
        defer { try? FileManager.default.removeItem(at: fake.dir) }

        let driver = CodexDriver(
            executablePath: { fake.script.path },
            launchAdjustments: { ProviderLaunchAdjustments(environment: ["FAKE_CODEX_LOG": fake.log.path, "CODEX_HOME": "/tmp/custom-codex"]) }
        )
        let status = await driver.probe()
        #expect(status.health == .ready)
        #expect(status.version == "0.144.6 · ChatGPT Pro")
        #expect(status.models.count == 2)
        #expect(status.models[0].slug == ModelSelection.configuredDefaultModel)
        #expect(status.models[1].slug == "gpt-5.6-sol")

        let skills = await driver.commands(directory: fake.workspace)
        #expect(skills?.count == 1)
        #expect(skills?[0].insertText == "/skill:scan ")

        let generated = try await driver.generateJSON(
            prompt: "Title",
            schema: ["type": "object", "properties": ["title": ["type": "string"]]],
            model: "gpt-5.6-sol",
            cwd: fake.workspace
        )
        #expect(generated["title"]?.stringValue == "Fix login")

        let unauthDriver = CodexDriver(
            executablePath: { fake.script.path },
            launchAdjustments: { ProviderLaunchAdjustments(environment: ["FAKE_CODEX_LOG": fake.log.path, "FAKE_CODEX_UNAUTH": "1"]) }
        )
        let unauth = await unauthDriver.probe()
        #expect(unauth.health == .unauthenticated)
    }

    @Test func sessionRunsPlanModeApprovalsUserInputSteerCompactAndRollback() async throws {
        let fake = try makeHarness()
        defer { try? FileManager.default.removeItem(at: fake.dir) }

        let session = CodexSession(
            executablePath: { fake.script.path },
            launchAdjustments: { ProviderLaunchAdjustments(environment: ["FAKE_CODEX_LOG": fake.log.path]) }
        )
        let collected = EventCollector()
        let consumer = Task {
            for await event in session.events {
                await collected.append(event)
            }
        }
        defer { consumer.cancel() }

        let selection = ModelSelection(provider: .codex, model: "gpt-5.6-sol", options: [ModelOptionID.effort: "high"])
        let threadID = try await session.start(SessionConfig(cwd: fake.workspace, modelSelection: selection, runtimeMode: .autoAcceptEdits))
        #expect(threadID == "thr-new")

        // 1. Plan mode turn
        let turn1 = try await session.startTurn(TurnInput(text: "Plan the auth fix", attachments: [], modelSelection: selection, runtimeMode: .autoAcceptEdits, interactionMode: .plan))
        #expect(turn1 == "turn-1")
        #expect(await collected.waitFor(countOfCompletions: 1))

        // 2. File change approval is auto-approved in .autoAcceptEdits
        _ = try await session.startTurn(TurnInput(text: "approve-edit", attachments: [], modelSelection: selection, runtimeMode: .autoAcceptEdits, interactionMode: .standard))
        #expect(await collected.waitFor(countOfCompletions: 2))

        // 3. Command approval prompts in .autoAcceptEdits and accepts on respond
        _ = try await session.startTurn(TurnInput(text: "approve-cmd", attachments: [], modelSelection: selection, runtimeMode: .autoAcceptEdits))
        let approvalID = try #require(await collected.waitForApprovalID())
        await session.respond(toApproval: approvalID, decision: .accept)
        #expect(await collected.waitFor(countOfCompletions: 3))

        // 4. Structured user input
        _ = try await session.startTurn(TurnInput(text: "ask-user", attachments: [], modelSelection: selection, runtimeMode: .autoAcceptEdits))
        let inputID = try #require(await collected.waitForUserInputID())
        await session.answer(userInput: inputID, answers: ["q1": ["Fast"]])
        #expect(await collected.waitFor(countOfCompletions: 4))

        // 5. Steer & interrupt on slow turn
        _ = try await session.startTurn(TurnInput(text: "slow work", attachments: [], modelSelection: selection, runtimeMode: .autoAcceptEdits))
        try await session.steer(TurnInput(text: "also check tests", attachments: [], modelSelection: selection, runtimeMode: .autoAcceptEdits))
        await session.interrupt()
        #expect(await collected.waitFor(countOfCompletions: 5))

        // 6. Compact & rollback
        try await session.compact()
        #expect(await collected.waitFor(countOfCompletions: 6))
        try await session.rollback(beforeTurn: 2, providerTurnID: "turn-2")

        await session.close()

        let recorded = fake.recorded()
        let turnStarts = recorded.filter { $0["method"]?.stringValue == "turn/start" }
        #expect(turnStarts.first?["params"]?["collaborationMode"]?["mode"]?.stringValue == "plan")
        #expect(turnStarts.dropFirst().first?["params"]?["collaborationMode"]?["mode"]?.stringValue == "default")
        #expect(recorded.contains { $0["edit_decision"]?.stringValue == "accept" })
        #expect(recorded.contains { $0["method"]?.stringValue == "turn/steer" })
        #expect(recorded.contains { $0["method"]?.stringValue == "thread/compact/start" })
        let rollback = recorded.first { $0["method"]?.stringValue == "thread/rollback" }
        #expect(rollback?["params"]?["numTurns"]?.intValue == 4)
    }
}

private actor EventCollector {
    private var events: [ProviderEvent] = []

    func append(_ event: ProviderEvent) {
        events.append(event)
    }

    func waitFor(countOfCompletions target: Int) async -> Bool {
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
