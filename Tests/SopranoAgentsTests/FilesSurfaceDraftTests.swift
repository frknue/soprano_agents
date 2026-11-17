import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

@MainActor
struct FilesSurfaceDraftTests {
    /// Lists one more file on every call, so a reload is visible as a new listing.
    private final class GrowingFiles: WorkspaceFileService, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var calls: Int { lock.withLock { count } }

        func listFiles(root: String) async throws -> [String] {
            let n = lock.withLock { count += 1; return count }
            return (1...n).map { "file\($0).txt" }
        }

        func readFile(root: String, relativePath: String) async throws -> WorkspaceFileContent { .text("") }
    }

    @Test func returningToAProjectDraftRelistsItsFolderInsteadOfShowingTheOldTree() async throws {
        let files = GrowingFiles()
        let engine = AgentEngine(environment: EngineEnvironment(
            drivers: [:],
            git: RecordingGit(),
            store: InMemoryThreadStore(),
            dataDirectory: EngineHarness.temporaryDirectory(),
            files: files
        ))
        let project = engine.addProject(path: EngineHarness.temporaryDirectory().path)
        let state = WorkspaceState()
        let surface = FilesSurfaceViewController(engine: engine, state: state)
        _ = surface.view
        state.select(.draft(projectID: project.id))
        state.showRightPanel(.files)
        #expect(await EngineHarness.eventually { files.calls == 1 })

        // Meanwhile a "Current checkout" thread changes the folder.
        let threadID = EngineHarness.idleThread(in: engine)
        state.select(.thread(threadID))
        state.select(.draft(projectID: project.id))

        #expect(await EngineHarness.eventually { files.calls >= 2 })
    }

    /// One tracked file and an ignored `build/` folder whose first read waits until released.
    private final class SlowIgnoredFolder: WorkspaceFileService, @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var released = false

        var directoryReads: Int { lock.withLock { reads } }
        func release() { lock.withLock { released = true } }

        func listFiles(root: String) async throws -> [String] { ["main.swift"] }
        func listIgnored(root: String) async throws -> [String] { ["build/"] }

        func listDirectory(root: String, relativePath: String) async throws -> [WorkspaceDirectoryEntry] {
            let first = lock.withLock { reads += 1; return reads == 1 }
            while first, !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(5)) }
            return [WorkspaceDirectoryEntry(name: "app.o", isDirectory: false)]
        }

        func readFile(root: String, relativePath: String) async throws -> WorkspaceFileContent { .text("") }
    }

    @Test func anIgnoredFolderOpenDuringARefreshShowsItsEntriesFromTheNewListing() async throws {
        let files = SlowIgnoredFolder()
        let engine = AgentEngine(environment: EngineEnvironment(
            drivers: [:], git: RecordingGit(), store: InMemoryThreadStore(),
            dataDirectory: EngineHarness.temporaryDirectory(), files: files
        ))
        let project = engine.addProject(path: EngineHarness.temporaryDirectory().path)
        let state = WorkspaceState()
        let surface = FilesSurfaceViewController(engine: engine, state: state)
        _ = surface.view
        state.select(.draft(projectID: project.id))
        state.showRightPanel(.files)
        let outline = surface.outlineView
        func paths() -> [String] {
            (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? WorkspaceFileNode)?.path }
        }
        #expect(await EngineHarness.eventually { paths().contains("build") })

        // Open build/ (its read hangs), refresh, then let the old read finish.
        outline.expandItem(outline.item(atRow: paths().firstIndex(of: "build")!))
        #expect(await EngineHarness.eventually { files.directoryReads == 1 })
        surface.refresh()
        #expect(await EngineHarness.eventually { files.directoryReads == 2 })
        files.release()

        #expect(await EngineHarness.eventually { paths().contains("build/app.o") })
    }
}
