import Foundation
import SQLite3

/// Portable per-teammate long-term memory stored in SQLite (`<data>/team/<threadID>/memory/soprano-memory.db`).
/// Used for non-omp teammates via `memory_retain` and `memory_recall` MCP tools so teammates on
/// Codex, Claude Code, Antigravity and OpenCode keep durable memory alongside omp's Mnemopi.
public struct TeammateMemoryStore: Sendable {
    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        public var id: Int64
        public var content: String
        public var tags: [String]
        public var createdAt: Date

        public init(id: Int64, content: String, tags: [String], createdAt: Date) {
            self.id = id
            self.content = content
            self.tags = tags
            self.createdAt = createdAt
        }
    }

    public let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    @discardableResult
    public func retain(content: String, tags: [String] = [], now: Date = Date()) throws -> Entry {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EngineError.message("Memory content must not be empty.")
        }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let cleanedTags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let tagsText = (try? JSONEncoder().encode(cleanedTags)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let timestamp = Int64(now.timeIntervalSince1970 * 1000)

        let sql = "INSERT INTO memories (content, tags, created_at) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EngineError.message("Failed to prepare memory insert: \(lastError(db))")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, trimmed, -1, transient)
        sqlite3_bind_text(stmt, 2, tagsText, -1, transient)
        sqlite3_bind_int64(stmt, 3, timestamp)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw EngineError.message("Failed to store memory: \(lastError(db))")
        }
        let id = sqlite3_last_insert_rowid(db)
        return Entry(id: id, content: trimmed, tags: cleanedTags, createdAt: now)
    }

    public func recall(query: String, limit: Int = 10) throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }
        let db = try openDatabase()
        defer { sqlite3_close(db) }

        let sql = "SELECT id, content, tags, created_at FROM memories ORDER BY created_at DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw EngineError.message("Failed to query memory: \(lastError(db))")
        }
        defer { sqlite3_finalize(stmt) }

        var all: [Entry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let content = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let tagsRaw = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let tags: [String]
            if tagsRaw.hasPrefix("["), let data = tagsRaw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                tags = decoded
            } else {
                tags = tagsRaw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            let ms = sqlite3_column_int64(stmt, 3)
            all.append(Entry(id: id, content: content, tags: tags, createdAt: Date(timeIntervalSince1970: Double(ms) / 1000.0)))
        }

        let maxCount = max(1, min(limit, 50))
        let terms = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !terms.isEmpty else {
            return Array(all.prefix(maxCount))
        }

        let scored: [(entry: Entry, score: Int)] = all.compactMap { entry in
            let haystack = (entry.content + " " + entry.tags.joined(separator: " ")).lowercased()
            let hits = terms.reduce(into: 0) { count, term in
                if haystack.contains(term) { count += 1 }
            }
            return hits > 0 ? (entry, hits) : nil
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.entry.createdAt > rhs.entry.createdAt
            }
            .prefix(maxCount)
            .map(\.entry)
    }

    private func openDatabase() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close(db) }
            throw EngineError.message("Could not open memory database: \(msg)")
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL,
            tags TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_memories_created ON memories(created_at DESC);
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            let msg = lastError(db)
            sqlite3_close(db)
            throw EngineError.message("Could not initialize memory schema: \(msg)")
        }
        return db
    }

    private func lastError(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
