// PERSONAL BUILD: Total Spend test fixtures ported from 0.7.16.
import XCTest
import os
@testable import OpenUsage

/// The shipped pricing resources (supplement + LiteLLM/models.dev snapshots) as a ready-to-use
/// `ModelPricing` — loaded once, entirely offline (no store, no network, no disk cache). Tests that
/// price real model names use this the way production code uses `ModelPricingStore.current()`.
enum TestPricing {
    static let bundled: ModelPricing = {
        func resource(_ name: String) -> Data {
            guard let url = Bundle.openUsageResources.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url) else {
                fatalError("bundled resource \(name).json missing")
            }
            return data
        }
        return ModelPricing(
            supplement: try! PricingSupplement.decode(from: resource("pricing_supplement")),
            primary: try! PricingCatalogCodecs.catalogFromCompact(resource("pricing_litellm_snapshot")),
            secondary: try! PricingCatalogCodecs.catalogFromCompact(resource("pricing_models_dev_snapshot"))
        )
    }()
}

/// Builds throwaway Claude config dirs (`<tmp>/…/projects/<file>.jsonl`) and canned usage lines for
/// `ClaudeLogUsageScanner` tests, plus a scanner wired to read only the fixture (never the real
/// `~/.claude` of the machine running the tests).
enum ClaudeLogFixture {
    /// A temp Claude config dir whose `projects/` contains `files` (relative path → JSONL content).
    static func makeHome(files: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-claude-\(UUID().uuidString)", isDirectory: true)
        try write(files: files, toProjectsOf: root)
        return root
    }

