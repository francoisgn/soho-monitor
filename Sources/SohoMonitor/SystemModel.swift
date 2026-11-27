import Observation
import SohoMonitorCore

/// Live CPU and memory state for the cards. Sampling runs in the shared `SamplingEngine` only while the panel is on
/// screen (`setDemand`); this model mirrors each metric's status and history on the main actor.
@MainActor @Observable
final class SystemModel {
    static let historyCapacity = 120

    private(set) var cpu: MetricStatus<CPUUsage> = .loading
    private(set) var cpuHistory: [Double] = []
    private(set) var memory: MetricStatus<MemoryReading> = .loading
    private(set) var memoryHistory: [Double] = []
    /// Chip name and core counts: read once, they do not change.
    let cpuInfo = CPUInfo.read()

    @ObservationIgnored private let engine = SamplingEngine(clock: ContinuousClock())
    /// Registered for the app's whole life: event driven, it costs nothing while the panel is hidden.
    @ObservationIgnored private let pressure = MemoryPressureMonitor()
    @ObservationIgnored private var tokens: [DemandToken] = []
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var reconciling = false
    @ObservationIgnored private var started = false
    /// Set once the collectors are registered: a demand before that waits for it.
    @ObservationIgnored private var registered = false

    static let cpuID: MetricID = "cpu"
    static let memoryID: MetricID = "memory"

    /// Registers the collectors and mirrors their channels. Sampling starts only with `setDemand(true)`.
    func start() {
        guard !started else { return }
        started = true
        let pressure = pressure
        Task {
            let cpuChannel = await engine.register(
                Self.cpuID, collector: CPUCollector(), capacity: Self.historyCapacity)
            let memoryChannel = await engine.register(
                Self.memoryID, collector: MemoryCollector(pressure: { pressure.level }),
                capacity: Self.historyCapacity)
            mirror(cpuChannel) { model, status, history in
                model.cpu = status
                model.cpuHistory = history.map(\.total)
            }
            mirror(memoryChannel) { model, status, history in
                model.memory = status
                model.memoryHistory = history.map(\.usedFraction)
            }
            registered = true
            reconcile()
        }
    }

    /// True while something on screen shows the system cards.
    func setDemand(_ on: Bool) {
        wanted = on
        reconcile()
    }

    private func mirror<Value: Sendable>(
        _ channel: MetricChannel<Value>,
        apply: @escaping @MainActor (SystemModel, MetricStatus<Value>, [Value]) -> Void
    ) {
        Task { [weak self] in
            for await status in channel.updates() {
                guard let self else { return }
                apply(self, status, channel.history)
            }
        }
    }

    /// Brings the held tokens in line with `wanted`, one engine call at a time, whatever the order of the toggles.
    private func reconcile() {
        guard registered, !reconciling else { return }
        reconciling = true
        Task {
            while tokens.isEmpty == wanted {
                if wanted {
                    tokens = [await engine.acquire(Self.cpuID), await engine.acquire(Self.memoryID)]
                } else {
                    let held = tokens
                    tokens = []
                    for token in held { await engine.release(token) }
                }
            }
            reconciling = false
        }
    }
}
