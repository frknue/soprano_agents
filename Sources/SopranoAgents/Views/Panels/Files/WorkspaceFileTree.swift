import AppKit
import SopranoAgentsCore

/// One row of the Files explorer: a folder or a file of a thread's working directory. A class so
/// `NSOutlineView` keeps rows (and their expansion) by identity; immutable once built.
final class WorkspaceFileNode: NSObject, Sendable {
    let name: String
    /// Workspace-relative "/"-separated path.
    let path: String
    let isDirectory: Bool
    /// Git ignores it (shown dimmed).
    let isIgnored: Bool
    /// An ignored folder whose entries are read when it opens (`children` stays empty).
    let isLazy: Bool
    /// Folders first, then files, each alphabetical (case-insensitive). Empty for files.
    let children: [WorkspaceFileNode]

    init(name: String, path: String, isDirectory: Bool, isIgnored: Bool = false, isLazy: Bool = false, children: [WorkspaceFileNode] = []) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isIgnored = isIgnored
        self.isLazy = isLazy
        self.children = children
    }

    /// The folder part of `path` ("" at the root).
    var directory: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// The rows of an ignored folder's listing: all ignored; folders open lazily in turn.
    static func ignoredChildren(of folder: String, entries: [WorkspaceDirectoryEntry]) -> [WorkspaceFileNode] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        let folders = entries.filter(\.isDirectory).sorted { WorkspaceFileTree.ordered($0.name, $1.name) }
        let files = entries.filter { !$0.isDirectory }.sorted { WorkspaceFileTree.ordered($0.name, $1.name) }
        return folders.map { WorkspaceFileNode(name: $0.name, path: prefix + $0.name, isDirectory: true, isIgnored: true, isLazy: true) }
            + files.map { WorkspaceFileNode(name: $0.name, path: prefix + $0.name, isDirectory: false, isIgnored: true) }
    }
}

/// The file listing of one working directory: the folder tree the explorer shows (git-ignored
/// files and folders included, dimmed) and the flat search over the files git does not ignore.
struct WorkspaceFileTree: Sendable {
    /// Most matches a search returns.
    static let searchLimit = 500

    /// Every searchable file path (not ignored), in listing order.
    let paths: [String]
    /// Top-level folders and files.
    let roots: [WorkspaceFileNode]
    private let lowercasedPaths: [String]

    /// `ignored`: ignored files, and ignored folders as "path/" (listed lazily when opened).
    init(paths: [String], ignored: [String] = []) {
        self.paths = paths
        lowercasedPaths = paths.map { $0.lowercased() }
        let root = FolderBuilder()
        func folder(for parts: ArraySlice<Substring>) -> FolderBuilder {
            var folder = root
            for part in parts {
                let name = String(part)
                if let next = folder.folders[name] {
                    folder = next
                } else {
                    let next = FolderBuilder()
                    folder.folders[name] = next
                    folder = next
                }
            }
            return folder
        }
        for path in paths {
            let parts = path.split(separator: "/")
            guard let fileName = parts.last else { continue }
            folder(for: parts.dropLast()).files.append(String(fileName))
        }
        for entry in ignored {
            let isFolder = entry.hasSuffix("/")
            let parts = entry.split(separator: "/")
            guard let name = parts.last else { continue }
            let parent = folder(for: parts.dropLast())
            if isFolder {
                if parent.folders[String(name)] == nil { parent.ignoredFolders.insert(String(name)) }
            } else {
                parent.ignoredFiles.append(String(name))
            }
        }
        roots = Self.nodes(of: root, prefix: "")
    }

    var isEmpty: Bool { roots.isEmpty }

    /// Files whose path matches `query` (case-insensitive; surrounding spaces ignored): file
    /// names starting with it, then names containing it, then paths containing it, then paths
    /// containing its characters in order. Listing order within each group; at most `limit`.
    func search(_ query: String, limit: Int = WorkspaceFileTree.searchLimit) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty, limit > 0 else { return [] }
        var groups: [[String]] = [[], [], [], []]
        for (index, path) in lowercasedPaths.enumerated() {
            let name = path.lastIndex(of: "/").map { path[path.index(after: $0)...] } ?? path[...]
            let group: Int
            if name.hasPrefix(needle) {
                group = 0
            } else if name.contains(needle) {
                group = 1
            } else if path.contains(needle) {
                group = 2
            } else if Self.isSubsequence(needle, of: path) {
                group = 3
            } else {
                continue
            }
            groups[group].append(paths[index])
            if group == 0, groups[0].count >= limit { break }
        }
        return Array(groups.joined().prefix(limit))
    }

    /// Paths of every folder in the tree (for expansion bookkeeping).
    var directoryPaths: Set<String> {
        var result: Set<String> = []
        func walk(_ nodes: [WorkspaceFileNode]) {
            for node in nodes where node.isDirectory {
                result.insert(node.path)
                walk(node.children)
            }
        }
        walk(roots)
        return result
    }

    /// Paths of the ignored folders that open lazily (top of each ignored subtree).
    var lazyDirectoryPaths: [String] {
        var result: [String] = []
        func walk(_ nodes: [WorkspaceFileNode]) {
            for node in nodes where node.isDirectory {
                if node.isLazy { result.append(node.path) } else { walk(node.children) }
            }
        }
        walk(roots)
        return result
    }

    // MARK: - Building

    private final class FolderBuilder {
        var folders: [String: FolderBuilder] = [:]
        var files: [String] = []
        var ignoredFolders: Set<String> = []
        var ignoredFiles: [String] = []
    }

    private static func nodes(of folder: FolderBuilder, prefix: String) -> [WorkspaceFileNode] {
        var folderNodes = folder.folders.keys.map { name in
            let path = prefix + name
            return WorkspaceFileNode(name: name, path: path, isDirectory: true,
                                     children: nodes(of: folder.folders[name] ?? FolderBuilder(), prefix: path + "/"))
        }
        folderNodes += folder.ignoredFolders.map { name in
            WorkspaceFileNode(name: name, path: prefix + name, isDirectory: true, isIgnored: true, isLazy: true)
        }
        var fileNodes = folder.files.map { WorkspaceFileNode(name: $0, path: prefix + $0, isDirectory: false) }
        fileNodes += folder.ignoredFiles.map { WorkspaceFileNode(name: $0, path: prefix + $0, isDirectory: false, isIgnored: true) }
        return folderNodes.sorted { ordered($0.name, $1.name) } + fileNodes.sorted { ordered($0.name, $1.name) }
    }

    /// Case-insensitive alphabetical order; exact case breaks ties so the order is total.
    static func ordered(_ lhs: String, _ rhs: String) -> Bool {
        switch lhs.caseInsensitiveCompare(rhs) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs < rhs
        }
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = needle.unicodeScalars.makeIterator()
        guard var wanted = remaining.next() else { return true }
        for scalar in haystack.unicodeScalars where scalar == wanted {
            guard let next = remaining.next() else { return true }
            wanted = next
        }
        return false
    }
}
