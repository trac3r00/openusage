import Foundation

// PERSONAL BUILD: Total Spend log scanning. Minimal stand-ins for the 0.7.16 environment helpers the
// ported scanners expect. Main no longer captures the login-shell environment, so overrides such as
// `CLAUDE_CONFIG_DIR` / `CODEX_HOME` resolve only when the app's own process environment carries them;
// otherwise the scanners use their default home-directory locations.

protocol EnvironmentReading: Sendable {
    func value(for name: String) -> String?
}

struct ProcessEnvironmentReader: EnvironmentReading {
    var processEnvironment: [String: String] = ProcessInfo.processInfo.environment

    func value(for name: String) -> String? {
        processEnvironment[name]?.nilIfEmpty
    }
}

func expandHome(_ path: String) -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" { return home }
    return home + String(path.dropFirst())
}

extension String {
    var trimmingTrailingSlashes: String {
        var copy = self
        while copy.hasSuffix("/") { copy.removeLast() }
        return copy
    }
}
