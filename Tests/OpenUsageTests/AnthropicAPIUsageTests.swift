import XCTest
@testable import OpenUsage

/// Usage and Cost Analytics rows shaped as Anthropic's reference documents them.
enum AnthropicAPIFixtures {
    static func costRow(_ start: String, cents: String, model: String?, product: String? = nil, key: String? = nil) -> String {
        """
        {"starting_at":"\(start)","ending_at":"\(start)","group":{"model":\(json(model)),"product":\(json(product)),"api_key_id":\(json(key))},
        "cost":{"amount":"\(cents)","list_amount":"\(cents)","currency":"USD","requests":1}}
        """
    }

    static func usageRow(_ start: String, input: Int, output: Int, model: String, product: String? = nil, key: String? = nil) -> String {
        """
        {"starting_at":"\(start)","ending_at":"\(start)","group":{"model":"\(model)","product":\(json(product)),"api_key_id":\(json(key))},
        "usage":{"uncached_input_tokens":\(input),"cache_creation":{"ephemeral_1h_input_tokens":10,"ephemeral_5m_input_tokens":20},
        "cache_read_input_tokens":30,"output_tokens":\(output),"total_tokens":0,"requests":1}}
        """
    }

    static func page(_ rows: [String], next: String? = nil) -> String {
        #"{"data":[\#(rows.joined(separator: ","))],"has_more":\#(next != nil),"next_page":\#(json(next))}"#
    }

    static let keys = #"{"data":[{"id":"apikey_prod","name":"Production"}],"has_more":false,"first_id":"apikey_prod","last_id":"apikey_prod"}"#
    static let empty = page([])
    static let unauthorized = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#

    static func query(_ request: HTTPRequest, _ name: String) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private static func json(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }
}

@MainActor
final class AnthropicAPIUsageTests: XCTestCase {
    private typealias F = AnthropicAPIFixtures
    private static let now = ISO8601DateFormatter().date(from: "2026-10-29T11:00:00Z")!

    private var utc: Calendar { .utc }

