import Foundation

/// A long-lived team agent ("CTO", "Frontend engineer"). The thread it lives in carries it
/// (`AgentThread.teammate`): its conversation is that thread's, its home folder the thread's
/// working directory (the project root, or its own scratch folder), its model and runtime mode
/// the thread's. Other threads and teammates reach it by `handle` through the team tools.
public struct Teammate: Codable, Sendable, Hashable {
    /// Display name ("CTO", "Ada").
    public var name: String
    /// Unique lowercase address ("cto", "frontend"): `team_message {to}` and, when exported,
    /// its omp agent name.
    public var handle: String
    /// One line: what it is responsible for.
    public var role: String
    /// Standing instructions, appended to omp's system prompt with the team rules.
    public var instructions: String
    /// Also written to omp's user agents folder (`<handle>.md`), so terminal omp can start a
    /// fresh copy of the persona (without this teammate's memory).
    public var exportsToOmp: Bool

    public init(name: String, handle: String, role: String, instructions: String, exportsToOmp: Bool = true) {
        self.name = name
        self.handle = handle
        self.role = role
        self.instructions = instructions
        self.exportsToOmp = exportsToOmp
    }

    /// Handles omp reserves or ships agents under; a teammate never takes them.
    public static let reservedHandles: Set<String> = [
        "main", "sub", "task", "sonic", "scout", "reviewer", "security-reviewer", "seance", "all", "user", "you",
    ]

    /// Longest handle accepted.
    public static let maximumHandleLength = 32

    /// A handle derived from `name`: lowercase ASCII letters, digits and single dashes
    /// ("Frontend Engineer" → "frontend-engineer"); "" when nothing usable remains.
    public static func suggestedHandle(from name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var handle = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                handle.unicodeScalars.append(scalar)
            } else if !handle.isEmpty, !handle.hasSuffix("-") {
                handle.append("-")
            }
        }
        while handle.hasSuffix("-") { handle.removeLast() }
        while let first = handle.first, first.isNumber { handle.removeFirst() }
        if handle.hasPrefix("-") { handle.removeFirst() }
        return String(handle.prefix(maximumHandleLength))
    }

    /// Why `handle` can't be used, nil when it can: it must start with a letter, hold only
    /// lowercase letters, digits and dashes, fit `maximumHandleLength`, not be reserved, and not
    /// be in `taken` (other teammates' handles).
    public static func handleProblem(_ handle: String, taken: Set<String>) -> String? {
        if handle.isEmpty { return "Give the teammate a handle." }
        if handle.count > maximumHandleLength { return "The handle is longer than \(maximumHandleLength) characters." }
        guard let first = handle.unicodeScalars.first, ("a"..."z").contains(first) else {
            return "The handle must start with a lowercase letter."
        }
        let allowed = handle.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        if !allowed { return "The handle may only contain lowercase letters, digits and dashes." }
        if reservedHandles.contains(handle) { return "“\(handle)” is reserved by omp; pick another handle." }
        if taken.contains(handle) { return "Another teammate already uses “\(handle)”." }
        return nil
    }
}

/// Who sent a message that did not come from the user: another teammate or one of the user's
/// threads, through `team_message`.
public struct MessageSender: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// A teammate (its thread carries `teammate`).
        case teammate
        /// One of the user's threads.
        case thread
    }

    public var kind: Kind
    /// The sending thread (a teammate's own thread for `.teammate`).
    public var threadID: String
    /// Teammate name or thread title when the message was sent.
    public var name: String

    public init(kind: Kind, threadID: String, name: String) {
        self.kind = kind
        self.threadID = threadID
        self.name = name
    }
}

/// What the New/Edit Teammate dialog submits.
public struct TeammateDraft: Sendable, Hashable {
    public var name: String
    public var handle: String
    public var role: String
    public var instructions: String
    /// Home folder: a project's root; nil = the teammate's own folder in app data.
    public var projectID: String?
    public var exportsToOmp: Bool

    public init(name: String, handle: String, role: String, instructions: String, projectID: String?, exportsToOmp: Bool = true) {
        self.name = name
        self.handle = handle
        self.role = role
        self.instructions = instructions
        self.projectID = projectID
        self.exportsToOmp = exportsToOmp
    }
}

/// Result of saving a teammate: its thread, and a problem worth showing that did not stop the
/// save (the omp export could not be written).
public struct TeammateSaveResult: Sendable, Hashable {
    public var threadID: String
    public var warning: String?

    public init(threadID: String, warning: String? = nil) {
        self.threadID = threadID
        self.warning = warning
    }
}
