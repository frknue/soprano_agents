import Foundation

/// Records completed and failed turns across ALL providers (`omp`, `codex`, `claude`, `antigravity`,
/// `opencode`) in an OS-agnostic append-only JSONL ledger (`<data>/usage-ledger.jsonl`) so the
/// Statistics board shows unified multi-provider usage alongside `omp`'s `stats.db`.
public final class LocalUsageLedger: UsageStatisticsService, @unchecked Sendable {
    public struct Entry: Codable, Sendable, Hashable {
        public var timestamp: Date
        public var provider: String
        public var model: String
        public var agent: String
        public var folder: String
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadTokens: Int
        public var cacheWriteTokens: Int
        public var costUSD: Double?
        public var failed: Bool

        public init(
            timestamp: Date,
            provider: String,
            model: String,
            agent: String,
            folder: String,
            inputTokens: Int,
            outputTokens: Int,
            cacheReadTokens: Int = 0,
            cacheWriteTokens: Int = 0,
            costUSD: Double? = nil,
            failed: Bool = false
        ) {
            self.timestamp = timestamp
            self.provider = provider
            self.model = model
            self.agent = agent
            self.folder = folder
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.costUSD = costUSD
            self.failed = failed
        }
    }

    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func record(_ entry: Entry) {
        lock.withLock {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .millisecondsSince1970
                var data = try encoder.encode(entry)
                data.append(0x0A)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: fileURL, options: .atomic)
                }
            } catch {
                // Usage recording must never break turn completion.
            }
        }
    }

    public func sync() async throws {}

    public func groups(since: Date?, granularity: UsageGranularity) async throws -> [UsageGroup] {
        let url = fileURL
        return await Task.detached(priority: .userInitiated) {
            Self.aggregate(fileURL: url, since: since, granularity: granularity, calendar: .current)
        }.value
    }

    static func aggregate(
        fileURL: URL,
        since: Date?,
        granularity: UsageGranularity,
        calendar: Calendar,
        excludingProviders: Set<String> = []
    ) -> [UsageGroup] {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8), !raw.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        struct Key: Hashable {
            var bucket: Date
            var provider: String
            var model: String
            var agent: String
            var folder: String
        }

        var buckets: [Key: UsageTotals] = [:]
        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(Entry.self, from: data)
            else { continue }
            if let since, entry.timestamp < since { continue }
            if excludingProviders.contains(entry.provider) { continue }

            let bucketStart: Date = switch granularity {
            case .hour:
                calendar.dateInterval(of: .hour, for: entry.timestamp)?.start ?? entry.timestamp
            case .day:
                calendar.startOfDay(for: entry.timestamp)
            }

            let estimated = Self.estimateCost(entry: entry)
            var totals = UsageTotals(
                requests: 1,
                failedRequests: entry.failed ? 1 : 0,
                inputTokens: max(0, entry.inputTokens),
                outputTokens: max(0, entry.outputTokens),
                cacheReadTokens: max(0, entry.cacheReadTokens),
                cacheWriteTokens: max(0, entry.cacheWriteTokens),
                inputCost: estimated?.input ?? 0,
                outputCost: estimated?.output ?? 0,
                cacheReadCost: estimated?.cacheRead ?? 0,
                cacheWriteCost: estimated?.cacheWrite ?? 0,
                unpricedRequests: (estimated == nil && (entry.inputTokens + entry.outputTokens) > 0) ? 1 : 0
            )
            if let explicitCost = entry.costUSD, explicitCost > 0, estimated == nil {
                totals.inputCost = explicitCost
                totals.unpricedRequests = 0
            }

            let key = Key(
                bucket: bucketStart,
                provider: entry.provider,
                model: entry.model,
                agent: entry.agent,
                folder: entry.folder
            )
            buckets[key, default: UsageTotals()].add(totals)
        }

        return buckets.map { key, totals in
            UsageGroup(
                start: key.bucket,
                provider: key.provider,
                model: key.model,
                agent: key.agent,
                folder: key.folder,
                totals: totals
            )
        }.sorted { $0.start < $1.start }
    }

    private struct TokenCost {
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
    }

    /// Lightweight per-million-token USD API-equivalent rates for common models when the provider
    /// does not report explicit dollar cost.
    private static func estimateCost(entry: Entry) -> TokenCost? {
        let model = entry.model.lowercased()
        let rates: (input: Double, output: Double, cacheRead: Double, cacheWrite: Double)?
        if model.contains("opus") {
            rates = (15.0, 75.0, 1.5, 18.75)
        } else if model.contains("sonnet") {
            rates = (3.0, 15.0, 0.3, 3.75)
        } else if model.contains("haiku") {
            rates = (0.8, 4.0, 0.08, 1.0)
        } else if model.contains("gpt-5") || model.contains("codex") {
            rates = (2.5, 10.0, 0.25, 0.0)
        } else if model.contains("o3") || model.contains("o4") {
            rates = (2.0, 8.0, 0.5, 0.0)
        } else if model.contains("gemini") && model.contains("flash") {
            rates = (0.3, 2.5, 0.075, 0.0)
        } else if model.contains("gemini") {
            rates = (1.25, 10.0, 0.31, 0.0)
        } else {
            rates = nil
        }
        guard let rates else { return nil }
        return TokenCost(
            input: Double(max(0, entry.inputTokens)) / 1_000_000.0 * rates.input,
            output: Double(max(0, entry.outputTokens)) / 1_000_000.0 * rates.output,
            cacheRead: Double(max(0, entry.cacheReadTokens)) / 1_000_000.0 * rates.cacheRead,
            cacheWrite: Double(max(0, entry.cacheWriteTokens)) / 1_000_000.0 * rates.cacheWrite
        )
    }
}
