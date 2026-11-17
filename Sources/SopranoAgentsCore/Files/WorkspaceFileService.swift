import Foundation

/// What reading one workspace file produced, decided by extension and content.
public enum WorkspaceFileContent: Sendable, Equatable {
    case text(String)
    /// png, jpg, jpeg, gif, webp, heic, bmp, tif, tiff, ico — up to `WorkspaceFileLimits.maximumImageBytes`.
    case image(Data)
    /// A NUL byte in the first 8 KiB, or not valid UTF-8.
    case binary(byteCount: Int)
    /// Text over `WorkspaceFileLimits.maximumTextBytes`, or an image over `maximumImageBytes`.
    case tooLarge(byteCount: Int)
}

/// Lists and reads the files of a working directory for the right panel's file explorer and
/// viewer. Paths are workspace-relative and "/"-separated.
public protocol WorkspaceFileService: Sendable {
    /// Workspace-relative "/"-separated file paths, sorted. In a git repo: tracked +
    /// untracked-not-ignored files that exist on disk
    /// (`git ls-files -z --cached --others --exclude-standard`). Elsewhere: every regular file
    /// under root, skipping `.git`, `node_modules`, `.build`, `DerivedData`, capped at
    /// `WorkspaceFileLimits.maximumWalkedFiles`.
    func listFiles(root: String) async throws -> [String]
    /// What git ignores under `root`, for the explorer to show dimmed: ignored files, and
    /// ignored folders as one entry ending in "/" (`git ls-files -z --others --ignored
    /// --exclude-standard --directory`), sorted. Empty outside git.
    func listIgnored(root: String) async throws -> [String]
    /// One folder's entries (files and folders, sorted), for expanding an ignored folder;
    /// `relativePath` "" is the root. Paths escaping `root` throw `EngineError.message`.
    func listDirectory(root: String, relativePath: String) async throws -> [WorkspaceDirectoryEntry]
    /// Reads one file under `root`; paths escaping it (`..`, absolute, a symlink out of root)
    /// throw `EngineError.message`.
    func readFile(root: String, relativePath: String) async throws -> WorkspaceFileContent
}

extension WorkspaceFileService {
    /// Services without git (fixtures, tests) ignore nothing.
    public func listIgnored(root: String) async throws -> [String] { [] }
    public func listDirectory(root: String, relativePath: String) async throws -> [WorkspaceDirectoryEntry] { [] }
}

/// One entry of a folder listing.
public struct WorkspaceDirectoryEntry: Sendable, Hashable {
    public var name: String
    /// A real folder (a symlink to one counts as a file and is never entered).
    public var isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

public enum WorkspaceFileLimits {
    public static let maximumTextBytes = 2 * 1024 * 1024
    public static let maximumImageBytes = 20 * 1024 * 1024
    /// Bytes inspected for a NUL to call a file binary.
    public static let binaryProbeBytes = 8 * 1024
    /// Cap of the non-git directory walk.
    public static let maximumWalkedFiles = 20_000
    /// Most entries one folder listing returns.
    public static let maximumDirectoryEntries = 5_000
    /// Directories the non-git walk never enters.
    public static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData"]
    /// Lowercased extensions read as `.image`.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tif", "tiff", "ico"]
}

/// Workspace path containment shared by the engine and the live service.
public enum WorkspaceFilePath {
    /// Absolute URL of `relativePath` under `root` with symlinks resolved, or nil when it is
    /// empty, absolute, climbs above root with `..`, or resolves (through a symlink) outside the
    /// resolved root. Missing trailing components are appended as written, so paths that do not
    /// exist yet (the snapshot fixture) still resolve.
    public static func resolve(root: String, relativePath: String) -> URL? {
        guard !relativePath.hasPrefix("/") else { return nil }
        var components: [Substring] = []
        for component in relativePath.split(separator: "/") where component != "." {
            if component == ".." {
                guard components.popLast() != nil else { return nil }
            } else {
                components.append(component)
            }
        }
        guard !components.isEmpty else { return nil }
        let resolvedRoot = canonical(root)
        let candidate = canonical(resolvedRoot + "/" + components.joined(separator: "/"))
        let prefix = resolvedRoot == "/" ? "/" : resolvedRoot + "/"
        guard candidate.hasPrefix(prefix) else { return nil }
        return URL(fileURLWithPath: candidate)
    }

    /// `realpath` of the deepest existing ancestor of an absolute, `..`-free path, followed by
    /// the components that do not exist.
    static func canonical(_ path: String) -> String {
        var existing = (path as NSString).standardizingPath
        var missing: [String] = []
        while true {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                guard !missing.isEmpty else { return base }
                return (base == "/" ? "" : base) + "/" + missing.reversed().joined(separator: "/")
            }
            let parent = (existing as NSString).deletingLastPathComponent
            guard parent != existing, !parent.isEmpty else { return path }
            missing.append((existing as NSString).lastPathComponent)
            existing = parent
        }
    }
}
