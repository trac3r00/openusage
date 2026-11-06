import Foundation

enum TotalSpendSetting {
    static let enabledKey = "personalSpend.totalSpendEnabled"
    static let periodKey = "personalSpend.totalSpendPeriod"
    static let metricKey = "personalSpend.totalSpendMetric"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}

enum TotalSpendPeriod: String, CaseIterable, Identifiable, Sendable {
    case today
    case yesterday
    case last30

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .last30: "30 Days"
        }
    }

    var window: UsageWindow {
        switch self {
        case .today: .today
        case .yesterday: .yesterday
        case .last30: .lastDays(30)
        }
    }
}

/// Raw values match 0.7.16 so a stored selection carries over.
enum TotalSpendMetric: String, CaseIterable, Identifiable, Sendable {
    case cost = "apiSpend"
    case costPerMtok
    case tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost: "Cost"
        case .costPerMtok: "Cost/MTok"
        case .tokens: "Tokens"
        }
    }

    var emptyMessage: String {
        switch self {
        case .cost: "No cost data for this period"
        case .costPerMtok: "No cost-per-token data for this period"
        case .tokens: "No token data for this period"
        }
    }

    var usesDollarEstimateNote: Bool { self != .tokens }

    static let localEstimateNote = "Estimated locally, so it may be off"
}

struct TotalSpendModel: Equatable, Sendable {
    let name: String
    var dollars: Double?
    var tokens: Double?

    var costPerMtok: Double? {
        guard let dollars, let tokens, dollars > 0, tokens > 0 else { return nil }
        return dollars / tokens * 1_000_000
    }

    func number(for metric: TotalSpendMetric) -> Double? {
        switch metric {
        // Cost/MTok ranks models by what they cost, then shows that model's rate: ranking by rate alone
        // would crown a model with a handful of expensive tokens.
        case .cost, .costPerMtok: dollars.flatMap { $0 > 0 ? $0 : nil }
        case .tokens: tokens.flatMap { $0 > 0 ? $0 : nil }
        }
    }
}

/// One arc of the ring: an account's reported usage, or a provider's whole local-log estimate.
struct TotalSpendSlice: Identifiable, Equatable, Sendable {
    /// The account's card ID, or `<kind>.local` for a provider's local logs.
    let id: String
    let kind: ProviderKind
    /// Names the account when its provider has more than one; nil otherwise.
    let label: String?
    let amountUSD: Double
    let tokenCount: Double
    let estimated: Bool
    let models: [TotalSpendModel]
    /// Where the money went beyond models, such as API keys; empty for providers that don't report it.
    let spenders: [TotalSpendModel]

    init(
        id: String? = nil, kind: ProviderKind, label: String? = nil,
        amountUSD: Double, tokenCount: Double, estimated: Bool, models: [TotalSpendModel], spenders: [TotalSpendModel] = []
    ) {
        self.id = id ?? kind.rawValue
        self.kind = kind
        self.label = label
        self.amountUSD = amountUSD
        self.tokenCount = tokenCount
        self.estimated = estimated
        self.models = models
        self.spenders = spenders
    }

    var title: String { label.map { "\(kind.displayName) · \($0)" } ?? kind.displayName }

    func identified(_ id: String, label: String?) -> TotalSpendSlice {
        TotalSpendSlice(id: id, kind: kind, label: label, amountUSD: amountUSD, tokenCount: tokenCount,
                        estimated: estimated, models: models, spenders: spenders)
    }

    func labeled(_ label: String?) -> TotalSpendSlice { identified(id, label: label) }

    var costPerMtok: Double? {
        guard amountUSD > 0, tokenCount > 0 else { return nil }
        return amountUSD / tokenCount * 1_000_000
    }

    func rankedModels(by metric: TotalSpendMetric) -> [TotalSpendModel] { Self.ranked(models, by: metric) }

    func rankedSpenders(by metric: TotalSpendMetric) -> [TotalSpendModel] { Self.ranked(spenders, by: metric) }

    private static func ranked(_ models: [TotalSpendModel], by metric: TotalSpendMetric) -> [TotalSpendModel] {
        models.filter { $0.number(for: metric) != nil }.sorted {
            let (lhs, rhs) = ($0.number(for: metric) ?? 0, $1.number(for: metric) ?? 0)
            return lhs != rhs ? lhs > rhs : $0.name < $1.name
        }
    }
}

struct TotalSpendProjectedSlice: Identifiable, Equatable {
    let slice: TotalSpendSlice
    let displayAmount: Double

    var id: String { slice.id }
}

struct TotalSpendProjection: Equatable {
    let metric: TotalSpendMetric
    let slices: [TotalSpendProjectedSlice]
    let centerValue: Double
    let isEstimated: Bool
    let topModel: TotalSpendModel?

    var isEmpty: Bool { slices.isEmpty }
}

struct TotalSpend: Equatable {
    let period: TotalSpendPeriod
    /// In the user's provider order; `projection(for:)` ranks them.
    let slices: [TotalSpendSlice]

    var isEmpty: Bool { slices.isEmpty }

    func projection(for metric: TotalSpendMetric) -> TotalSpendProjection {
        let included: [(slice: TotalSpendSlice, display: Double)] = slices.compactMap { slice in
            switch metric {
            case .cost: slice.amountUSD > 0 ? (slice, slice.amountUSD) : nil
            case .tokens: slice.tokenCount > 0 ? (slice, slice.tokenCount) : nil
            case .costPerMtok: slice.costPerMtok.map { (slice, $0) }
            }
        }
        // A stable sort keeps the user's provider order for ties.
        let ranked = included.enumerated().sorted { lhs, rhs in
            lhs.element.display != rhs.element.display ? lhs.element.display > rhs.element.display : lhs.offset < rhs.offset
        }.map(\.element)

        let usd = ranked.reduce(0) { $0 + $1.slice.amountUSD }
        let tokens = ranked.reduce(0) { $0 + $1.slice.tokenCount }
        let center: Double = switch metric {
        case .cost: usd
        case .tokens: tokens
        case .costPerMtok: tokens > 0 ? usd / tokens * 1_000_000 : 0
        }
        return TotalSpendProjection(
            metric: metric,
            slices: ranked.map { TotalSpendProjectedSlice(slice: $0.slice, displayAmount: $0.display) },
            centerValue: center,
            isEstimated: metric.usesDollarEstimateNote && ranked.contains { $0.slice.estimated },
            topModel: Self.topModel(in: ranked.map(\.slice), by: metric)
        )
    }

    /// The single biggest model across the included providers. Models with the same name from
    /// different providers count together.
    private static func topModel(in slices: [TotalSpendSlice], by metric: TotalSpendMetric) -> TotalSpendModel? {
        var merged: [String: TotalSpendModel] = [:]
        for model in slices.flatMap(\.models) {
            guard var existing = merged[model.name] else {
                merged[model.name] = model
                continue
            }
            existing.dollars = sum(existing.dollars, model.dollars)
            existing.tokens = sum(existing.tokens, model.tokens)
            merged[model.name] = existing
        }
        return merged.values.filter { $0.number(for: metric) != nil }.max {
            let (lhs, rhs) = ($0.number(for: metric) ?? 0, $1.number(for: metric) ?? 0)
            return lhs != rhs ? lhs < rhs : $0.name > $1.name
        }
    }

    private static func sum(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }
}
