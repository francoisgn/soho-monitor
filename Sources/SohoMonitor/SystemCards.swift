import SohoMonitorCore
import SwiftUI

/// Metrics of the compact CPU and memory cards: shorter than the other cards, same content.
private enum Compact {
    static let spacing: CGFloat = 6
    static let padding = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    static let sparklineHeight: CGFloat = 22
}

/// The CPU card: total usage, chip name, core pills, thin bar and history.
struct CPUCard: View {
    var status: MetricStatus<CPUUsage>
    var history: [Double]
    var info: CPUInfo

    var body: some View {
        let usage: CPUUsage? = if case .value(let usage) = status { usage } else { nil }
        let tint = CardColor.tint(usage?.level ?? .normal, accent: CardColor.cpu)
        GlassCard(accent: CardColor.cpu, spacing: Compact.spacing, padding: Compact.padding) {
            MetricHeader(
                symbol: "cpu", title: "CPU", subtitle: info.name ?? " ", figure: PercentFormat.whole(usage?.total),
                tint: tint, compact: true
            )
            .help(usage.map(Self.detail) ?? "")
            ThinBar(fraction: usage?.total, tint: tint)
            // No value now: no old history either, next to a dash.
            Sparkline(
                values: usage == nil ? [] : history, capacity: SystemModel.historyCapacity, tint: tint,
                height: Compact.sparklineHeight)
            PillRow(pills: StatusPill.pills(for: status) + info.pills.map { InfoPill(text: $0) })
        }
    }

    private static func detail(_ usage: CPUUsage) -> String {
        "User \(PercentFormat.whole(usage.user)) · System \(PercentFormat.whole(usage.system))"
    }
}

/// The memory card: used share, used / total, pressure and swap pills, thin bar and history.
struct MemoryCard: View {
    var status: MetricStatus<MemoryReading>
    var history: [Double]

    var body: some View {
        let reading: MemoryReading? = if case .value(let reading) = status { reading } else { nil }
        let tint = CardColor.tint(reading?.level ?? .normal, accent: CardColor.memory)
        GlassCard(accent: CardColor.memory, spacing: Compact.spacing, padding: Compact.padding) {
            MetricHeader(
                symbol: "memorychip", title: "Memory", subtitle: reading?.usedOfTotal ?? " ",
                figure: PercentFormat.whole(reading?.usedFraction), tint: tint, compact: true
            )
            .help(reading?.breakdown ?? "")
            ThinBar(fraction: reading?.usedFraction, tint: tint)
            Sparkline(
                values: reading == nil ? [] : history, capacity: SystemModel.historyCapacity, tint: tint,
                height: Compact.sparklineHeight)
            PillRow(pills: StatusPill.pills(for: status) + Self.pills(reading))
        }
    }

    private static func pills(_ reading: MemoryReading?) -> [InfoPill] {
        guard let reading else { return [] }
        var pills: [InfoPill] = []
        if let pressure = reading.pressure {
            // The short label keeps the pressure and swap pills on one line; hover and VoiceOver get the full name.
            let full = "Memory \(pressure.label.lowercased())"
            pills.append(
                InfoPill(
                    text: pressure.shortLabel, tint: CardColor.tint(reading.level, accent: CardColor.memory),
                    help: full, spoken: full))
        }
        if let swap = reading.swapText {
            pills.append(InfoPill(text: swap, help: reading.swap.map { "Swap file: \(MemoryFormat.short($0.total))" }))
        }
        return pills
    }
}

/// "Sampling…" while loading; after a failure, the reason itself in a red pill (truncated, whole text on hover);
/// nothing once there is a value.
enum StatusPill {
    static func pills<Value>(for status: MetricStatus<Value>) -> [InfoPill] {
        switch status {
        case .loading: [InfoPill(text: "Sampling…")]
        case .value: []
        case .unavailable(let reason):
            [InfoPill(text: reason, tint: CardColor.critical, help: "Unavailable: \(reason)")]
        }
    }
}

/// CPU and memory side by side, as on the desktop panel.
struct SystemCards: View {
    let model: SystemModel

    var body: some View {
        // Same height for both cards, whatever their pills.
        HStack(alignment: .top, spacing: 10) {
            CPUCard(status: model.cpu, history: model.cpuHistory, info: model.cpuInfo)
                .frame(maxHeight: .infinity, alignment: .top)
            MemoryCard(status: model.memory, history: model.memoryHistory)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Previews (states of the design system: normal, warning, critical, unavailable, loading)

private enum PreviewData {
    static let info = CPUInfo(
        name: "Apple M4", physicalCores: 10, logicalCores: 10, levels: [(4, "Performance"), (6, "Efficiency")])

    static func wave(_ base: Double, _ swing: Double) -> [Double] {
        // Split into typed steps: as one expression it exceeds the type checker's time limit on the CI runner.
        (0..<90).map { (index: Int) -> Double in
            let x = Double(index)
            let slow: Double = swing * sin(x / 6)
            let fast: Double = swing / 3 * sin(x / 1.7)
            return base + slow + fast
        }
    }

    static func cpu(_ total: Double) -> MetricStatus<CPUUsage> {
        .value(CPUUsage(total: total, user: total * 0.7, system: total * 0.3, perCore: []))
    }

    static func memory(usedPages: UInt64, pressure: MemoryPressure?) -> MetricStatus<MemoryReading> {
        let pages = VMPageCounts(
            free: 0, active: usedPages, inactive: 0, speculative: 0, wired: 80_000, compressed: 40_000, purgeable: 0,
            external: 120_000)
        return .value(
            MemoryReading(
                pages: pages, pageSize: 16_384, total: 17_179_869_184,
                swap: SwapUsage(total: 2_147_483_648, used: 805_306_368), pressure: pressure))
    }
}

#Preview("States") {
    VStack(spacing: 10) {
        HStack(alignment: .top, spacing: 10) {
            CPUCard(status: PreviewData.cpu(0.23), history: PreviewData.wave(0.25, 0.12), info: PreviewData.info)
            MemoryCard(
                status: PreviewData.memory(usedPages: 400_000, pressure: .normal), history: PreviewData.wave(0.5, 0.05))
        }
        HStack(alignment: .top, spacing: 10) {
            CPUCard(status: PreviewData.cpu(0.78), history: PreviewData.wave(0.7, 0.15), info: PreviewData.info)
            MemoryCard(
                status: PreviewData.memory(usedPages: 800_000, pressure: .warning), history: PreviewData.wave(0.8, 0.05)
            )
        }
        HStack(alignment: .top, spacing: 10) {
            CPUCard(status: PreviewData.cpu(0.96), history: PreviewData.wave(0.9, 0.08), info: PreviewData.info)
            MemoryCard(
                status: PreviewData.memory(usedPages: 900_000, pressure: .critical),
                history: PreviewData.wave(0.9, 0.04))
        }
        HStack(alignment: .top, spacing: 10) {
            CPUCard(
                status: .unavailable("host_processor_info: (os/kern) failure"), history: [], info: PreviewData.info)
            MemoryCard(status: .loading, history: [])
        }
    }
    .frame(width: 420)
    .padding(24)
}
