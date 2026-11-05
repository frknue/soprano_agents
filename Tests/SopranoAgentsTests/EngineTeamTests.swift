import AppKit
import Testing
@testable import SopranoAgentsCore

@MainActor
struct EngineTeamTests {
    private func teammate(_ engine: AgentEngine, _ name: String, handle: String, exports: Bool = false) throws -> String {
        try engine.createTeammate(TeammateDraft(
            name: name, handle: handle, role: "Owns \(handle)", instructions: "Be brief.", projectID: nil, exportsToOmp: exports
        )).threadID
    }

    private func call(_ id: String, to handle: String, _ message: String) -> ProviderEvent {
        .hostToolCall(HostToolCall(id: id, toolCallID: "tool-\(id)", name: TeamTools.message, arguments: ["to": .string(handle), "message": .string(message)]))
    }

    private func answer(_ session: ScriptedSession, _ text: String) {
        session.emit(.itemUpdated(TurnItem(id: "answer-\(text.count)", kind: .assistantMessage(text: text, isFinal: true), status: .completed)))
        session.emit(.turnCompleted(outcome: .completed, error: nil))
    }

    /// The session of the conversation that runs in `threadID`'s working directory.
    private func session(of threadID: String, _ engine: AgentEngine, _ driver: ScriptedDriver) -> ScriptedSession? {
        guard let thread = engine.thread(threadID) else { return nil }
        let cwd = engine.workingDirectory(for: thread)
        return driver.sessions.last { $0.configs.first?.cwd == cwd }
    }