    /// A temp *user home* fixture for Cowork tests. `claudeFiles` land under
    /// `<home>/.claude/projects/`; each `coworkSessions` entry (session dir relative to
    /// `local-agent-mode-sessions`, e.g. `group/sub/local_x` → files) lands under that session's
    /// `.claude/projects/` inside `<home>/Library/Application Support/Claude/local-agent-mode-sessions`.
    static func makeUserHome(
        claudeFiles: [String: String] = [:],
        coworkSessions: [String: [String: String]] = [:]
    ) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-claude-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if !claudeFiles.isEmpty {
            try write(files: claudeFiles, toProjectsOf: home.appendingPathComponent(".claude"))
        }
        let sessionsBase = home
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        for (sessionDir, files) in coworkSessions {
            try write(
                files: files,
                toProjectsOf: sessionsBase.appendingPathComponent(sessionDir).appendingPathComponent(".claude")
            )
        }
        return home
    }

    private static func write(files: [String: String], toProjectsOf configDir: URL) throws {
        let projects = configDir.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        for (relativePath, content) in files {
            let url = projects.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A scanner pinned to the fixture home (or to nothing when `home` is nil → "No data").
    static func scanner(home: URL?) -> ClaudeLogUsageScanner {
        ClaudeLogUsageScanner(
            environment: FakeEnvironment(home.map { ["CLAUDE_CONFIG_DIR": $0.path] } ?? [:]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-claude-home") },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
        )
    }

    /// A scanner whose *user home* is the fixture from `makeUserHome` — exercises the default
    /// `~/.claude` root plus Cowork session discovery, with no `CLAUDE_CONFIG_DIR` override.
    static func scanner(userHome: URL) -> ClaudeLogUsageScanner {
        ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]),
            homeDirectory: { userHome },
            incrementalScanner: IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>()
        )
    }

    /// One Claude Code usage line in the modern log shape. Pass `nil` to omit a field.
    static func usageLine(
        timestamp: String,
        model: String? = "claude-sonnet-4-5-20250929",
        input: Int = 0,
        output: Int = 0,
        cacheWrite: Int? = nil,
        cacheRead: Int? = nil,
        costUSD: Double? = nil,
        messageID: String? = "msg_1",
        requestID: String? = "req_1",
        isSidechain: Bool? = nil,
        speed: String? = nil,
        version: String? = "1.0.24"
    ) -> String {
        var usage: [String: Any] = ["input_tokens": input, "output_tokens": output]
        if let cacheWrite { usage["cache_creation_input_tokens"] = cacheWrite }
        if let cacheRead { usage["cache_read_input_tokens"] = cacheRead }
        if let speed { usage["speed"] = speed }
        var message: [String: Any] = ["usage": usage]
        if let model { message["model"] = model }
        if let messageID { message["id"] = messageID }
        var object: [String: Any] = ["timestamp": timestamp, "sessionId": "session-1", "message": message]
        if let version { object["version"] = version }
        if let requestID { object["requestId"] = requestID }
        if let costUSD { object["costUSD"] = costUSD }
        if let isSidechain { object["isSidechain"] = isSidechain }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Builds throwaway Codex homes (`<tmp>/…/sessions/<file>.jsonl`) and canned rollout lines for
/// `CodexLogUsageScanner` tests, plus a scanner pinned to the fixture (never the real `~/.codex`).
enum CodexLogFixture {
    /// A temp Codex home whose `sessions/` (or another top-level dir) contains `files`
    /// (relative path → JSONL content).
    static func makeHome(files: [String: String] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true
        )
        for (relativePath, content) in files {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// A scanner pinned to the fixture home (or to nothing when `home` is nil → "No data").
    static func scanner(home: URL?) -> CodexLogUsageScanner {
        CodexLogUsageScanner(
            environment: FakeEnvironment(home.map { ["CODEX_HOME": $0.path] } ?? [:]),
            homeDirectory: { FileManager.default.temporaryDirectory.appendingPathComponent("openusage-no-codex-home") },
            incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>()
        )
    }

    /// A `turn_context` line carrying the session's active model.
    static func turnContext(timestamp: String, model: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "turn_context",
            "payload": ["model": model]
        ])
    }

    /// An `event_msg`/`token_count` line. Pass `last` for the turn delta and/or `totals` for the
    /// cumulative counter; either may be omitted like in real rollouts.
    static func tokenCount(
        timestamp: String,
        last: [String: Int]? = nil,
        totals: [String: Int]? = nil,
        model: String? = nil
    ) -> String {
        var info: [String: Any] = [:]
        if let last { info["last_token_usage"] = last }
        if let totals { info["total_token_usage"] = totals }
        if let model { info["model"] = model }
        return jsonLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": ["type": "token_count", "info": info]
        ])
    }

    /// Token-count dictionary in the rollout shape.
    static func usage(input: Int, cached: Int = 0, output: Int, reasoning: Int = 0) -> [String: Int] {
        [
            "input_tokens": input,
            "cached_input_tokens": cached,
            "output_tokens": output,
            "reasoning_output_tokens": reasoning,
            "total_tokens": input + output
        ]
    }

    /// An `event_msg`/`thread_settings_applied` line carrying the session's service tier, the way
    /// Codex CLI ≥ July 2026 records tier changes.
    static func threadSettingsApplied(timestamp: String, serviceTier: String?, model: String = "gpt-5.2") -> String {
        var threadSettings: [String: Any] = ["model": model]
        if let serviceTier {
            threadSettings["service_tier"] = serviceTier
        }
        return jsonLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "thread_settings_applied",
                "thread_settings": threadSettings
            ]
        ])
    }

    /// A `session_meta` line marking the file as a `thread_spawn` subagent session.
    static func subagentSessionMeta(timestamp: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "session_meta",
            "payload": ["id": "subagent-abc", "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent-xyz"]]]]
        ])
    }

    /// A `session_meta` line marking the file as a fork (`forked_from_id`, no subagent source).
    static func forkSessionMeta(timestamp: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "session_meta",
            "payload": ["id": "fork-abc", "forked_from_id": "parent-xyz"]
        ])
    }

    /// A root session's `session_meta` line (no parent, nothing replayed).
    static func rootSessionMeta(timestamp: String) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "session_meta",
            "payload": ["id": "root-abc", "source": "vscode"]
        ])
    }

    /// An `event_msg`/`task_started` line. `startedAt` is the turn's start as epoch seconds — a
    /// replayed parent turn keeps its original (older) value; a live turn is at/after the child
    /// session's creation.
    static func taskStarted(timestamp: String, startedAt: Int) -> String {
        jsonLine([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": ["type": "task_started", "turn_id": "turn-1", "started_at": startedAt]
        ])
    }

    private static func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Shared test doubles used across provider and store tests.
struct FakeEnvironment: EnvironmentReading {
    var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func value(for name: String) -> String? {
        values[name]
    }
}
