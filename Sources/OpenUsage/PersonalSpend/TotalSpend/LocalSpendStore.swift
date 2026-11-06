import Foundation
import Observation

/// This Mac's local-log usage for the Total Spend card. Scans run off the main actor, reuse the
/// scanners' incremental parse caches, and start with the app's normal refresh cycle.
@MainActor
@Observable
final class LocalSpendStore {
    private(set) var scans: [ProviderKind: LogUsageScan] = [:]

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Account kinds that changed while a scan ran; they get a scan of their own once it ends.
    @ObservationIgnored private var pendingKinds: Set<ProviderKind>?
    @ObservationIgnored private let scanner = LocalSpendScanner()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readsLocalLogs: Bool

    /// A test host never reads this Mac's real logs.
    init(defaults: UserDefaults = .standard, readsLocalLogs: Bool = !AppNotifications.isRunningUnderTests) {
        self.defaults = defaults
        self.readsLocalLogs = readsLocalLogs
    }

    func refresh(accountKinds: Set<ProviderKind>) {
        guard scanTask == nil else {
            pendingKinds = accountKinds
            return
        }
        let kinds = accountKinds.intersection(TotalSpendAggregator.localLogKinds)
        guard readsLocalLogs, TotalSpendSetting.isEnabled(in: defaults), !kinds.isEmpty else {
            if !scans.isEmpty { scans = [:] }
            return
        }
        let scanner = scanner
        scanTask = Task { [weak self] in
            let result = await scanner.scan(kinds, now: Date())
            guard let self else { return }
            self.scanTask = nil
            // The accounts changed while this scan ran: scan again for the new set. The same set
            // asked for again keeps this result rather than reading the logs twice.
            if let pending = self.pendingKinds {
                self.pendingKinds = nil
                if pending.intersection(TotalSpendAggregator.localLogKinds) != kinds {
                    self.refresh(accountKinds: pending)
                    return
                }
            }
            guard TotalSpendSetting.isEnabled(in: self.defaults) else { return }
            self.scans = result
        }
    }
}

private struct LocalSpendScanner: Sendable {
    private let openCode = OpenCodeUsageScanner()

    func scan(_ kinds: Set<ProviderKind>, now: Date) async -> [ProviderKind: LogUsageScan] {
        let pricing = await ModelPricingStore.shared.current()
        async let claude = kinds.contains(.claude) ? ClaudeLogUsageScanner().scan(now: now, pricing: pricing) : nil
        async let codex = kinds.contains(.codex) ? CodexLogUsageScanner().scan(now: now, pricing: pricing) : nil
        async let grok = kinds.contains(.grok) ? GrokLogUsageScanner().scan(now: now, pricing: pricing) : nil
        async let openCode = kinds.contains(.opencodeGo) ? scanOpenCode(now: now) : nil

        var scans: [ProviderKind: LogUsageScan] = [:]
        scans[.claude] = await claude
        scans[.codex] = await codex
        scans[.grok] = await grok
        scans[.opencodeGo] = await openCode
        return scans
    }

    private func scanOpenCode(now: Date) async -> LogUsageScan? {
        do {
            return try await openCode.scan(now: now)?.logScan
        } catch {
            AppLog.warn(LogTag.plugin("opencode"), "Total Spend skipped OpenCode: \(error.localizedDescription)")
            return nil
        }
    }
}
