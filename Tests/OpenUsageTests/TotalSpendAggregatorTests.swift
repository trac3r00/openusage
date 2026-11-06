import XCTest
@testable import OpenUsage

// PERSONAL BUILD: Total Spend aggregation.
final class TotalSpendAggregatorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private func scan(_ days: [(String, Int, Double, String)]) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        for (day, tokens, cost, model) in days { accumulator.add(day: day, tokens: tokens, cost: cost, model: model) }
        return accumulator.build()
    }

    private func snapshot(id: String, kind: ProviderKind, days: [Date: UsageDay], asOf: Date? = nil) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(providerID: id, displayName: kind.displayName, lines: [])
        ReportedSpendBreakdowns.append(to: &snapshot, in: UsageHistory(calendar: calendar, asOf: asOf ?? now, days: days))
        return snapshot
    }

    private func day(_ offset: Int) -> Date {
        UsageHistory.dayStarts([offset], now: now, calendar: calendar)[0]
    }

    private func reportedDay(spend: Double? = nil, tokens: Double? = nil, model: String) -> UsageDay {
        var totals = UsageTotals()
        totals.values[.spend] = spend
        totals.values[.tokens] = tokens
        return UsageDay(totals: totals, byModel: [model: totals])
    }

    func testLocalLogsCountOnlyForProvidersWithAnAccount() {
        let scans: [ProviderKind: LogUsageScan] = [
            .claude: scan([("2026-07-12", 1_000, 4, "claude-sonnet-5.5")]),
            .grok: scan([("2026-07-12", 500, 2, "grok-5")])
        ]
        let accounts = [TotalSpendAccount(kind: .grok, snapshot: nil)]

        let total = TotalSpendAggregator.total(for: .today, accounts: accounts, localScans: scans, now: now, calendar: calendar)

        XCTAssertEqual(total.slices.map(\.kind), [.grok])
        XCTAssertEqual(total.slices.first?.amountUSD, 2)
        XCTAssertEqual(total.slices.first?.estimated, true)
    }

    func testLocalLogsMakeOneSlicePerProviderHoweverManyAccounts() {
        let scans: [ProviderKind: LogUsageScan] = [.claude: scan([("2026-07-12", 1_000, 4, "claude-sonnet-5.5")])]
        let accounts = [TotalSpendAccount(kind: .claude, snapshot: nil), TotalSpendAccount(kind: .claude, snapshot: nil)]

        let total = TotalSpendAggregator.total(for: .today, accounts: accounts, localScans: scans, now: now, calendar: calendar)

        XCTAssertEqual(total.slices.count, 1)
        XCTAssertEqual(total.slices.first?.amountUSD, 4)
    }

    func testReportedSpendMakesOneNamedSlicePerAccount() {
        let accounts = [
            TotalSpendAccount(id: "a", kind: .cursor, label: "Work",
                              snapshot: snapshot(id: "a", kind: .cursor, days: [day(0): reportedDay(spend: 3, tokens: 100, model: "gpt-6")])),
            TotalSpendAccount(id: "b", kind: .cursor, label: "Personal",
                              snapshot: snapshot(id: "b", kind: .cursor, days: [day(0): reportedDay(spend: 2, tokens: 50, model: "gpt-6")]))
        ]

        let total = TotalSpendAggregator.total(for: .today, accounts: accounts, localScans: [:], now: now, calendar: calendar)

        XCTAssertEqual(total.slices.map(\.id), ["a", "b"])
        XCTAssertEqual(total.slices.map(\.title), ["Cursor · Work", "Cursor · Personal"])
        XCTAssertEqual(total.slices.map(\.amountUSD), [3, 2])
        XCTAssertEqual(total.slices.map(\.estimated), [false, false])
        XCTAssertEqual(total.projection(for: .cost).topModel, TotalSpendModel(name: "gpt-6", dollars: 5, tokens: 150))
    }

    func testASingleAccountSliceCarriesNoAccountName() {
        let accounts = [TotalSpendAccount(id: "a", kind: .cursor, label: "Work",
                                          snapshot: snapshot(id: "a", kind: .cursor, days: [day(0): reportedDay(spend: 3, model: "m")]))]

        let total = TotalSpendAggregator.total(for: .today, accounts: accounts, localScans: [:], now: now, calendar: calendar)

        XCTAssertEqual(total.slices.map(\.title), ["Cursor"])
    }

    func testClaudeCodeBilledToAnAPIOrganizationCountsOnceWhenLocalLogsHaveIt() {
        let all = reportedDay(spend: 10, tokens: 1_000, model: "claude-sonnet-5")
        let claudeCode = reportedDay(spend: 4, tokens: 400, model: "claude-sonnet-5")
        var keys = UsageTotals()
        keys.values[.spend] = 10
        let keyDay = UsageDay(totals: keys, byModel: ["Production": UsageTotals(values: [.spend: 6]), "Claude Code": UsageTotals(values: [.spend: 4])])
        var org = ProviderSnapshot(providerID: "org", displayName: "Anthropic API", lines: [])
        ReportedSpendBreakdowns.append(
            to: &org, in: UsageHistory(calendar: calendar, asOf: now, days: [day(0): all]),
            parts: [ReportedSpendBreakdowns.claudeCode: UsageHistory(calendar: calendar, asOf: now, days: [day(0): claudeCode]),
                    ReportedSpendBreakdowns.apiKeys: UsageHistory(calendar: calendar, asOf: now, days: [day(0): keyDay])]
        )
        let accounts = [TotalSpendAccount(id: "org", kind: .anthropicAPI, snapshot: org), TotalSpendAccount(kind: .claude, snapshot: nil)]
        let local: [ProviderKind: LogUsageScan] = [.claude: scan([("2026-07-12", 400, 4, "claude-sonnet-5")])]

        let deduped = TotalSpendAggregator.total(for: .today, accounts: accounts, localScans: local, now: now, calendar: calendar)
        let withoutLogs = TotalSpendAggregator.total(for: .today, accounts: accounts, localScans: [:], now: now, calendar: calendar)

        let org1 = deduped.slices.first { $0.kind == .anthropicAPI }
        XCTAssertEqual(org1?.amountUSD, 6)
        XCTAssertEqual(org1?.tokenCount, 600)
        XCTAssertEqual(org1?.spenders.map(\.name), ["Production"])
        let org2 = withoutLogs.slices.first { $0.kind == .anthropicAPI }
        XCTAssertEqual(org2?.amountUSD, 10)
        XCTAssertEqual(Set(org2?.spenders.map(\.name) ?? []), ["Production", "Claude Code"])
    }

    func testASnapshotFromAnEarlierDayCountsForNothing() {
        let yesterday = now.addingTimeInterval(-86_400)
        let stale = snapshot(id: "a", kind: .cursor, days: [day(1): reportedDay(spend: 7, model: "m")], asOf: yesterday)

        let total = TotalSpendAggregator.total(for: .today, accounts: [TotalSpendAccount(id: "a", kind: .cursor, snapshot: stale)],
                                               localScans: [:], now: now, calendar: calendar)

        XCTAssertTrue(total.isEmpty)
    }

    func testCodexLocalEstimateReplacesReportedTokensInsteadOfAdding() {
        let codex = TotalSpendAccount(kind: .codex, snapshot: snapshot(id: "c", kind: .codex, days: [day(0): reportedDay(tokens: 9_000, model: "gpt-6")]))
        let local: [ProviderKind: LogUsageScan] = [.codex: scan([("2026-07-12", 1_000, 1.5, "gpt-6")])]

        let withLocal = TotalSpendAggregator.total(for: .today, accounts: [codex], localScans: local, now: now, calendar: calendar)
        let withoutLocal = TotalSpendAggregator.total(for: .today, accounts: [codex], localScans: [:], now: now, calendar: calendar)

        XCTAssertEqual(withLocal.slices.map(\.tokenCount), [1_000])
        XCTAssertEqual(withLocal.slices.first?.estimated, true)
        XCTAssertEqual(withoutLocal.slices.map(\.tokenCount), [9_000])
        XCTAssertEqual(withoutLocal.slices.first?.estimated, false)
    }

    func testPeriodsSelectTheirDaysAndIdleProvidersAreOmitted() {
        let scans: [ProviderKind: LogUsageScan] = [
            .claude: scan([("2026-07-11", 1_000, 4, "a"), ("2026-06-20", 1_000, 6, "a"), ("2026-05-01", 1_000, 100, "a")]),
            .grok: scan([("2026-07-11", 0, 0, "g")])
        ]
        let accounts = [TotalSpendAccount(kind: .claude, snapshot: nil), TotalSpendAccount(kind: .grok, snapshot: nil)]
        func amount(_ period: TotalSpendPeriod) -> [Double] {
            TotalSpendAggregator.total(for: period, accounts: accounts, localScans: scans, now: now, calendar: calendar).slices.map(\.amountUSD)
        }

        XCTAssertEqual(amount(.today), [])
        XCTAssertEqual(amount(.yesterday), [4])
        XCTAssertEqual(amount(.last30), [10])
    }

    func testProjectionRanksBiggestFirstAndFindsTheTopModelAcrossProviders() {
        let total = TotalSpend(period: .today, slices: [
            TotalSpendSlice(kind: .openrouter, amountUSD: 2, tokenCount: 1_000_000, estimated: false,
                            models: [TotalSpendModel(name: "shared", dollars: 2, tokens: 1_000_000)]),
            TotalSpendSlice(kind: .claude, amountUSD: 9, tokenCount: 1_000_000, estimated: true,
                            models: [TotalSpendModel(name: "big", dollars: 6, tokens: 100), TotalSpendModel(name: "shared", dollars: 5, tokens: 10)])
        ])

        let cost = total.projection(for: .cost)
        XCTAssertEqual(cost.slices.map(\.slice.kind), [.claude, .openrouter])
        XCTAssertEqual(cost.centerValue, 11)
        XCTAssertTrue(cost.isEstimated)
        XCTAssertEqual(cost.topModel?.name, "shared")
        XCTAssertEqual(cost.topModel?.dollars, 7)

        let tokens = total.projection(for: .tokens)
        XCTAssertFalse(tokens.isEstimated)
        XCTAssertEqual(tokens.topModel?.name, "shared")

        let rate = total.projection(for: .costPerMtok)
        XCTAssertEqual(rate.centerValue, 5.5, accuracy: 0.0001)
        XCTAssertEqual(rate.slices.map(\.displayAmount), [9, 2])
    }

    func testTiesKeepTheUsersProviderOrder() {
        let total = TotalSpend(period: .today, slices: [
            TotalSpendSlice(kind: .ollama, amountUSD: 1, tokenCount: 0, estimated: false, models: []),
            TotalSpendSlice(kind: .cursor, amountUSD: 1, tokenCount: 0, estimated: false, models: [])
        ])

        XCTAssertEqual(total.projection(for: .cost).slices.map(\.slice.kind), [.ollama, .cursor])
        XCTAssertTrue(total.projection(for: .tokens).isEmpty)
    }
}
