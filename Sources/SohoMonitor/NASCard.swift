import SohoMonitorCore
import SwiftUI

/// The NAS card once a password is saved (operator layout, #27): header with the main volume's used share and free
/// space, then storage (one bar per volume, volume health, pool and disk health dot), CPU · RAM · disk activity on
/// one line, containers with a status dot each, and pills for the DSM update and the sections that could not be read.
struct NASCard: View {
    var config: SynologyConfig
    var state: RemoteState<NASSnapshot>
    var tlsFailure: TLSFailure?
    var trust: TLSTrustState?
    var now: Date

    private enum Compact {
        static let spacing: CGFloat = 7
        static let padding = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    }

    var body: some View {
        GlassCard(accent: CardColor.nas, spacing: Compact.spacing, padding: Compact.padding) {
            switch state {
            case .ok(let snapshot, _):
                NASDetails(snapshot: snapshot, host: config.host)
            case .stale(let snapshot, let since, let reason):
                NASDetails(snapshot: snapshot, host: config.host).opacity(0.5)
                NASStatusLine(
                    text: "Data from \(RelativeAge.string(from: since, now: now)): \(reason)",
                    level: .warning
                )
                .padding(.top, NASDetails.endsWithPills(snapshot) ? PillRow.textClearance : 0)
                // A changed pin with data still shown: the fingerprint to check, at once.
                if let presented = tlsFailure?.presented { FingerprintRow(fingerprint: presented) }
            case .loading:
                header(figure: "—")
                NASStatusLine(text: "Connecting to \(config.host)…", level: .normal)
            case .unreachable(let since, let reason):
                header(figure: "—")
                NASStatusLine(
                    text: "Unreachable: \(reason) (first failure \(RelativeAge.string(from: since, now: now)))",
                    level: .warning)
            case .failed(let message):
                header(figure: "—")
                // The fingerprint is in the row below (with its copy button), not twice.
                let text = if case .certificateMismatch = tlsFailure { "Pinned certificate changed" } else { message }
                NASStatusLine(text: text.capitalizedFirst, level: .critical)
                if let presented = tlsFailure?.presented { FingerprintRow(fingerprint: presented) }
            case .authFailed(let message):
                header(figure: "—")
                NASStatusLine(text: message.capitalizedFirst, level: .critical)
            case .needsSetup:
                header(figure: "—")
                NASStatusLine(text: "Needs setup: no password saved for \(config.user)", level: .normal)
            }
            if let warning = TLSWarning.text(policy: config.tls, trust: trust) {
                Label(warning, systemImage: "exclamationmark.shield")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CardColor.warning)
                    .lineLimit(2)
                    .padding(.top, pillsLast ? PillRow.textClearance : 0)
            }
        }
    }

    /// The card's last row so far is a pill row: what follows keeps clear of the glass.
    private var pillsLast: Bool {
        if case .ok(let snapshot, _) = state { return NASDetails.endsWithPills(snapshot) }
        return false
    }

    private func header(figure: String) -> some View {
        MetricHeader(
            symbol: NASDetails.symbol, title: "NAS", subtitle: config.host, figure: figure, tint: CardColor.nas,
            compact: true)
    }
}

/// The data of one cycle.
private struct NASDetails: View {
    static let symbol = "externaldrive.connected.to.line.below"

    var snapshot: NASSnapshot
    var host: String

