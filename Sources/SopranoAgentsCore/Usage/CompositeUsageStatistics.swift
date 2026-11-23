import Foundation

/// Combines `OmpUsageStatistics` (full omp TUI + GUI history from `~/.omp/stats.db`) with
/// `LocalUsageLedger` (all turns run through Soprano Agents across Codex, Claude Code, Antigravity,
/// OpenCode, and omp). Excludes `.omp` rows from the local ledger whenever omp's own database is
/// present so omp turns are never double-counted.
public struct CompositeUsageStatistics: UsageStatisticsService {
    private let omp: any UsageStatisticsService
    private let ledger: LocalUsageLedger

    public init(omp: any UsageStatisticsService, ledger: LocalUsageLedger) {
        self.omp = omp
        self.ledger = ledger
    }

    public func sync() async throws {
        // If omp is not installed on a Codex/Claude-only machine, don't fail the whole stats board.
        do {
            try await omp.sync()
        } catch ProviderError.notInstalled {
            return
        }
    }

    public func groups(since: Date?, granularity: UsageGranularity) async throws -> [UsageGroup] {
        var ompGroups: [UsageGroup] = []
        var ompHasData = false
        if let read = try? await omp.groups(since: since, granularity: granularity), !read.isEmpty {
            ompGroups = read
            ompHasData = true
        }
        let ledgerURL = ledger.fileURL
        let excluded: Set<String> = ompHasData ? [ProviderKind.omp.rawValue] : []
        let localGroups = await Task.detached(priority: .userInitiated) {
            LocalUsageLedger.aggregate(
                fileURL: ledgerURL,
                since: since,
                granularity: granularity,
                calendar: .current,
                excludingProviders: excluded
            )
        }.value
        return (ompGroups + localGroups).sorted { $0.start < $1.start }
    }
}
