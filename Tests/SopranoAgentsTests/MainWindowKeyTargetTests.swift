import AppKit
import SopranoAgentsCore
import Testing
@testable import SopranoAgents

@MainActor
struct MainWindowKeyTargetTests {
    private func controller() throws -> MainWindowController {
        _ = NSApplication.shared
        let built = try DemoFixtures.build("demo")
        let state = WorkspaceState()
        state.select(built.selection)
        let controller = MainWindowController(
            engine: built.engine,
            state: state,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistsFrame: false,
            frame: NSRect(x: -30000, y: -30000, width: 1200, height: 800)
        )
        controller.mainWindow?.allowsOffscreenFrame = true
        return controller
    }

    @Test func aNotificationOrDockClickGivesTheKeyboardToTheDialogOpenOverTheWindow() throws {
        let controller = try controller()
        let window = try #require(controller.window)
        controller.showWindow(nil)
        defer { window.close() }
        #expect(controller.keyTarget === window)

        let overlay = OverlayWindow()
        overlay.present(over: window)
        #expect(controller.keyTarget === overlay)
        overlay.dismiss()
        #expect(controller.keyTarget === window)
    }

    @Test func theCommitDialogKeepsTheKeyboardWhenTheWindowIsBroughtForward() throws {
        let controller = try controller()
        let window = try #require(controller.window)
        controller.showWindow(nil)
        defer { window.close() }
        CommitDialog.present(status: GitStatusSummary(isRepository: true, branch: "main"), in: window) { _ in }
        let panel = try #require(window.childWindows?.first { $0 is CommitDialogPanel })
        defer { panel.cancelOperation(nil) }

        #expect(controller.keyTarget === panel)
    }

    @Test func aDialogHiddenWithItsMinimizedWindowStillTakesTheKeyboardOnReopen() async throws {
        let controller = try controller()
        let window = try #require(controller.window)
        controller.showWindow(nil)
        defer { window.close() }
        let overlay = OverlayWindow()
        overlay.present(over: window)
        defer { overlay.dismiss() }
        // A minimized window's children go off screen with it; the dialog is still open.
        window.miniaturize(nil)
        _ = await EngineHarness.eventually(timeout: .seconds(3)) { window.isMiniaturized && !overlay.isVisible }
        try #require(window.isMiniaturized && !overlay.isVisible)

        #expect(controller.keyTarget === overlay)

        overlay.dismiss()
        #expect(controller.keyTarget === window)
    }
}