    var body: some View {
        let storage = snapshot.storage.value
        let main = storage?.volumes.first
        let tint = CardColor.tint(main?.health.level ?? .normal, accent: CardColor.nas)
        MetricHeader(
            symbol: Self.symbol, title: "NAS", figure: PercentFormat.whole(main?.usedFraction), tint: tint,
            compact: true
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("NAS \(host)")
        .accessibilityValue(main.map { Self.spoken($0) } ?? "")
        // The free space right under the large figure, at the end of the identity line.
        HStack(spacing: 8) {
            identity
            Spacer(minLength: 0)
            if let main, let free = Self.freeText(main) { FigureCaption(text: free) }
        }
        if let storage {
            ForEach(Array(storage.volumes.enumerated()), id: \.offset) { _, volume in
                VolumeRow(volume: volume, showsName: storage.volumes.count > 1)
            }
            HardwareLine(storage: storage)
        }
        if let system = snapshot.system.value { LoadLine(system: system) }
        if let list = snapshot.containers.value, !list.containers.isEmpty || list.total > 0 {
            ContainerGrid(list: list)
        }
        let pills = Self.pills(snapshot)
        // Always under a row of text (containers, load or hardware line): kept clear of the glass edge.
        if !pills.isEmpty { PillRow(pills: pills).padding(.top, PillRow.textClearance) }
    }

    /// The details end with a pill row (DSM update or an unreadable section).
    static func endsWithPills(_ snapshot: NASSnapshot) -> Bool { !pills(snapshot).isEmpty }

    /// "DS416play · DSM 7.1.1 · 54 °C · up 77 d 8 h": model, version, system temperature (orange when DSM warns),
    /// uptime. The card's only temperature (the disks' are not shown).
    @ViewBuilder private var identity: some View {
        let system = snapshot.system.value
        let parts = [system?.model, system?.dsmVersion.map(NASFormat.shortVersion)].compactMap { $0 }
        let head = parts.isEmpty ? host : parts.joined(separator: " · ")
        let temperature = system?.temperature.map {
            Text(" · \($0) °C").foregroundStyle(
                system?.temperatureWarning == true ? AnyShapeStyle(CardColor.warning) : AnyShapeStyle(.secondary))
        }
        let uptime = system?.uptime.map { Text(" · up \(NASFormat.uptime($0))") }
        Text("\(Text(head))\(temperature ?? Text(""))\(uptime ?? Text(""))")
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(system?.dsmVersion ?? host)
    }

    /// "792.6 GB free" for a volume whose sizes DSM gave.
    static func freeText(_ volume: NASVolume) -> String? {
        volume.free.map { "\(ByteFormat.short(Int64(clamping: $0))) free" }
    }

    /// "90 % used, 792.6 GB free, almost full" for VoiceOver.
    private static func spoken(_ volume: NASVolume) -> String {
        [PercentFormat.whole(volume.usedFraction) + " used", freeText(volume), volume.statusText]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The DSM update badge, then one red pill per section that could not be read.
    static func pills(_ snapshot: NASSnapshot) -> [InfoPill] {
        var pills: [InfoPill] = []
        if let badge = snapshot.update.value?.badge {
            pills.append(
                InfoPill(text: "Update: \(badge)", tint: CardColor.nas, help: "DSM update available: \(badge)"))
        }
        let failures: [(String, String?)] = [
            ("Storage", snapshot.storage.unavailableReason), ("System", snapshot.system.unavailableReason),
            ("Containers", snapshot.containers.unavailableReason),
        ]
        for case (let name, let reason?) in failures {
            pills.append(InfoPill(text: "\(name): \(reason)", tint: CardColor.critical, help: "\(name): \(reason)"))
        }
        return pills
    }
}

/// One volume: name (when there are several), bar tinted by DSM's own health, used of total.
private struct VolumeRow: View {
    var volume: NASVolume
    var showsName: Bool

    var body: some View {
        let tint = CardColor.tint(volume.health.level, accent: CardColor.nas)
        HStack(spacing: 8) {
            if showsName {
                Text(volume.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).frame(
                    width: 64, alignment: .leading)
            }
            ThinBar(fraction: volume.usedFraction, tint: tint)
            if let used = volume.used, let total = volume.total {
                Text("\(ByteFormat.short(Int64(clamping: used))) of \(ByteFormat.short(Int64(clamping: total)))")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .help("\(volume.name): \(volume.health.label)\(volume.detail.map { " (\($0))" } ?? "")")
    }
}

/// Volume health, then the worst pool or disk as a dot (named when it is not healthy).
private struct HardwareLine: View {
    var storage: NASStorage

    var body: some View {
        let hardware = storage.hardware
        HStack(spacing: 10) {
            if let volume = storage.volumes.first {
                StatusDot(level: volume.health.level, text: "Volume \(volume.statusText.lowercasedUnlessName)")
            }
            StatusDot(
                level: hardware.health.level,
                text: hardware.subject.map { "\($0) \(hardware.health.label.lowercasedUnlessName)" }
                    ?? "\(Self.count(storage)) healthy")
            Spacer(minLength: 0)
        }
    }

    private static func count(_ storage: NASStorage) -> String {
        let disks = storage.disks.count
        let what = disks == 1 ? "1 disk" : "\(disks) disks"
        return storage.pools.isEmpty ? what : "Pool, \(what)"
    }
}

/// CPU · RAM · Disk activity on one line, each tinted by its level.
private struct LoadLine: View {
    var system: NASSystem

    var body: some View {
        HStack(spacing: 14) {
            figure("CPU", system.cpu, system.cpuLevel)
            figure("RAM", system.memory, system.memoryLevel)
            figure("Disk", system.diskActivity, system.diskActivityLevel)
                .help("Disk activity: how busy the NAS's disks were, all drives together")
            Spacer(minLength: 0)
        }
    }

    /// Plain when normal, orange or red otherwise: an accent colour would read as a warning on so small a figure.
    private func figure(_ name: String, _ value: Double?, _ level: MetricLevel) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(PercentFormat.whole(value))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(
                    level == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(CardColor.tint(level, accent: .primary)))
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Containers 6/6": then one compact chip per container (status dot and name), problems first.
private struct ContainerGrid: View {
    var list: NASContainerList

    private static let columns = [
        GridItem(.flexible(), spacing: 8, alignment: .leading), GridItem(.flexible(), spacing: 8, alignment: .leading),
        GridItem(.flexible(), alignment: .leading),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Containers").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(list.running)/\(list.total) running")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 3) {
                ForEach(Array(list.containers.enumerated()), id: \.offset) { _, container in
                    StatusDot(level: container.level, text: container.name, idle: Self.isIdle(container))
                        .help("\(container.name): \(container.state.label)\(container.image.map { " · \($0)" } ?? "")")
                        .accessibilityLabel("\(container.name), \(container.state.label)")
                }
            }
        }
    }

    /// Stopped as expected: a grey dot, not green.
    private static func isIdle(_ container: NASContainer) -> Bool {
        if case .stopped = container.state { return true }
        return false
    }
}

/// A coloured dot and a short text: green, orange or red by level; grey when idle.
private struct StatusDot: View {
    var level: MetricLevel
    var text: String
    var idle = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color.gradient).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
    }

