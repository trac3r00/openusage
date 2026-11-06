import Foundation

struct TotalSpendAccount: Sendable {
    let id: String
    let kind: ProviderKind
    let label: String
    let snapshot: ProviderSnapshot?

    init(id: String? = nil, kind: ProviderKind, label: String = "", snapshot: ProviderSnapshot?) {
        self.id = id ?? snapshot?.providerID ?? kind.rawValue
        self.kind = kind
        self.label = label
        self.snapshot = snapshot
    }
}

/// Builds the Total Spend card's slices.
///
/// - Claude, Codex, Grok and OpenCode use this Mac's local logs, priced locally (estimated). The logs
///   belong to the Mac, not to an account, so a provider gets one slice however many accounts it has.
/// - Every other provider gets one slice per account, from what that account's API reported for the
///   period (not estimated). A provider with several accounts names each slice after its account.
/// - Codex reports tokens too. When a local estimate exists for the period it wins and the reported
///   figure is dropped, because both count the same requests and adding them would double count.
enum TotalSpendAggregator {
    static let localLogKinds: Set<ProviderKind> = [.claude, .codex, .grok, .opencodeGo]

    static func total(
        for period: TotalSpendPeriod,
        accounts: [TotalSpendAccount],
        localScans: [ProviderKind: LogUsageScan],
        now: Date,
        calendar: Calendar = .current
    ) -> TotalSpend {
        var kinds: [ProviderKind] = []
        for account in accounts where !kinds.contains(account.kind) { kinds.append(account.kind) }

        let slices = kinds.flatMap { kind -> [TotalSpendSlice] in
            let kindAccounts = accounts.filter { $0.kind == kind }
            let named = kindAccounts.count > 1
            if localLogKinds.contains(kind), let scan = localScans[kind],
               let local = localSlice(kind: kind, scan: scan, period: period, now: now, calendar: calendar) {
                return [local.labeled(named ? "This Mac" : nil)]
            }
            // Claude Code billed to an Anthropic API organization is already in Claude's local logs
            // when this Mac has them, so the organization's slice leaves its Claude Code rows out.
            let claudeCodeCountedLocally = kind == .anthropicAPI && claudeLocallyCounted(
                accounts: accounts, localScans: localScans, period: period, now: now, calendar: calendar
            )
            return kindAccounts.compactMap { account in
                let breakdowns = account.snapshot?.usageBreakdowns ?? [:]
                // A snapshot read on an earlier day still holds that day's "Today"; it counts for
                // nothing until the account refreshes.
                guard let breakdown = breakdowns[ReportedSpendBreakdowns.key(for: period)],
                      breakdown.archivedTitle(at: now) == nil
                else { return nil }
                let excluded = claudeCodeCountedLocally
                    ? breakdowns[ReportedSpendBreakdowns.key(for: period, part: ReportedSpendBreakdowns.claudeCode)] : nil
                let spenders = breakdowns[ReportedSpendBreakdowns.key(for: period, part: ReportedSpendBreakdowns.apiKeys)]
                return reportedSlice(kind: kind, breakdowns: [breakdown], excluding: excluded, spenders: spenders,
                                     dropsClaudeCodeSpender: excluded != nil)
                    .map { $0.identified(account.id, label: named ? account.label : nil) }
            }
        }
        return TotalSpend(period: period, slices: slices)
    }

    static func localSlice(
        kind: ProviderKind, scan: LogUsageScan, period: TotalSpendPeriod, now: Date, calendar: Calendar
    ) -> TotalSpendSlice? {
        guard let offsets = period.window.dayOffsets else { return nil }
        let dayKeys = Set(UsageHistory.dayStarts(offsets, now: now, calendar: calendar)
            .map { DailyUsageAccumulator.dayKey(from: $0, calendar: calendar) })
        let days = scan.series.daily.filter { dayKeys.contains($0.date) }
        let dollars = days.reduce(0) { $0 + max($1.costUSD ?? 0, 0) }
        let tokens = Double(days.reduce(0) { $0 + max($1.totalTokens, 0) })
        guard dollars > 0 || tokens > 0 else { return nil }

        var models = ModelMerger()
        for day in scan.modelUsage?.daily ?? [] where dayKeys.contains(day.date) {
            for model in day.models {
                models.add(TotalSpendModel(name: model.model, dollars: model.costUSD, tokens: Double(model.totalTokens)))
            }
        }
        return TotalSpendSlice(id: "\(kind.rawValue).local", kind: kind, amountUSD: dollars, tokenCount: tokens,
                               estimated: true, models: models.result)
    }

    /// Whether Claude's local logs make a slice for the period, so its Claude Code use is counted there.
    private static func claudeLocallyCounted(
        accounts: [TotalSpendAccount], localScans: [ProviderKind: LogUsageScan], period: TotalSpendPeriod, now: Date, calendar: Calendar
    ) -> Bool {
        guard accounts.contains(where: { $0.kind == .claude }), let scan = localScans[.claude] else { return false }
        return localSlice(kind: .claude, scan: scan, period: period, now: now, calendar: calendar) != nil
    }

