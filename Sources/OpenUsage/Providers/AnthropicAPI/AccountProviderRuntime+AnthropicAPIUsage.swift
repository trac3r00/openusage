import Foundation

extension AccountProviderRuntime {
    /// Reads the last 30 local days on every refresh; a rejected key fails the card.
    ///
    /// Today and yesterday come from hourly buckets, so they follow this Mac's time zone. Older days
    /// come from daily buckets, which end where the hourly range starts: at the UTC midnight before
    /// yesterday began here, so no hour is read twice or skipped.
    func refreshAnthropicAPI(_ credential: AccountCredential) async throws -> ProviderUsage {
        guard case .apiKey(let apiKey) = credential else { throw ProviderError.invalidResponse }
        let client = AnthropicAPIUsageClient(http: http)
        let asOf = now()
        let calendar = Calendar.current
        let span = UsageHistory.dayStarts(0..<30, now: asOf, calendar: calendar)
        guard let yesterday = span.dropFirst().first, let oldest = span.last else { throw ProviderError.invalidResponse }
        let hourlyStart = Calendar.utc.startOfDay(for: yesterday)
        let dailyStart = Calendar.utc.startOfDay(for: oldest)

        async let hourlyCost = client.rows(.cost, apiKey: apiKey, from: hourlyStart, to: asOf, bucket: .hour)
        async let hourlyUsage = client.rows(.usage, apiKey: apiKey, from: hourlyStart, to: asOf, bucket: .hour)
        async let dailyCost = client.rows(.cost, apiKey: apiKey, from: dailyStart, to: hourlyStart, bucket: .day)
        async let dailyUsage = client.rows(.usage, apiKey: apiKey, from: dailyStart, to: hourlyStart, bucket: .day)
        async let keyNames = client.apiKeyNames(apiKey: apiKey)

        let names = await keyNames
        var read = AnthropicAPIRead()
        try AnthropicAPIUsageMapper.add(costPages: try await hourlyCost, usagePages: try await hourlyUsage,
                                        placement: .hourly, keyNames: names, calendar: calendar, to: &read)
        try AnthropicAPIUsageMapper.add(costPages: try await dailyCost, usagePages: try await dailyUsage,
                                        placement: .dailyByUTCDate, keyNames: names, calendar: calendar, to: &read)

        func history(_ days: [Date: UsageDay]) -> UsageHistory {
            UsageHistory(calendar: calendar, asOf: asOf,
                         days: Dictionary(uniqueKeysWithValues: span.map { ($0, days[$0] ?? AnthropicAPIUsageMapper.quietDay) }))
        }
        var usage = ProviderUsage(plan: nil, lines: [], history: history(read.days))
        usage.spendHistories = [  // PERSONAL BUILD: Total Spend
            ReportedSpendBreakdowns.claudeCode: history(read.claudeCodeDays),
            ReportedSpendBreakdowns.apiKeys: history(read.keyDays)
        ]
        return usage
    }
}
