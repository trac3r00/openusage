import SwiftUI

/// PERSONAL BUILD: the Total Spend card above both dashboard tabs. Hidden while the setting is off or
/// no provider has dollars or tokens for any period.
struct TotalSpendSection: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore

    @AppStorage(TotalSpendSetting.enabledKey) private var isEnabled = true
    @AppStorage(TotalSpendSetting.periodKey) private var periodRawValue = TotalSpendPeriod.today.rawValue
    @AppStorage(TotalSpendSetting.metricKey) private var metricRawValue = TotalSpendMetric.cost.rawValue

    private var period: TotalSpendPeriod { TotalSpendPeriod(rawValue: periodRawValue) ?? .today }
    private var metric: TotalSpendMetric { TotalSpendMetric(rawValue: metricRawValue) ?? .cost }

    var body: some View {
        let totals = isEnabled ? self.totals(now: Date()) : [:]
        Group {
            if let total = totals[period], totals.values.contains(where: { !$0.isEmpty }) {
                VStack(alignment: .leading, spacing: DashboardGrid.headerGap) {
                    header
                    card(total.projection(for: metric))
                }
                .padding(.bottom, DashboardGrid.sectionSpacing)
            }
        }
        // The app's refresh cycle scans at launch and on every refresh; only turning the card back on
        // needs a scan of its own, so opening the panel never starts one.
        .onChange(of: isEnabled) { _, enabled in
            if enabled { container.localSpend.refresh(accountKinds: Set(container.accounts.accounts.map(\.kind))) }
        }
    }

    private func totals(now: Date) -> [TotalSpendPeriod: TotalSpend] {
        let order = Dictionary(layout.registry.providers.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let accounts = container.accounts.accounts
            .sorted { (order[$0.cardID] ?? .max) < (order[$1.cardID] ?? .max) }
            .map { TotalSpendAccount(id: $0.cardID, kind: $0.kind, label: $0.label, snapshot: dataStore.snapshots[$0.cardID]) }
        let scans = container.localSpend.scans
        return Dictionary(uniqueKeysWithValues: TotalSpendPeriod.allCases.map {
            ($0, TotalSpendAggregator.total(for: $0, accounts: accounts, localScans: scans, now: now))
        })
    }

    private var header: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(TotalSpendMetric.allCases) { option in
                    Button {
                        metricRawValue = option.rawValue
                    } label: {
                        if option == metric { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(metric.title)
                        .font(DashboardGrid.headerFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Total Spend Metric")
            .accessibilityValue(metric.title)
            Spacer(minLength: DashboardGrid.columnGap)
        }
        .padding(.horizontal, DashboardGrid.cardPadding)
        .frame(height: DashboardGrid.headerHeight)
    }

    private func card(_ projection: TotalSpendProjection) -> some View {
        VStack(spacing: Theme.Spacing.xl) {
            CapsuleSegments(
                options: TotalSpendPeriod.allCases.map { ($0, $0.label) },
                selection: Binding(get: { period }, set: { periodRawValue = $0.rawValue }),
                height: 24,
                fontSize: 11
            )
            if projection.isEmpty {
                Text(metric.emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            } else {
                HStack(spacing: 18) {
                    TotalSpendRing(projection: projection)
                    VStack(alignment: .leading, spacing: 7) {
                        let all = projection.slices.map(\.slice)
                        ForEach(projection.slices) {
                            TotalSpendLegendRow(slice: $0, color: TotalSpendPalette.color(for: $0.slice, among: all), metric: metric)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let top = projection.topModel { topModelLine(top) }
            }
        }
        .padding(.horizontal, DashboardGrid.cardPadding)
        .padding(.vertical, Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
        .cardSurface()
        .animation(Motion.spring, value: periodRawValue)
        .animation(Motion.spring, value: metricRawValue)
    }

    private func topModelLine(_ model: TotalSpendModel) -> some View {
        let value = (metric == .costPerMtok ? model.costPerMtok : model.number(for: metric))
            .map { TotalSpendFormat.short($0, metric: metric) }
        return HStack(spacing: 4) {
            Text("Top Model:")
                .foregroundStyle(.secondary)
            Text(model.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let value {
                Text("· \(value)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TotalSpendLegendRow: View {
    let slice: TotalSpendProjectedSlice
    let color: Color
    let metric: TotalSpendMetric

    @State private var hover = HoverPopoverState()
    @Environment(\.reduceAnimations) private var reduceAnimations

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(slice.slice.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(TotalSpendFormat.short(slice.displayAmount, metric: metric))
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.system(size: 12))
        .contentShape(Rectangle())
        .hoverHighlight(hover.overInline || hover.isPresented)
        .onContinuousHover { phase in
            if case .active = phase { hover.inlineHover(true) } else { hover.inlineHover(false) }
        }
        .onDisappear { hover.dismiss() }
        .motionAwareHoverPopover(
            isPresented: Binding(get: { hover.isPresented }, set: { if !$0 { hover.dismiss() } }),
            reduceAnimations: reduceAnimations
        ) {
            TotalSpendModelsDetail(slice: slice.slice, metric: metric) { hover.detailHover($0) }
        }
    }
}

private struct TotalSpendModelsDetail: View {
    let slice: TotalSpendSlice
    let metric: TotalSpendMetric
    let onHoverChange: (Bool) -> Void

    private static let shownModels = 5

    var body: some View {
        let models = Array(slice.rankedModels(by: metric).prefix(Self.shownModels))
        let spenders = Array(slice.rankedSpenders(by: metric).prefix(Self.shownModels))
        VStack(alignment: .leading, spacing: 8) {
            Text("\(slice.title) Top Models")
                .font(.system(size: 13, weight: .semibold))
            if models.isEmpty {
                Text("No models reported")
                    .foregroundStyle(.secondary)
            }
            rows(models)
            if !spenders.isEmpty {
                Text("Top API Keys")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 4)
                rows(spenders)
            }
            if slice.estimated, metric.usesDollarEstimateNote {
                Text(TotalSpendMetric.localEstimateNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .onContinuousHover { phase in
            if case .active = phase { onHoverChange(true) } else { onHoverChange(false) }
        }
    }

    private func rows(_ models: [TotalSpendModel]) -> some View {
        ForEach(models, id: \.name) { model in
            HStack(spacing: 8) {
                Text(model.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(value(model))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func value(_ model: TotalSpendModel) -> String {
        let number = metric == .costPerMtok ? model.costPerMtok : model.number(for: metric)
        return number.map { TotalSpendFormat.short($0, metric: metric) } ?? "\u{2014}"
    }
}