    @Test func aThreadsTeamMessageBecomesATeammateTurnWhoseAnswerIsTheReply() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let cto = try teammate(engine, "CTO", handle: "cto")
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "Plan the release", attachments: [])
        let caller = try #require(session(of: threadID, engine, driver))
        #expect(caller.configs.first?.hostTools.map(\.name) == [TeamTools.message, TeamTools.list, TeamTools.activity])
        #expect(caller.configs.first?.systemPromptFile == nil)

        caller.emit(call("h1", to: "cto", "Is the schema change safe?"))

        #expect(await EngineHarness.eventually { self.session(of: cto, engine, driver)?.turns.count == 1 })
        let teammateSession = try #require(session(of: cto, engine, driver))
        let config = try #require(teammateSession.configs.first)
        let persona = try String(contentsOfFile: try #require(config.systemPromptFile), encoding: .utf8)
        #expect(persona.contains("You are CTO (`cto`)"))
        #expect(persona.contains("Be brief."))
        let overlay = try String(contentsOfFile: try #require(config.configOverlays.first), encoding: .utf8)
        #expect(overlay.contains("backend: mnemopi"))
        let prompt = teammateSession.turns[0].text
        #expect(prompt.contains("from the user's thread “Thread”]\nIs the schema change safe?"))
        #expect(prompt.contains("sent back to Thread as your reply"))
        #expect(engine.thread(cto)?.turns.first?.userMessage.sender == MessageSender(kind: .thread, threadID: threadID, name: "Thread"))
        #expect(caller.hostToolResults.isEmpty)

        answer(teammateSession, "Safe: it is additive.")

        #expect(await EngineHarness.eventually { caller.hostToolResults.count == 1 })
        #expect(caller.hostToolResults.first?.id == "h1")
        // The reply names what the teammate's turn changed (its checkpoint).
        #expect(caller.hostToolResults.first?.result == HostToolResult(text: "Safe: it is additive.\n\n[CTO changed 1 file: README.md]"))
    }

    @Test func aMessageToABusyTeammateWaitsForItsOwnTurn() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let cto = try teammate(engine, "CTO", handle: "cto")
        try await engine.send(cto, text: "Review the auth module", attachments: [])
        let teammateSession = try #require(session(of: cto, engine, driver))
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "Ship it", attachments: [])
        let caller = try #require(session(of: threadID, engine, driver))

        caller.emit(call("h1", to: "CTO", "Can we ship?"))
        #expect(await EngineHarness.eventually { engine.thread(cto)?.queue.count == 1 })
        #expect(teammateSession.steers.isEmpty)

        answer(teammateSession, "Auth looks fine.")
        #expect(await EngineHarness.eventually { teammateSession.turns.count == 2 })
        #expect(caller.hostToolResults.isEmpty)

        answer(teammateSession, "Yes, ship it.")
        #expect(await EngineHarness.eventually { caller.hostToolResults.count == 1 })
        #expect(caller.hostToolResults.first?.result.text.hasPrefix("Yes, ship it.") == true)
    }

    @Test func aTeammateCannotMessageTheTeammateWaitingForIt() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let cto = try teammate(engine, "CTO", handle: "cto")
        let frontend = try teammate(engine, "Frontend", handle: "frontend")
        try await engine.send(cto, text: "Ask frontend about the layout", attachments: [])
        let ctoSession = try #require(session(of: cto, engine, driver))

        ctoSession.emit(call("h1", to: "frontend", "Which layout?"))
        #expect(await EngineHarness.eventually { self.session(of: frontend, engine, driver)?.turns.count == 1 })
        let frontendSession = try #require(session(of: frontend, engine, driver))

        frontendSession.emit(call("h2", to: "cto", "What do you prefer?"))
        #expect(await EngineHarness.eventually { frontendSession.hostToolResults.count == 1 })
        let refusal = try #require(frontendSession.hostToolResults.first?.result)
        #expect(refusal.isError)
        #expect(refusal.text.contains("CTO is waiting for your reply"))
        #expect(engine.thread(cto)?.queue.isEmpty == true)

        frontendSession.emit(call("h3", to: "frontend", "Hello me"))
        #expect(await EngineHarness.eventually { frontendSession.hostToolResults.count == 2 })
        #expect(frontendSession.hostToolResults.last?.result.isError == true)
    }

    @Test func aCancelledMessageIsWithdrawnOrStopsTheTurnWorkingOnIt() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let cto = try teammate(engine, "CTO", handle: "cto")
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "Plan", attachments: [])
        let caller = try #require(session(of: threadID, engine, driver))

        caller.emit(call("h1", to: "cto", "First question"))
        #expect(await EngineHarness.eventually { self.session(of: cto, engine, driver)?.turns.count == 1 })
        let teammateSession = try #require(session(of: cto, engine, driver))
        caller.emit(call("h2", to: "cto", "Second question"))
        #expect(await EngineHarness.eventually { engine.thread(cto)?.queue.count == 1 })

        caller.emit(.hostToolCancelled(id: "h2"))
        #expect(await EngineHarness.eventually { engine.thread(cto)?.queue.isEmpty == true })
        caller.emit(.hostToolCancelled(id: "h1"))
        #expect(await EngineHarness.eventually { teammateSession.interrupts == 1 })
        #expect(caller.hostToolResults.isEmpty)
    }

    @Test func aMessageCancelledWhileTheTeammateRewindsNeverStartsWork() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let cto = try teammate(engine, "CTO", handle: "cto")
        try await engine.send(cto, text: "Draft the plan", attachments: [])
        let teammateSession = try #require(session(of: cto, engine, driver))
        answer(teammateSession, "Plan drafted.")
        #expect(await EngineHarness.eventually { engine.thread(cto)?.isRunning == false })
        let firstTurn = try #require(engine.thread(cto)?.turns.first?.id)
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "Plan", attachments: [])
        let caller = try #require(session(of: threadID, engine, driver))

        let gate = Gate()
        teammateSession.rollbackGate = { await gate.wait() }
        let rewind = Task { _ = try? await engine.revert(cto, toBeforeTurn: firstTurn, restoreFiles: false) }
        #expect(await EngineHarness.eventually { teammateSession.rollbacks.count == 1 })
        caller.emit(call("h1", to: "cto", "Is the plan done?"))
        #expect(await EngineHarness.eventually { engine.runtime.teamDeliveries.count == 1 })
        caller.emit(.hostToolCancelled(id: "h1"))
        #expect(await EngineHarness.eventually { engine.runtime.teamWaits.isEmpty })
        gate.open()
        await rewind.value
        #expect(await EngineHarness.eventually { engine.runtime.teamDeliveries.isEmpty })

        #expect(engine.thread(cto)?.turns.isEmpty == true)
        #expect(engine.thread(cto)?.queue.isEmpty == true)
        #expect(teammateSession.turns.count == 1)
    }

    @Test func aTeammateCreatedWhileASessionStartsIsReachableFromItsFirstTurn() async throws {
        let driver = ScriptedDriver()
        let gate = Gate()
        driver.sessionStartGate = { await gate.wait() }
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        let sending = Task { try await engine.send(threadID, text: "Plan", attachments: []) }
        #expect(await EngineHarness.eventually { driver.session?.configs.count == 1 })
        let caller = try #require(driver.session)
        #expect(caller.configs.first?.hostTools.isEmpty == true)

        _ = try teammate(engine, "CTO", handle: "cto")
        gate.open()
        try await sending.value

        #expect(caller.turns.count == 1)
        #expect((caller.toolSetsAtTurnStart.first ?? 0) >= 1)
        #expect(caller.hostToolSets.first?.map(\.name) == [TeamTools.message, TeamTools.list, TeamTools.activity])
    }

    @Test func teamActivityReportsWhatATeammateHandledToday() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let cto = try teammate(engine, "CTO", handle: "cto")
        try await engine.send(cto, text: "Summarize the open PRs", attachments: [])
        let teammateSession = try #require(session(of: cto, engine, driver))
        answer(teammateSession, "Three PRs are open; #81 needs a rebase.")
        #expect(await EngineHarness.eventually { engine.thread(cto)?.isRunning == false })

        try await engine.send(cto, text: "What did you do today?", attachments: [])
        teammateSession.emit(.hostToolCall(HostToolCall(id: "h1", toolCallID: nil, name: TeamTools.activity, arguments: [:])))

        #expect(await EngineHarness.eventually { teammateSession.hostToolResults.count == 1 })
        let report = try #require(teammateSession.hostToolResults.first?.result.text)
        #expect(report.contains("CTO (`cto`) handled 2 requests"))
        #expect(report.contains("from the user · done"))
        #expect(report.contains("Asked: Summarize the open PRs"))
        #expect(report.contains("Answered: Three PRs are open; #81 needs a rebase."))
    }

    @Test func aTeammateAddsATeammateItCanMessageAtOnce() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let project = engine.addProject(path: EngineHarness.temporaryDirectory().path)
        let cto = try teammate(engine, "CTO", handle: "cto")
        try await engine.send(cto, text: "We need a frontend engineer", attachments: [])
        let ctoSession = try #require(session(of: cto, engine, driver))
        #expect(ctoSession.configs.first?.hostTools.map(\.name) == [TeamTools.list, TeamTools.activity, TeamTools.create, TeamTools.update, TeamTools.delete])

        ctoSession.emit(.hostToolCall(HostToolCall(id: "h1", toolCallID: nil, name: TeamTools.create, arguments: [
            "name": .string("Frontend engineer"), "role": .string("Owns the theme"), "instructions": .string("Ship small PRs."),
            "home": .string(project.title.uppercased()),
        ])))

        #expect(await EngineHarness.eventually { ctoSession.hostToolResults.count == 1 })
        let result = try #require(ctoSession.hostToolResults.first?.result)
        #expect(result.isError == false)
        #expect(result.text.hasPrefix("Added Frontend engineer (`frontend-engineer`) to the team"))
        let added = try #require(engine.teammateThread(handle: "frontend-engineer"))
        #expect(added.projectID == project.id)
        #expect(added.teammate == Teammate(name: "Frontend engineer", handle: "frontend-engineer", role: "Owns the theme", instructions: "Ship small PRs."))
        #expect(await EngineHarness.eventually {
            ctoSession.hostToolSets.last?.first?.parameters["properties"]?["to"]?["enum"] == ["frontend-engineer"]
        })
    }

    @Test func teamCreateRefusesWhatTheDialogWouldAndNormalThreadsCannotCreate() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let cto = try teammate(engine, "CTO", handle: "cto")
        try await engine.send(cto, text: "Grow the team", attachments: [])
        let ctoSession = try #require(session(of: cto, engine, driver))

        ctoSession.emit(.hostToolCall(HostToolCall(id: "h1", toolCallID: nil, name: TeamTools.create, arguments: [
            "name": .string("CTO"), "role": .string("A second CTO"),
        ])))
        ctoSession.emit(.hostToolCall(HostToolCall(id: "h2", toolCallID: nil, name: TeamTools.create, arguments: [
            "name": .string("Designer"), "role": .string("Owns the UI"), "home": .string("~/no-such-project"),
        ])))

        #expect(await EngineHarness.eventually { ctoSession.hostToolResults.count == 2 })
        let results = Dictionary(uniqueKeysWithValues: ctoSession.hostToolResults.map { ($0.id, $0.result) })
        #expect(results["h1"] == HostToolResult(text: "Another teammate already uses “cto”.", isError: true))
        #expect(results["h2"]?.isError == true)
        #expect(results["h2"]?.text.hasPrefix("No single project matches “~/no-such-project”.") == true)

        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "Add a designer", attachments: [])
        let caller = try #require(session(of: threadID, engine, driver))
        #expect(caller.configs.first?.hostTools.map(\.name).contains(TeamTools.create) == false)
        caller.emit(.hostToolCall(HostToolCall(id: "h3", toolCallID: nil, name: TeamTools.create, arguments: [
            "name": .string("Designer"), "role": .string("Owns the UI"),
        ])))

        #expect(await EngineHarness.eventually { caller.hostToolResults.count == 1 })
        #expect(caller.hostToolResults.first?.result.isError == true)
        #expect(engine.team.compactMap(\.teammate?.handle) == ["cto"])
    }

    @Test func aTeammateUpdatesAnotherOnlyInTheFieldsItPassesAndDeletesOthersButNeverItself() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let project = engine.addProject(path: EngineHarness.temporaryDirectory().path)
        let cto = try teammate(engine, "CTO", handle: "cto")
        let theme = try engine.createTeammate(TeammateDraft(
            name: "Theme", handle: "theme", role: "Valkental themes", instructions: "Valkental only.", projectID: project.id, exportsToOmp: false
        )).threadID
        let qa = try teammate(engine, "QA", handle: "qa")
        try await engine.send(cto, text: "Fix the team", attachments: [])
        let ctoSession = try #require(session(of: cto, engine, driver))

        ctoSession.emit(.hostToolCall(HostToolCall(id: "h1", toolCallID: nil, name: TeamTools.update, arguments: [
            "teammate": .string("theme"), "handle": .string("frontend"), "role": .string("Themes for every account"), "home": .string("own"),
        ])))
        #expect(await EngineHarness.eventually { ctoSession.hostToolResults.count == 1 })
        #expect(ctoSession.hostToolResults[0].result.isError == false)
        let updated = try #require(engine.thread(theme))
        #expect(updated.teammate == Teammate(name: "Theme", handle: "frontend", role: "Themes for every account", instructions: "Valkental only.", exportsToOmp: false))
        #expect(updated.projectID == nil)
        #expect(await EngineHarness.eventually {
            ctoSession.hostToolSets.last?.first?.parameters["properties"]?["to"]?["enum"] == ["frontend", "qa"]
        })

        ctoSession.emit(.hostToolCall(HostToolCall(id: "h2", toolCallID: nil, name: TeamTools.delete, arguments: ["teammate": .string("cto")])))
        ctoSession.emit(.hostToolCall(HostToolCall(id: "h3", toolCallID: nil, name: TeamTools.delete, arguments: ["teammate": .string("qa")])))
        #expect(await EngineHarness.eventually { ctoSession.hostToolResults.count == 3 })
        let results = Dictionary(uniqueKeysWithValues: ctoSession.hostToolResults.map { ($0.id, $0.result) })
        #expect(results["h2"] == HostToolResult(text: "A teammate can't delete itself; ask the user.", isError: true))
        #expect(results["h3"]?.isError == false)
        #expect(engine.thread(qa) == nil)
        #expect(engine.team.compactMap(\.teammate?.handle) == ["cto", "frontend"])
    }

    @Test func aNormalThreadGetsTeamToolsOnlyOnceTheTeamHasMembers() async throws {
        let driver = ScriptedDriver()
        let engine = EngineHarness.engine(driver: driver)
        let threadID = EngineHarness.idleThread(in: engine)
        try await engine.send(threadID, text: "Hi", attachments: [])
        let caller = try #require(session(of: threadID, engine, driver))
        #expect(caller.configs.first?.hostTools.isEmpty == true)

        _ = try teammate(engine, "CTO", handle: "cto")

        #expect(await EngineHarness.eventually { caller.hostToolSets.count == 1 })
        #expect(caller.hostToolSets.first?.first?.parameters["properties"]?["to"]?["enum"] == ["cto"])
    }

    @Test func handlesMustBeValidAndUnique() throws {
        let engine = EngineHarness.engine()
        _ = try teammate(engine, "CTO", handle: "cto")

        #expect(throws: EngineError.message("Another teammate already uses “cto”.")) { try self.teammate(engine, "Other", handle: "cto") }
        #expect(throws: EngineError.self) { try self.teammate(engine, "Task", handle: "task") }
        #expect(throws: EngineError.self) { try self.teammate(engine, "Bad", handle: "Bad Handle") }
        #expect(Teammate.suggestedHandle(from: "Frontend Engineer") == "frontend-engineer")
        #expect(Teammate.suggestedHandle(from: "Ärztin #2") == "arztin-2")
    }

    @Test func teammatesStayOnOmp() throws {
        let engine = EngineHarness.engine()
        let cto = try teammate(engine, "CTO", handle: "cto")

        engine.setModelSelection(cto, .default(for: .opencode))

        #expect(engine.thread(cto)?.modelSelection.provider == .omp)
        #expect(InboxSection.of(try #require(engine.thread(cto))) == nil)
    }

    @Test func exportsFollowTheTeammateAndNeverTouchForeignFiles() async throws {
        let agents = EngineHarness.temporaryDirectory()
        let engine = EngineHarness.engine(ompAgentsDirectory: agents)
        try "---\nname: reviewer2\n---\nMine.\n".write(to: agents.appendingPathComponent("design.md"), atomically: true, encoding: .utf8)

        let cto = try teammate(engine, "CTO", handle: "cto", exports: true)
        let exported = try String(contentsOf: agents.appendingPathComponent("cto.md"), encoding: .utf8)
        #expect(exported.contains("name: cto"))
        #expect(exported.contains("Be brief."))

        let clash = try engine.createTeammate(TeammateDraft(name: "Design", handle: "design", role: "", instructions: "", projectID: nil))
        #expect(clash.warning?.contains("design.md already exists") == true)
        #expect(try String(contentsOf: agents.appendingPathComponent("design.md"), encoding: .utf8) == "---\nname: reviewer2\n---\nMine.\n")

        // A file that isn't UTF-8 can't prove it is ours either: it stays as it is.
        let utf16 = try #require("---\nname: qa\n---\nMine.\n".data(using: .utf16))
        try utf16.write(to: agents.appendingPathComponent("qa.md"))
        let unreadable = try engine.createTeammate(TeammateDraft(name: "QA", handle: "qa", role: "", instructions: "", projectID: nil))
        #expect(unreadable.warning?.contains("qa.md already exists") == true)
        #expect(try Data(contentsOf: agents.appendingPathComponent("qa.md")) == utf16)

        var draft = try #require(engine.teammateDraft(cto))
        draft.handle = "chief"
        _ = try engine.updateTeammate(cto, draft)
        #expect(!FileManager.default.fileExists(atPath: agents.appendingPathComponent("cto.md").path))
        #expect(FileManager.default.fileExists(atPath: agents.appendingPathComponent("chief.md").path))

        await engine.deleteThread(cto)
        #expect(!FileManager.default.fileExists(atPath: agents.appendingPathComponent("chief.md").path))
        #expect(engine.team.map(\.teammate?.handle) == ["design", "qa"])
    }
}