    private var pacific: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func runtime(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) throws
        -> (AccountProviderRuntime, RoutingHTTPClient) {
        let account = Account(kind: .anthropicAPI, label: "Org")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("sk-ant-admin01-key"), for: account.id)
        let http = RoutingHTTPClient(handler: handler)
        return (AccountProviderRuntime(account: account, vault: vault, http: http, now: { Self.now }), http)
    }

    private func read(cost: [String], usage: [String], placement: AnthropicAPIUsageMapper.Placement = .hourly,
                      names: [String: String]? = ["apikey_prod": "Production"], calendar: Calendar = .utc) throws -> AnthropicAPIRead {
        var read = AnthropicAPIRead()
        try AnthropicAPIUsageMapper.add(costPages: [Data(F.page(cost).utf8)], usagePages: [Data(F.page(usage).utf8)],
                                        placement: placement, keyNames: names, calendar: calendar, to: &read)
        return read
    }

    private func day(_ value: String, in calendar: Calendar) throws -> Date {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        return try XCTUnwrap(calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])))
    }

    func testModelsKeysClaudeCodeAndAWebSearchCostSumIntoTheDay() throws {
        let read = try read(
            cost: [F.costRow("2026-10-27T09:00:00Z", cents: "1234.5", model: "claude-sonnet-5", key: "apikey_prod"),
                   F.costRow("2026-10-27T10:00:00Z", cents: "250", model: "claude-opus-5-5", product: "claude_code"),
                   F.costRow("2026-10-27T11:00:00Z", cents: "100", model: nil)],
            usage: [F.usageRow("2026-10-27T09:00:00Z", input: 1000, output: 300, model: "claude-sonnet-5", key: "apikey_prod"),
                    F.usageRow("2026-10-27T10:00:00Z", input: 200, output: 100, model: "claude-opus-5-5", product: "claude_code")]
        )
        let today = try day("2026-10-27", in: utc)
        let all = try XCTUnwrap(read.days[today])

        XCTAssertEqual(try XCTUnwrap(all.totals[.spend]), 15.845, accuracy: 0.0001)
        XCTAssertEqual(all.totals[.tokens], 1000 + 300 + 60 + 200 + 100 + 60)
        XCTAssertEqual(all.totals[.cacheWriteTokens], 60)
        XCTAssertEqual(Set(try XCTUnwrap(all.byModel).keys), ["claude-sonnet-5", "claude-opus-5-5"])
        XCTAssertEqual(read.claudeCodeDays[today]?.totals[.spend], 2.5)
        XCTAssertEqual(read.claudeCodeDays[today]?.totals[.tokens], 360)
        let keys = try XCTUnwrap(read.keyDays[today]?.byModel)
        XCTAssertEqual(try XCTUnwrap(keys["Production"]?[.spend]), 12.345, accuracy: 0.0001)
        XCTAssertEqual(keys["Claude Code"]?[.spend], 2.5)
        XCTAssertEqual(keys["No API Key"]?[.spend], 1)
    }

    func testAnHourlyBucketLandsOnTheLocalDayHoldingItsStart() throws {
        let read = try read(cost: [F.costRow("2026-10-28T03:00:00Z", cents: "100", model: "m")], usage: [], calendar: pacific)

        XCTAssertEqual(Array(read.days.keys), [try day("2026-10-27", in: pacific)])
    }

    func testADailyBucketLandsOnTheLocalDayWithItsUTCDate() throws {
        let read = try read(cost: [F.costRow("2026-10-28T00:00:00Z", cents: "100", model: "m")], usage: [],
                            placement: .dailyByUTCDate, calendar: pacific)

        XCTAssertEqual(Array(read.days.keys), [try day("2026-10-28", in: pacific)])
    }

    func testAKeyWithoutANameShowsTheEndOfItsID() throws {
        let read = try read(cost: [F.costRow("2026-10-27T09:00:00Z", cents: "100", model: "m", key: "apikey_01abcdef")],
                            usage: [], names: nil)

        XCTAssertEqual(read.keyDays.values.first?.byModel?.keys.first, "Key abcdef")
    }

    func testTodayAndYesterdayReadHourlyAndOlderDaysReadDailyWithTheBetaHeaders() async throws {
        let (runtime, http) = try runtime { request in
            switch (request.url.path(), F.query(request, "time_bucket_width"), F.query(request, "page")) {
            case ("/v1/organizations/analytics/cost", "1h", nil):
                .json(F.page([F.costRow("2026-10-29T09:00:00Z", cents: "300", model: "claude-sonnet-5")], next: "page_2"))
            case ("/v1/organizations/analytics/cost", "1h", "page_2"):
                .json(F.page([F.costRow("2026-10-29T10:00:00Z", cents: "125", model: "claude-opus-5-5")]))
            case ("/v1/organizations/analytics/cost", "1d", nil):
                .json(F.page([F.costRow("2026-10-20T00:00:00Z", cents: "1000", model: "claude-sonnet-5")]))
            case ("/v1/organizations/analytics/usage", _, nil): .json(F.empty)
            case ("/v1/organizations/api_keys", _, _): .json(F.keys)
            default: .json("", status: 404)
            }
        }

        let usage = try await runtime.refreshAnthropicAPI(.apiKey("sk-ant-admin01-key"))
        let history = try XCTUnwrap(usage.history)

        XCTAssertEqual(history.totals(over: .today)?[.spend], 4.25)
        XCTAssertEqual(history.totals(over: .lastDays(30))?[.spend], 14.25)
        XCTAssertNotNil(usage.spendHistories[ReportedSpendBreakdowns.claudeCode])
        XCTAssertNotNil(usage.spendHistories[ReportedSpendBreakdowns.apiKeys])
        let hourly = try XCTUnwrap(http.requests.first {
            $0.url.path() == "/v1/organizations/analytics/cost" && F.query($0, "time_bucket_width") == "1h"
        })
        XCTAssertEqual(hourly.headers["x-api-key"], "sk-ant-admin01-key")
        XCTAssertEqual(hourly.headers["anthropic-beta"], AnthropicAPIUsageClient.betaHeader)
        XCTAssertNil(hourly.headers["Authorization"])
        XCTAssertEqual(F.query(hourly, "starting_at"), "2026-10-28T00:00:00Z")
        XCTAssertEqual(F.query(hourly, "ending_at"), "2026-10-29T11:00:00Z")
        let groups = URLComponents(url: hourly.url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == "group_by[]" }.compactMap(\.value)
        XCTAssertEqual(groups, AnthropicAPIUsageClient.dimensions)
        let daily = try XCTUnwrap(http.requests.first {
            $0.url.path() == "/v1/organizations/analytics/cost" && F.query($0, "time_bucket_width") == "1d"
        })
        XCTAssertEqual(F.query(daily, "starting_at"), "2026-09-30T00:00:00Z")
        XCTAssertEqual(F.query(daily, "ending_at"), "2026-10-28T00:00:00Z")
    }

    func testAKeyListFailureStillReadsUsage() async throws {
        let (runtime, _) = try runtime { request in
            request.url.path() == "/v1/organizations/api_keys" ? .json("", status: 500) : .json(F.empty)
        }

        let usage = try await runtime.refreshAnthropicAPI(.apiKey("sk-ant-admin01-key"))

        XCTAssertEqual(usage.history?.totals(over: .lastDays(30))?[.spend], 0)
    }

    func testARejectedKeyAsksForAnAdminKey() async throws {
        let (runtime, _) = try runtime { _ in .json(F.unauthorized, status: 401) }

        do {
            _ = try await runtime.refreshAnthropicAPI(.apiKey("sk-ant-api03-key"))
            XCTFail("a rejected key must fail the read")
        } catch {
            XCTAssertEqual(error as? ProviderError, .keyRejected(AnthropicAPIUsageClient.rejectedKeyMessage))
        }
    }

    func testAMalformedCostRowFailsTheRead() {
        XCTAssertThrowsError(try read(cost: [F.costRow("2026-10-27T09:00:00Z", cents: "n/a", model: "m")], usage: []))
    }
}
