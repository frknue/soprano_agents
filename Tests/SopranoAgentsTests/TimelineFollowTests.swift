import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

/// When the timeline follows its end: a user scroll, however small, stops it; opening a row
/// keeps that row in view; Collapse all closes everything, also inside closed groups.
@MainActor
struct TimelineFollowTests {
    private let turnID = "turn-rechecked-1"

    /// The "rechecked" thread with a recap long enough to scroll, in a short offscreen window.
    private func timeline() throws -> (controller: TimelineViewController, window: NSWindow, clip: NSClipView) {
        let built = try DemoFixtures.build("rechecked")
        let recap = (1...40).map { "Line \($0) of the recap." }.joined(separator: "\n\n")
        built.engine.updateThread(DemoFixtures.ID.rechecked) { thread in
            guard let index = thread.turns[0].items.firstIndex(where: { $0.id == "rc11" }) else { return }
            thread.turns[0].items[index].kind = .assistantMessage(text: recap, isFinal: true)
        }
        let state = WorkspaceState()
        state.select(built.selection)
        let controller = TimelineViewController(engine: built.engine, state: state)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderFrontRegardless()
        render(window)
        controller.reload(scrollToEnd: true)
        render(window)
        let scrollView = try #require(controller.view.subviews.first { $0 is NSScrollView } as? NSScrollView)
        return (controller, window, scrollView.contentView)
    }

    private func render(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func endY(_ clip: NSClipView) -> CGFloat {
        (clip.documentView?.frame.height ?? 0) - clip.bounds.height
    }

    @Test func aSmallUserScrollUpStopsFollowingTheEndSoTheNextUpdateLeavesItWhereItIs() throws {
        let (controller, window, clip) = try timeline()
        defer { window.orderOut(nil) }
        let end = endY(clip)
        #expect(end > 100)
        #expect(abs(clip.bounds.minY - end) < 1)

        // A slow trackpad scroll moves only a few points per event.
        clip.scroll(to: NSPoint(x: 0, y: end - 3))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        controller.reload()
        render(window)

        #expect(abs(clip.bounds.minY - (end - 3)) < 1)

        // Back at the end, it follows again.
        clip.scroll(to: NSPoint(x: 0, y: endY(clip)))
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
        controller.reload()
        #expect(abs(clip.bounds.minY - endY(clip)) < 1)
    }

    @Test func openingTheFoldWhileFollowingTheEndKeepsTheFoldInView() throws {
        let (controller, window, clip) = try timeline()
        // The detailed work log (`chat.workLog`) opens folds by default.
        if controller.expansion.isTurnOpen(turnID) { controller.timelineToggleFold(turnID: turnID) }
        defer { window.orderOut(nil) }
        // A window just tall enough to show the closed fold at its top, following the end.
        let list = try #require(clip.documentView as? TimelineListView)
        window.setContentSize(NSSize(width: 900, height: 3000))
        render(window)
        let closed = try #require(list.view(forRow: "fold:\(turnID)"))
        let contentHeight = list.subviews.map(\.frame.maxY).max() ?? 0
        window.setContentSize(NSSize(width: 900, height: contentHeight - closed.frame.minY + 30))
        render(window)
        #expect(abs(clip.bounds.minY - endY(clip)) < 1)
        #expect(clip.bounds.contains(closed.convert(closed.bounds, to: clip)))

        controller.timelineToggleFold(turnID: turnID)
        render(window)
        #expect(controller.expansion.isTurnOpen(turnID))
        let fold = try #require(list.view(forRow: "fold:\(turnID)"))
        let header = fold.convert(NSRect(x: 0, y: 0, width: fold.bounds.width, height: 24), to: clip)
        #expect(clip.bounds.contains(header))
    }

    @Test func collapseAllClosesEntriesAndDiffsInsideGroupsThatAreAlreadyClosed() throws {
        let (controller, window, _) = try timeline()
        defer { window.orderOut(nil) }
        controller.expandAll()
        let rows = controller.currentRows
        let entries = rows.compactMap { row -> String? in
            if case let .workEntry(model) = row.content, model.grouped { return model.id } else { return nil }
        }
        let group = try #require(rows.compactMap { row -> String? in
            if case let .workGroup(model) = row.content { return model.groupID } else { return nil }
        }.first)
        let entry = try #require(entries.first)
        controller.timelineToggleEntry(entry)
        #expect(controller.expansion.entries.contains(entry))
        controller.timelineToggleGroup(group)
        #expect(!controller.expansion.isGroupOpen(group))

        controller.collapseAll()

