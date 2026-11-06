import AppKit
import SwiftUI

/// The donut: one identity-keyed arc per provider, so a period or metric switch morphs each
/// provider's own arc instead of smearing colors between positions.
struct TotalSpendRing: View {
    let projection: TotalSpendProjection

    static let diameter: CGFloat = 104
    /// Even a tiny share keeps a visible sliver; the legend and center keep the true amounts.
    private static let minimumSliceShare = 0.025

    var body: some View {
        ZStack {
            ForEach(arcs) { arc in
                RingSectorShape(startFraction: arc.start, endFraction: arc.end)
                    .fill(arc.color)
            }
            center
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(projection.metric.title) \(TotalSpendFormat.exact(projection.centerValue, metric: projection.metric))")
    }

    private struct Arc: Identifiable {
        let id: String
        let color: Color
        let start: Double
        let end: Double
    }

    private var arcs: [Arc] {
        let total = projection.slices.reduce(0) { $0 + $1.displayAmount }
        guard total > 0 else { return [] }
        let floored = projection.slices.map { max($0.displayAmount / total, Self.minimumSliceShare) }
        let sum = floored.reduce(0, +)
        let all = projection.slices.map(\.slice)
        var cursor = 0.0
        return zip(projection.slices, floored).map { slice, share in
            let width = share / sum
            defer { cursor += width }
            return Arc(id: slice.id, color: TotalSpendPalette.color(for: slice.slice, among: all),
                       start: cursor, end: cursor + width)
        }
    }

    private var center: some View {
        let label = TotalSpendFormat.ringCenter(projection.centerValue, metric: projection.metric)
        return VStack(spacing: 1) {
            Text(label.primary)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.unit)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(width: Self.diameter * 0.6, height: Self.diameter * 0.6)
        .contentShape(Circle())
        .hoverTooltip(centerTooltip)
    }

    private var centerTooltip: String {
        let exact = TotalSpendFormat.exact(projection.centerValue, metric: projection.metric)
        return projection.isEstimated ? "\(exact) · \(TotalSpendMetric.localEstimateNote)" : exact
    }
}

/// One donut sector with hairline gaps and rounded corners, its ring fractions animatable.
/// Fractions run clockwise from 12 o'clock, 0...1 around the ring.
struct RingSectorShape: Shape {
    var startFraction: Double
    var endFraction: Double
    var innerRadiusRatio: CGFloat = 0.618
    var gapWidth: CGFloat = 1.6
    var cornerRadius: CGFloat = 3

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(startFraction, endFraction) }
        set {
            startFraction = newValue.first
            endFraction = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let outer = Double(min(rect.width, rect.height) / 2)
        let inner = outer * Double(innerRadiusRatio)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let top = -Double.pi / 2
        let halfGap = Double(gapWidth) / outer / 2
        let a0 = top + startFraction * 2 * .pi + halfGap
        let a1 = top + endFraction * 2 * .pi - halfGap
        let width = a1 - a0
        guard width > 0.001 else { return Path() }

        // Corners can't exceed half the band, and a narrow slice shrinks them further so the two
        // corner arcs of one edge never cross (s bounds the corner's angular footprint).
        let s = sin(min(width / 2, .pi / 2))
        var corner = min(Double(cornerRadius), (outer - inner) / 2)
        corner = min(corner, outer * s / (1 + s))
        if s < 1 { corner = min(corner, inner * s / (1 - s)) }

        var path = Path()
        guard corner >= 0.25 else {
            path.addArc(center: center, radius: outer, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
            path.addArc(center: center, radius: inner, startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
            path.closeSubpath()
            return path
        }

        // Each corner circle sits `corner` inside the rim it rounds; beta is the angular offset that
        // makes it tangent to both the rim and the radial edge.
        let betaOuter = asin(min(1, corner / (outer - corner)))
        let betaInner = asin(min(1, corner / (inner + corner)))
        func polar(_ radius: Double, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        func around(_ point: CGPoint, _ radius: Double, _ angle: Double) -> CGPoint {
            CGPoint(x: point.x + radius * cos(angle), y: point.y + radius * sin(angle))
        }

        path.addArc(center: center, radius: outer,
                    startAngle: .radians(a0 + betaOuter), endAngle: .radians(a1 - betaOuter), clockwise: false)
        let trailingOuter = polar(outer - corner, a1 - betaOuter)
        path.addArc(center: trailingOuter, radius: corner,
                    startAngle: .radians(a1 - betaOuter), endAngle: .radians(a1 + .pi / 2), clockwise: false)
        let trailingInner = polar(inner + corner, a1 - betaInner)
        path.addLine(to: around(trailingInner, corner, a1 + .pi / 2))
        path.addArc(center: trailingInner, radius: corner,
                    startAngle: .radians(a1 + .pi / 2), endAngle: .radians(a1 - betaInner + .pi), clockwise: false)
        path.addArc(center: center, radius: inner,
                    startAngle: .radians(a1 - betaInner), endAngle: .radians(a0 + betaInner), clockwise: true)
        let leadingInner = polar(inner + corner, a0 + betaInner)
        path.addArc(center: leadingInner, radius: corner,
                    startAngle: .radians(a0 + betaInner + .pi), endAngle: .radians(a0 + 3 * .pi / 2), clockwise: false)
        let leadingOuter = polar(outer - corner, a0 + betaOuter)
        path.addLine(to: around(leadingOuter, corner, a0 - .pi / 2))
        path.addArc(center: leadingOuter, radius: corner,
                    startAngle: .radians(a0 + 3 * .pi / 2), endAngle: .radians(a0 + betaOuter), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// Fixed per-provider brand colors, keyed by provider kind so a provider keeps its color across
/// periods, re-sorts and launches. Black brands get adaptive grays so they read in both appearances.
enum TotalSpendPalette {
    private static let byKind: [String: Color] = [
        "claude": hex(0xDE7356),
        "codex": hex(0x10A37F),
        "cursor": dynamic(light: 0x13120A, dark: 0xF5F5F7),
        "grok": dynamic(light: 0x8E8E93, dark: 0x98989D),
        "opencode": dynamic(light: 0x6E6E73, dark: 0xAEAEB2),
        "openrouter": hex(0x6467F2),
        "anthropic-api": hex(0xB5523B),
        "antigravity": hex(0x4285F4),
        "copilot": hex(0xA855F7),
        "devin": hex(0x0294DE),
        "muse": hex(0x0866FF),
        "ollama": dynamic(light: 0x48484A, dark: 0xC7C7CC),
        "zai": dynamic(light: 0x2D2D2D, dark: 0xD1D1D6)
    ]

    private static let fallback: [Color] = [hex(0x34C759), hex(0x5856D6), hex(0xFF2D55), hex(0xA2845E)]

    /// A provider's brand color; its second and later accounts get lighter shades of it, ordered by
    /// account so each keeps its shade when the ranking changes.
    static func color(for slice: TotalSpendSlice, among slices: [TotalSpendSlice]) -> Color {
        let siblings = slices.filter { $0.kind == slice.kind }.map(\.id).sorted()
        let shade = siblings.firstIndex(of: slice.id) ?? 0
        let opacity = [1.0, 0.68, 0.46, 0.3][min(shade, 3)]
        return color(for: slice.kind.rawValue).opacity(opacity)
    }

    static func color(for kindID: String) -> Color {
        if let brand = byKind[kindID] { return brand }
        let stableHash = kindID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return fallback[stableHash % fallback.count]
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
    }
}

enum TotalSpendFormat {
    private static let locale = Locale(identifier: "en_US")

    /// The short form for rows and the legend: `$12.40`, `12.4M`, `$1.37/MTok`.
    static func short(_ value: Double, metric: TotalSpendMetric) -> String {
        switch metric {
        case .cost: MetricFormatter.number(value, kind: .dollars, style: .row)
        case .tokens: MetricFormatter.number(value, kind: .count, style: .row)
        case .costPerMtok: MetricFormatter.number(value, kind: .dollars, style: .row) + "/MTok"
        }
    }

    static func exact(_ value: Double, metric: TotalSpendMetric) -> String {
        switch metric {
        case .cost: value.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale))
        case .tokens: value.formatted(.number.precision(.fractionLength(0)).locale(locale)) + " tokens"
        case .costPerMtok: value.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(locale)) + " per million tokens"
        }
    }

    static func ringCenter(_ value: Double, metric: TotalSpendMetric) -> (primary: String, unit: String) {
        switch metric {
        case .cost:
            return (MetricFormatter.number(value, kind: .dollars, style: .tray), "dollars")
        case .costPerMtok:
            return (MetricFormatter.number(value, kind: .dollars, style: .row), "MTok")
        case .tokens:
            let scales: [(Double, String)] = [(1_000_000_000, "billion"), (1_000_000, "million"), (1_000, "thousand")]
            for (scale, unit) in scales where abs(value) >= scale {
                return ((value / scale).formatted(.number.precision(.fractionLength(0...1)).locale(locale)), unit)
            }
            return (value.formatted(.number.precision(.fractionLength(0)).locale(locale)), "tokens")
        }
    }
}
