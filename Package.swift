// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SopranoAgents",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Same pin as Soprano; the timeline's Markdown block model (MarkdownDocument) parses with it.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        // Terminal drawer: an AppKit terminal view over a local pseudo-terminal.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
    ],
    targets: [
        // Agent engine: provider sessions (Codex app-server, Claude Code), thread model,
        // persistence, git checkpoints and diffs. Foundation only, no AppKit.
        .target(
            name: "SopranoAgentsCore",
            path: "Sources/SopranoAgentsCore"
        ),
        .executableTarget(
            name: "SopranoAgents",
            dependencies: [
                "SopranoAgentsCore",
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/SopranoAgents",
            exclude: ["Vendored/SOPRANO_COMMIT"],
            resources: [
                .copy("Resources/AppIcon.icns"),
            ],
            linkerSettings: [
                .linkedFramework("CoreServices"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "SopranoAgentsTests",
            dependencies: ["SopranoAgents", "SopranoAgentsCore"],
            path: "Tests/SopranoAgentsTests",
            // Recorded provider traces, read through #filePath.
            exclude: ["Fixtures"],
            swiftSettings: [
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
                .linkedFramework("Testing"),
            ]
        ),
    ]
)
