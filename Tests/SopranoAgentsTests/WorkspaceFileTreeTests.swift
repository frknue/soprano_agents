import AppKit
import Testing
@testable import SopranoAgents
@testable import SopranoAgentsCore

struct WorkspaceFileTreeTests {
    private let paths = [
        "Package.swift",
        "README.md",
        "Sources/Auth/LoginController.swift",
        "Sources/Auth/SessionStore.swift",
        "Sources/app.swift",
        "Tests/AuthTests/LoginRedirectTests.swift",
        "docs/guide/setup.md",
        "docs/Login.md",
        "assets/logo.png",
    ]

    @Test func foldersComeBeforeFilesAndEachSortsAlphabeticallyIgnoringCase() {
        let tree = WorkspaceFileTree(paths: paths)
        #expect(tree.roots.map(\.name) == ["assets", "docs", "Sources", "Tests", "Package.swift", "README.md"])
        let sources = tree.roots[2]
        #expect(sources.isDirectory)
        #expect(sources.children.map(\.name) == ["Auth", "app.swift"])
        #expect(sources.children[0].children.map(\.path) == ["Sources/Auth/LoginController.swift", "Sources/Auth/SessionStore.swift"])
        #expect(tree.roots[1].children.map(\.name) == ["guide", "Login.md"])
    }

    @Test func nodesCarryTheirWorkspaceRelativePathAndFolder() {
        let tree = WorkspaceFileTree(paths: paths)
        let setup = tree.roots[1].children[0].children[0]
        #expect(setup.path == "docs/guide/setup.md")
        #expect(setup.directory == "docs/guide")
        #expect(!setup.isDirectory)
        #expect(tree.roots[4].directory == "")
        #expect(tree.directoryPaths == ["assets", "docs", "docs/guide", "Sources", "Sources/Auth", "Tests", "Tests/AuthTests"])
    }

    @Test func searchRanksFileNameMatchesBeforePathAndSubsequenceMatches() {
        let tree = WorkspaceFileTree(paths: paths)
        #expect(tree.search("login") == [
            "Sources/Auth/LoginController.swift",
            "Tests/AuthTests/LoginRedirectTests.swift",
            "docs/Login.md",
        ])
        let ranked = WorkspaceFileTree(paths: ["a/u/t/h.txt", "auth/notes.txt", "lib/oauth.swift", "lib/AUTH.swift"])
        #expect(ranked.search(" Auth ") == ["lib/AUTH.swift", "lib/oauth.swift", "auth/notes.txt", "a/u/t/h.txt"])
        #expect(ranked.search("zz").isEmpty)
    }

    @Test func emptyQueriesMatchNothingAndResultsStopAtTheLimit() {
        let many = WorkspaceFileTree(paths: (0..<800).map { "lib/file\($0).txt" })
        #expect(many.search("   ").isEmpty)
        #expect(many.search("file").count == WorkspaceFileTree.searchLimit)
        #expect(many.search("file", limit: 3) == ["lib/file0.txt", "lib/file1.txt", "lib/file2.txt"])
    }

    @Test func anEmptyListingHasNoRows() {
        let tree = WorkspaceFileTree(paths: [])
        #expect(tree.isEmpty)
        #expect(tree.roots.isEmpty)
    }

    @Test func ignoredEntriesJoinTheTreeDimmedButStayOutOfSearch() {
        let tree = WorkspaceFileTree(paths: ["Sources/App.swift", "README.md"], ignored: [".build/", ".env", "Sources/trace.log"])

        #expect(tree.roots.map(\.name) == [".build", "Sources", ".env", "README.md"])
        let build = tree.roots[0]
        #expect(build.isDirectory && build.isIgnored && build.isLazy && build.children.isEmpty)
        #expect(!tree.roots[1].isIgnored)
        #expect(tree.roots[1].children.map { "\($0.name):\($0.isIgnored)" } == ["App.swift:false", "trace.log:true"])
        #expect(tree.roots[2].isIgnored && !tree.roots[2].isDirectory)
        #expect(tree.lazyDirectoryPaths == [".build"])
        #expect(tree.search("trace").isEmpty)
        #expect(tree.search("app") == ["Sources/App.swift"])
    }

    @Test func anIgnoredFoldersEntriesAreIgnoredAndItsFoldersOpenLazily() {
        let children = WorkspaceFileNode.ignoredChildren(of: ".build", entries: [
            WorkspaceDirectoryEntry(name: "release.yaml", isDirectory: false),
            WorkspaceDirectoryEntry(name: "debug", isDirectory: true),
        ])

        #expect(children.map(\.path) == [".build/debug", ".build/release.yaml"])
        let allIgnored = children.allSatisfy { $0.isIgnored }
        #expect(allIgnored)
        #expect(children[0].isLazy && !children[1].isLazy)
    }
}
