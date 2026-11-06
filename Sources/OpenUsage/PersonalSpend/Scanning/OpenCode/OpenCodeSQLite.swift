import Foundation

protocol SQLiteAccessing: Sendable {
    func queryValue(path: String, sql: String) throws -> String?
}

/// Read-only `sqlite3` CLI reads of OpenCode's local databases (ported from 0.7.16).
struct SQLiteCLIAccessor: SQLiteAccessing {
    var processRunner: ProcessRunning = SystemProcessRunner()

    func queryValue(path: String, sql: String) throws -> String? {
        guard try databaseExists(path) else { return nil }
        var result = try run(path: path, sql: sql, queryOnly: false)
        // A WAL database whose -shm file can't be opened under -readonly fails to open; retry with a
        // connection that may set up the sidecars but is refused any write by `PRAGMA query_only`.
        if !result.succeeded {
            result = try run(path: path, sql: sql, queryOnly: true)
        }
        guard result.succeeded else { throw SQLiteError.queryFailed(result.stderr) }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func run(path: String, sql: String, queryOnly: Bool) throws -> ProcessResult {
        var arguments = ["-batch", "-noheader"]
        arguments += queryOnly ? ["-cmd", "PRAGMA query_only = ON"] : ["-readonly"]
        arguments += ["-cmd", ".timeout 1000", expandHome(path), sql]
        return try processRunner.run(
            executable: "/usr/bin/sqlite3",
            arguments: arguments,
            environment: [:],
            timeout: 5
        )
    }

    private func databaseExists(_ path: String) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: expandHome(path))
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }
}

enum SQLiteError: Error, LocalizedError, Equatable {
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .queryFailed(let message):
            return message.isEmpty ? "SQLite query failed." : message
        }
    }
}

enum OpenCodeUsageError: Error, LocalizedError, Equatable {
    case databaseUnreadable

    var errorDescription: String? {
        "Couldn't read OpenCode's local database. Quit OpenCode and refresh, or check the data directory's permissions."
    }
}

/// Which assistant-message tables a database holds: OpenCode 1's `message`, OpenCode 2's
/// `session_message`, or both. Naming a missing table fails statement preparation, so the scanner asks first.
struct OpenCodeMessageTables: OptionSet, Sendable {
    let rawValue: Int

    static let v1 = OpenCodeMessageTables(rawValue: 1)
    static let v2 = OpenCodeMessageTables(rawValue: 2)
    static let all: OpenCodeMessageTables = [.v1, .v2]

    static let probeSQL =
        "SELECT group_concat(name) FROM sqlite_master WHERE type='table' AND name IN ('message','session_message');"

    /// The message tables a database holds, or `nil` when it holds neither (the caller skips it).
    static func present(in path: String, sqlite: SQLiteAccessing) throws -> OpenCodeMessageTables? {
        let names = try sqlite.queryValue(path: path, sql: probeSQL)?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        var tables: OpenCodeMessageTables = []
        if names.contains("message") { tables.insert(.v1) }
        if names.contains("session_message") { tables.insert(.v2) }
        return tables.isEmpty ? nil : tables
    }
}
