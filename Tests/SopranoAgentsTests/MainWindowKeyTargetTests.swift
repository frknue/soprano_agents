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
}
