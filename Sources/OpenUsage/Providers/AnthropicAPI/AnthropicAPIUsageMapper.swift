import Foundation

/// What one read of the Analytics reports holds, per local day.
struct AnthropicAPIRead: Equatable, Sendable {
    /// Every row: spend, tokens by kind, and both by model.
    var days: [Date: UsageDay] = [:]
    /// Only Claude Code's rows, so a Mac that also counts Claude Code from its logs can leave them out.
    var claudeCodeDays: [Date: UsageDay] = [:]
    /// Spend and tokens by API key name, carried in `byModel`.
    var keyDays: [Date: UsageDay] = [:]
}

enum AnthropicAPIUsageMapper {
    static let claudeCodeProduct = "claude_code"
    static let noKeyName = "No API Key"
    static let claudeCodeName = "Claude Code"
    private static let measures: [UsageMeasure] = [.spend, .tokens, .inputTokens, .cacheReadTokens, .cacheWriteTokens, .outputTokens]
    static let quietDay = UsageDay(totals: .zero(measures), byModel: [:])

    /// How a row's UTC bucket maps to a local day. An hourly bucket lands on the local day holding its
    /// start, which is exact in any whole-hour time zone. A daily bucket can't be split, so it lands on
    /// the local day with its UTC date, the way the Claude Console labels it.
    enum Placement: Sendable {
        case hourly
        case dailyByUTCDate
    }

    /// The `page` to ask for next, or nil on the last page.
    static func nextPage(_ body: Data) throws -> String? {
        try cursor(body, key: "next_page")
    }

    /// The `after_id` to ask for next on the API key list, or nil on the last page.
    static func lastID(_ body: Data) throws -> String? {
        try cursor(body, key: "last_id")
    }

    static func keyNames(_ pages: [Data]) throws -> [String: String] {
        var names: [String: String] = [:]
        for body in pages {
            guard let keys = ProviderParse.jsonObject(body)?["data"] as? [[String: Any]] else { throw ProviderError.invalidResponse }
            for key in keys {
                guard let id = (key["id"] as? String)?.nilIfEmpty else { continue }
                names[id] = (key["name"] as? String)?.nilIfEmpty ?? id
            }
        }
        return names
    }

    /// Adds cost and usage pages to `read`. A cost row with no model, such as web search or code
    /// execution, counts toward the day's spend and no model's.
    static func add(
        costPages: [Data], usagePages: [Data], placement: Placement, keyNames: [String: String]?,
        calendar: Calendar, to read: inout AnthropicAPIRead
    ) throws {
        for (row, day) in try rows(costPages, placement: placement, calendar: calendar) {
            try add(costTotals(row), row: row, on: day, keyNames: keyNames, to: &read)
        }
        for (row, day) in try rows(usagePages, placement: placement, calendar: calendar) {
            try add(tokenTotals(row), row: row, on: day, keyNames: keyNames, to: &read)
        }
    }

    private static func add(
        _ totals: UsageTotals, row: [String: Any], on day: Date, keyNames: [String: String]?, to read: inout AnthropicAPIRead
    ) throws {
        let group = row["group"] as? [String: Any] ?? [:]
        let model = (group["model"] as? String)?.nilIfEmpty
        let isClaudeCode = (group["product"] as? String) == claudeCodeProduct
        merge(totals, under: model, on: day, into: &read.days)
        if isClaudeCode { merge(totals, under: model, on: day, into: &read.claudeCodeDays) }
        merge(totals, under: keyName(group["api_key_id"] as? String, claudeCode: isClaudeCode, names: keyNames),
              on: day, into: &read.keyDays)
    }

    private static func merge(_ totals: UsageTotals, under name: String?, on day: Date, into days: inout [Date: UsageDay]) {
        let current = days[day] ?? quietDay
        var named = current.byModel ?? [:]
        if let name { named[name] = named[name].map { $0.adding(totals) } ?? totals }
        days[day] = UsageDay(totals: current.totals.adding(totals), byModel: named)
    }

    /// Claude Code is one spender whichever key it used, so the Total Spend card can drop it whole when
    /// this Mac's logs already count it.
    private static func keyName(_ id: String?, claudeCode: Bool, names: [String: String]?) -> String {
        if claudeCode { return claudeCodeName }
        guard let id = id?.nilIfEmpty else { return noKeyName }
        return names?[id] ?? "Key \(id.suffix(6))"
    }

    private static func rows(_ pages: [Data], placement: Placement, calendar: Calendar) throws -> [([String: Any], Date)] {
        try pages.flatMap { body -> [([String: Any], Date)] in
            guard let rows = ProviderParse.jsonObject(body)?["data"] as? [[String: Any]] else { throw ProviderError.invalidResponse }
            return try rows.map { row in
                guard let start = (row["starting_at"] as? String).flatMap(OpenUsageISO8601.date(from:)) else {
                    throw ProviderError.invalidResponse
                }
                return (row, try day(holding: start, placement: placement, calendar: calendar))
            }
        }
    }

    private static func day(holding start: Date, placement: Placement, calendar: Calendar) throws -> Date {
        switch placement {
        case .hourly:
            return calendar.startOfDay(for: start)
        case .dailyByUTCDate:
            let date = Calendar.utc.dateComponents([.year, .month, .day], from: start)
            guard let day = calendar.date(from: date) else { throw ProviderError.invalidResponse }
            return calendar.startOfDay(for: day)
        }
    }

    /// `amount` is a decimal string in cents, after discounts and before credits.
    private static func costTotals(_ row: [String: Any]) throws -> UsageTotals {
        guard let cost = row["cost"] as? [String: Any], let cents = ProviderParse.number(cost["amount"]),
              (cost["currency"] as? String ?? "USD") == "USD"
        else { throw ProviderError.invalidResponse }
        return UsageTotals(values: [.spend: cents / 100])
    }

    /// Cache writes are the 1-hour and 5-minute ephemeral writes together; tokens are every kind summed.
    private static func tokenTotals(_ row: [String: Any]) throws -> UsageTotals {
        guard let usage = row["usage"] as? [String: Any] else { throw ProviderError.invalidResponse }
        func count(_ value: Any?, required: Bool) throws -> Double {
            guard let value, !(value is NSNull) else {
                if required { throw ProviderError.invalidResponse }
                return 0
            }
            guard let number = ProviderParse.number(value), number >= 0 else { throw ProviderError.invalidResponse }
            return number
        }
        let cacheCreation = usage["cache_creation"] as? [String: Any] ?? [:]
        let input = try count(usage["uncached_input_tokens"], required: true)
        let cacheRead = try count(usage["cache_read_input_tokens"], required: false)
        let cacheWrite = try count(cacheCreation["ephemeral_1h_input_tokens"], required: false)
            + count(cacheCreation["ephemeral_5m_input_tokens"], required: false)
        let output = try count(usage["output_tokens"], required: true)
        return UsageTotals(values: [
            .tokens: input + cacheRead + cacheWrite + output,
            .inputTokens: input, .cacheReadTokens: cacheRead, .cacheWriteTokens: cacheWrite, .outputTokens: output
        ])
    }

    private static func cursor(_ body: Data, key: String) throws -> String? {
        guard let object = ProviderParse.jsonObject(body), let hasMore = object["has_more"] as? Bool else {
            throw ProviderError.invalidResponse
        }
        guard hasMore else { return nil }
        guard let next = (object[key] as? String)?.nilIfEmpty else { throw ProviderError.invalidResponse }
        return next
    }
}
