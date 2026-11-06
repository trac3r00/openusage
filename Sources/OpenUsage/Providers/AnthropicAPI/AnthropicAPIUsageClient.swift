import Foundation

/// The Admin API's Usage and Cost Analytics endpoints, and its API key list, for the organization an
/// Admin key belongs to.
struct AnthropicAPIUsageClient: Sendable {
    static let costURL = "https://api.anthropic.com/v1/organizations/analytics/cost"
    static let usageURL = "https://api.anthropic.com/v1/organizations/analytics/usage"
    static let apiKeysURL = "https://api.anthropic.com/v1/organizations/api_keys"
    static let rejectedKeyMessage = "Anthropic rejected this key. Use an Admin API key (sk-ant-admin…) from the Claude Console."
    static let betaHeader = "analytics-usage-cost-2026-08-24"
    static let apiVersion = "2026-10-21"
    /// Bounds the page loop should Anthropic ever repeat `next_page`.
    static let maxPages = 40
    /// Every row is split by these, so one read yields totals, models, Claude Code's part, and keys.
    static let dimensions = ["model", "product", "api_key_id"]

    enum Report: Sendable {
        case cost
        case usage

        var url: String { self == .cost ? AnthropicAPIUsageClient.costURL : AnthropicAPIUsageClient.usageURL }
    }

    enum Bucket: String, Sendable {
        case hour = "1h"
        case day = "1d"
    }

    var http: any HTTPClient

    /// One report's rows over `start..<end`, split into `bucket`-wide UTC buckets, oldest first.
    func rows(_ report: Report, apiKey: String, from start: Date, to end: Date, bucket: Bucket) async throws -> [Data] {
        let query = [
            URLQueryItem(name: "starting_at", value: Self.timestamp(start)),
            URLQueryItem(name: "ending_at", value: Self.timestamp(end)),
            URLQueryItem(name: "time_bucket_width", value: bucket.rawValue),
            URLQueryItem(name: "order_by", value: "time"),
            URLQueryItem(name: "order", value: "asc")
        ] + Self.dimensions.map { URLQueryItem(name: "group_by[]", value: $0) }
        return try await pages(report.url, apiKey: apiKey, query: query, beta: true, cursor: .nextPage)
    }

    /// Every API key's ID and name. A key that can't list keys still reads usage, so this returns nil
    /// instead of failing the card.
    func apiKeyNames(apiKey: String) async -> [String: String]? {
        do {
            let pages = try await pages(Self.apiKeysURL, apiKey: apiKey, query: [URLQueryItem(name: "limit", value: "100")],
                                        beta: false, cursor: .afterID)
            return try AnthropicAPIUsageMapper.keyNames(pages)
        } catch {
            AppLog.warn(LogTag.plugin("anthropic-api"), "could not list API key names: \(error.localizedDescription)")
            return nil
        }
    }

    private enum Cursor {
        /// `has_more` + `next_page`, passed back as `page`.
        case nextPage
        /// `has_more` + `last_id`, passed back as `after_id`.
        case afterID
    }

    private func pages(_ urlString: String, apiKey: String, query: [URLQueryItem], beta: Bool, cursor: Cursor) async throws -> [Data] {
        var bodies: [Data] = []
        var next: String?
        for _ in 0..<Self.maxPages {
            guard var components = URLComponents(string: urlString) else { throw ProviderError.invalidResponse }
            let paging = next.map { [URLQueryItem(name: cursor == .nextPage ? "page" : "after_id", value: $0)] } ?? []
            components.queryItems = query + paging
            guard let url = components.url else { throw ProviderError.invalidResponse }
            var headers = [
                "x-api-key": apiKey,
                "anthropic-version": Self.apiVersion,
                "Accept": "application/json",
                "User-Agent": "OpenUsage"
            ]
            if beta { headers["anthropic-beta"] = Self.betaHeader }
            let response = try await LoginHTTP.get(url, using: http, headers: headers)
            if ProviderError.isAuthFailure(response) { throw ProviderError.keyRejected(Self.rejectedKeyMessage) }
            guard (200..<300).contains(response.statusCode) else { throw ProviderError.failed(response) }
            bodies.append(response.body)
            let following = switch cursor {
            case .nextPage: try AnthropicAPIUsageMapper.nextPage(response.body)
            case .afterID: try AnthropicAPIUsageMapper.lastID(response.body)
            }
            guard let following else { return bodies }
            next = following
        }
        throw ProviderError.invalidResponse
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: .gmt, formatOptions: .withInternetDateTime)
    }
}