    static func reportedSlice(
        kind: ProviderKind, breakdowns: [UsageBreakdown], excluding excluded: UsageBreakdown? = nil,
        spenders: UsageBreakdown? = nil, dropsClaudeCodeSpender: Bool = false
    ) -> TotalSpendSlice? {
        var dollars = 0.0
        var tokens = 0.0
        var models = ModelMerger()
        for breakdown in breakdowns {
            dollars += amount(breakdown)
            tokens += max(breakdown.totals[.tokens] ?? 0, 0)
            models.addRanked(breakdown)
        }
        if let excluded {
            dollars = max(dollars - amount(excluded), 0)
            tokens = max(tokens - max(excluded.totals[.tokens] ?? 0, 0), 0)
            models.subtractRanked(excluded)
        }
        guard dollars > 0 || tokens > 0 else { return nil }
        var keys = ModelMerger()
        if let spenders { keys.addRanked(spenders) }
        let keyResult = keys.result.filter { !(dropsClaudeCodeSpender && $0.name == AnthropicAPIUsageMapper.claudeCodeName) }
        return TotalSpendSlice(kind: kind, amountUSD: dollars, tokenCount: tokens, estimated: false,
                               models: models.result, spenders: keyResult)
    }

    private static func amount(_ breakdown: UsageBreakdown) -> Double {
        max(breakdown.totals[.spend] ?? breakdown.totals[.usageValue] ?? 0, 0)
    }

    /// Adds models up by name. A reported breakdown lists a model under both its cost and its token
    /// ranking, so `once` keeps one copy per source; "Other" lumps unnamed models and never ranks.
    private struct ModelMerger {
        private var merged: [String: TotalSpendModel] = [:]
        private var order: [String] = []
        private var seenInSource: Set<String> = []

        var result: [TotalSpendModel] { order.compactMap { merged[$0] } }

        mutating func add(_ model: TotalSpendModel, once: Bool = false) {
            guard model.name != UsageBreakdownOther.name, !model.name.isEmpty else { return }
            if once, !seenInSource.insert(model.name).inserted { return }
            guard var existing = merged[model.name] else {
                merged[model.name] = model
                order.append(model.name)
                return
            }
            existing.dollars = Self.sum(existing.dollars, model.dollars)
            existing.tokens = Self.sum(existing.tokens, model.tokens)
            merged[model.name] = existing
        }

        mutating func finishSource() { seenInSource = [] }

        /// A reported breakdown lists each model under both its cost and its token ranking.
        mutating func addRanked(_ breakdown: UsageBreakdown) {
            for model in breakdown.models(by: .cost) + breakdown.models(by: .tokens) {
                add(TotalSpendModel(name: model.name, dollars: model.dollars, tokens: model.tokens), once: true)
            }
            finishSource()
        }

        /// Takes another breakdown's models back out, dropping any left with nothing.
        mutating func subtractRanked(_ breakdown: UsageBreakdown) {
            var removed = ModelMerger()
            removed.addRanked(breakdown)
            for model in removed.result {
                guard var existing = merged[model.name] else { continue }
                existing.dollars = existing.dollars.map { max($0 - (model.dollars ?? 0), 0) }
                existing.tokens = existing.tokens.map { max($0 - (model.tokens ?? 0), 0) }
                if (existing.dollars ?? 0) <= 0, (existing.tokens ?? 0) <= 0 {
                    merged[model.name] = nil
                    order.removeAll { $0 == model.name }
                } else {
                    merged[model.name] = existing
                }
            }
        }

        private static func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
            guard lhs != nil || rhs != nil else { return nil }
            return (lhs ?? 0) + (rhs ?? 0)
        }
    }
}

private enum UsageBreakdownOther {
    static let name = "Other"
}

/// Keeps each account's reported totals for the Total Spend periods with its snapshot, so the card
/// can read Today / Yesterday / 30 Days for providers whose own rows show other windows.
enum ReportedSpendBreakdowns {
    /// Anthropic API's Claude Code rows alone.
    static let claudeCode = "claudeCode"
    /// Anthropic API's spend by API key, with key names in place of model names.
    static let apiKeys = "apiKeys"

    static func key(for period: TotalSpendPeriod, part: String? = nil) -> String {
        "personalSpend.\(period.rawValue)" + (part.map { ".\($0)" } ?? "")
    }

    static func append(to snapshot: inout ProviderSnapshot, in history: UsageHistory?, parts: [String: UsageHistory] = [:]) {
        guard let history else { return }
        var breakdowns = snapshot.usageBreakdowns ?? [:]
        for period in TotalSpendPeriod.allCases {
            breakdowns[key(for: period)] = UsageBreakdown(period.window, in: history)
            for (part, partHistory) in parts {
                breakdowns[key(for: period, part: part)] = UsageBreakdown(period.window, in: partHistory)
            }
        }
        snapshot.usageBreakdowns = breakdowns
    }
}