    private var color: Color {
        switch level {
        case .normal: idle ? Color.secondary : Color.green
        case .warning: CardColor.warning
        case .critical: CardColor.critical
        }
    }
}

/// A state or error line under the header.
private struct NASStatusLine: View {
    var text: String
    var level: MetricLevel

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(
                level == .normal ? AnyShapeStyle(.secondary) : AnyShapeStyle(CardColor.tint(level, accent: .secondary))
            )
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .help(text)
    }
}

extension NASSection {
    var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

extension String {
    /// "Attention" → "attention"; a verbatim DSM string stays as it is.
    fileprivate var lowercasedUnlessName: String {
        ["Healthy", "Attention", "Degraded", "Crashed"].contains(self) ? lowercased() : self
    }
}

// MARK: - Previews (made-up values: never a real NAS's)

@MainActor
private enum NASPreview {
    static let config = SynologyConfig(host: "nas.example.test", user: "monitor")
    static let presented = CertificateFingerprint(sha256Of: Data("new".utf8))

    static func snapshot(pool: NASHealth = .normal, hot: Bool = false, problems: Bool = false) -> NASSnapshot {
        let containers = [
            NASContainer(name: "web", image: nil, state: problems ? .unhealthy : .running, expectedStopped: false),
            NASContainer(name: "db", image: nil, state: .running, expectedStopped: false),
            NASContainer(
                name: "backup", image: nil, state: .stopped(exitCode: problems ? 1 : 0), expectedStopped: !problems),
            NASContainer(name: "media", image: nil, state: .running, expectedStopped: false),
        ]
        let system = NASSystem(
            cpu: problems ? 0.93 : 0.12, memory: 0.41, diskActivity: 0.08, model: "DS-DEMO",
            dsmVersion: "DSM 7.2.2-72806 Update 3", temperature: hot ? 71 : 44, temperatureWarning: hot,
            uptime: 1_234_567)
        let volume = NASVolume(
            name: "volume1", total: 8_000_000_000_000, used: 5_200_000_000_000,
            health: pool == .normal ? .normal : .attention, detail: nil)
        let storage = NASStorage(
            volumes: [volume], pools: [NASPool(name: "SHR", health: pool)],
            disks: (1...4).map { NASDisk(name: "Drive \($0)", health: .normal, temperature: 35 + $0) })
        return NASSnapshot(
            system: .value(system), storage: .value(storage),
            update: .value(NASUpdate(available: problems, version: "DSM 7.3-80000")),
            containers: problems
                ? .unavailable("no permission for SYNO.Docker.Container")
                : .value(NASContainerList(containers: containers, total: containers.count)),
            trust: .trusted)
    }

    static func card(_ state: RemoteState<NASSnapshot>, tlsFailure: TLSFailure? = nil) -> some View {
        NASCard(config: config, state: state, tlsFailure: tlsFailure, trust: .trusted, now: .now)
            .frame(width: DiskCard.width)
    }
}

#Preview("NAS · healthy") { NASPreview.card(.ok(NASPreview.snapshot(), at: .now)).padding() }
#Preview("NAS · problems") {
    NASPreview.card(.ok(NASPreview.snapshot(pool: .degraded, hot: true, problems: true), at: .now)).padding()
}
#Preview("NAS · states") {
    VStack(spacing: 12) {
        NASPreview.card(.loading)
        NASPreview.card(.stale(NASPreview.snapshot(), since: .now.addingTimeInterval(-600), reason: "timed out"))
        NASPreview.card(.unreachable(since: .now.addingTimeInterval(-120), reason: "no network"))
        NASPreview.card(
            .failed(TLSFailure.certificateMismatch(presented: NASPreview.presented).message),
            tlsFailure: .certificateMismatch(presented: NASPreview.presented))
    }
    .padding()
}