        #expect(!controller.expansion.entries.contains(entry))
        #expect(!controller.expansion.isTurnOpen(turnID))
    }

    @Test func openingAThoughtWithRepeatedProviderItemIDKeepsItsHeaderInPlaceWithoutJumpingToAnEarlierTurn() throws {
        let selection = ModelSelection(provider: .antigravity, model: "default")
        let start = Date(timeIntervalSince1970: 1_000_000)
        let longBody = (1...24).map { "Thought line \($0) with enough detail to expand the row vertically." }.joined(separator: "\n\n")
        let filler = (1...30).map { "Filler paragraph \($0) to separate the two turns well beyond one viewport." }.joined(separator: "\n\n")

        // Two turns whose provider item IDs repeat (`t1/thought-1`, `t1/cmd-1`, `t1/message-2`),
        // as happens when a provider session restarts between turns in the same thread.
        func makeTurn(_ id: String, ordinal: Int, prompt: String, offset: TimeInterval) -> Turn {
            Turn(
                id: id,
                ordinal: ordinal,
                userMessage: UserMessage(id: "u-\(id)", text: prompt, createdAt: start.addingTimeInterval(offset)),
                modelSelection: selection,
                status: .completed,
                startedAt: start.addingTimeInterval(offset),
                completedAt: start.addingTimeInterval(offset + 10),
                items: [
                    TurnItem(id: "t1/thought-1", kind: .reasoning(text: "**Turn \(ordinal) thought**\n\n\(longBody)"), status: .completed, startedAt: start.addingTimeInterval(offset + 1), completedAt: start.addingTimeInterval(offset + 2)),
                    TurnItem(id: "t1/cmd-1", kind: .command(CommandExecution(command: "echo \(ordinal)")), status: .completed, startedAt: start.addingTimeInterval(offset + 3), completedAt: start.addingTimeInterval(offset + 4)),
                    TurnItem(id: "t1/message-2", kind: .assistantMessage(text: "Answer \(ordinal).\n\n\(filler)", isFinal: true), status: .completed, startedAt: start.addingTimeInterval(offset + 5), completedAt: start.addingTimeInterval(offset + 6)),
                ]
            )
        }

        let built = try DemoFixtures.build("rechecked")
        built.engine.updateThread(DemoFixtures.ID.rechecked) { thread in
            thread.turns = [
                makeTurn("turn-1", ordinal: 1, prompt: "First", offset: 0),
                makeTurn("turn-2", ordinal: 2, prompt: "Second", offset: 100),
            ]
        }
        let state = WorkspaceState()
        state.select(built.selection)
        let controller = TimelineViewController(engine: built.engine, state: state)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        render(window)

        // Open both folds and groups so both turns' thoughts are visible in the timeline.
        controller.expandAll()
        render(window)
        let scrollView = try #require(controller.view.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let clip = scrollView.contentView
        let list = try #require(clip.documentView as? TimelineListView)

        let firstRowID = "entry:turn-1:t1/thought-1"
        let secondRowID = "entry:turn-2:t1/thought-1"
        let secondEntryKey = "turn-2:t1/thought-1"
        let firstEntryKey = "turn-1:t1/thought-1"

        // Scroll so Turn 2's thought sits near the top of the viewport (well below Turn 1).
        list.reveal(rowID: secondRowID, rect: NSRect(x: 0, y: 0, width: 1, height: 24))
        render(window)
        let secondBefore = try #require(list.view(forRow: secondRowID))
        let visualYBefore: CGFloat = secondBefore.frame.minY - clip.bounds.minY
        #expect(clip.bounds.minY > 500)
        #expect(visualYBefore >= 0 && visualYBefore < clip.bounds.height)

        // Click Turn 2's thought to open it: Turn 1's thought must stay closed and Turn 2's header
        // must stay at its pre-click visual position instead of jumping up to Turn 1.
        controller.timelineToggleEntry(secondEntryKey)
        render(window)

        #expect(controller.expansion.entries.contains(secondEntryKey))
        #expect(!controller.expansion.entries.contains(firstEntryKey))
        let secondAfter = try #require(list.view(forRow: secondRowID))
        let visualYAfter: CGFloat = secondAfter.frame.minY - clip.bounds.minY
        #expect(abs(visualYAfter - visualYBefore) < 1)
        #expect(list.view(forRow: firstRowID) == nil)
    }

    @Test func openingAThoughtWhileFollowingTheEndAnchorsItsHeaderAtTheClickPosition() throws {
        let selection = ModelSelection(provider: .antigravity, model: "default")
        let start = Date(timeIntervalSince1970: 1_000_000)
        let longBody = (1...24).map { "Reasoning step \($0) explaining the fix in detail." }.joined(separator: "\n\n")
        let built = try DemoFixtures.build("rechecked")
        built.engine.updateThread(DemoFixtures.ID.rechecked) { thread in
            thread.turns = [
                Turn(
                    id: "turn-pinned",
                    ordinal: 1,
                    userMessage: UserMessage(id: "u-pinned", text: "Fix it", createdAt: start),
                    modelSelection: selection,
                    status: .completed,
                    startedAt: start,
                    completedAt: start.addingTimeInterval(10),
                    items: [
                        TurnItem(id: "t1/thought-1", kind: .reasoning(text: "**Inspecting timeline**\n\n\(longBody)"), status: .completed, startedAt: start.addingTimeInterval(1), completedAt: start.addingTimeInterval(2)),
                        TurnItem(id: "t1/cmd-1", kind: .command(CommandExecution(command: "swift test")), status: .completed, startedAt: start.addingTimeInterval(3), completedAt: start.addingTimeInterval(4)),
                        TurnItem(id: "t1/msg-1", kind: .assistantMessage(text: "Done.", isFinal: true), status: .completed, startedAt: start.addingTimeInterval(5), completedAt: start.addingTimeInterval(6)),
                    ]
                ),
            ]
        }
        let state = WorkspaceState()
        state.select(built.selection)
        let controller = TimelineViewController(engine: built.engine, state: state)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        render(window)

        controller.expandAll()
        controller.jumpToLatest()
        render(window)
        let scrollView = try #require(controller.view.subviews.first { $0 is NSScrollView } as? NSScrollView)
        let clip = scrollView.contentView
        let list = try #require(clip.documentView as? TimelineListView)
        #expect(list.isPinnedToBottom)

        let thoughtRowID = "entry:turn-pinned:t1/thought-1"
        let before = try #require(list.view(forRow: thoughtRowID))
        let visualYBefore: CGFloat = before.frame.minY - clip.bounds.minY

        controller.timelineToggleEntry("turn-pinned:t1/thought-1")
        render(window)

        let after = try #require(list.view(forRow: thoughtRowID))
        let visualYAfter: CGFloat = after.frame.minY - clip.bounds.minY
        #expect(abs(visualYAfter - visualYBefore) < 1)
    }
}
