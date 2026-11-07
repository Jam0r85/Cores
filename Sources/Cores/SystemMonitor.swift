import Foundation
import Observation
import os

/// Samples the CPU and sensors and keeps a minute of history for the charts.
///
/// While the panel is open it samples every second and reads everything. While it's closed
/// only the menu bar readout is visible, so it samples every 3 seconds at background priority,
/// skips the readings only the panel shows (fans, memory, SSD, battery), and doesn't touch the
/// panel's views at all. The menu bar is only redrawn when what it shows actually changes.
@MainActor @Observable
final class SystemMonitor {
    struct ClusterLoad: Identifiable {
        let id: Int
        let name: String
        let firstCPU: Int
        var cores: [Double]
        var average: Double { cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count) }
    }

    struct Sample: Identifiable {
        let time: Date
        let value: Double
        var id: Date { time }
    }

    /// Everything the panel draws.
    struct PanelData {
        var clusters: [ClusterLoad]
        var totalLoad: Double = 0
        var loadHistory: [Sample] = []
        var sensors = SensorSnapshot()
        var cpuTempHistory: [Sample] = []
        var gpuTempHistory: [Sample] = []
        var thermalState: ProcessInfo.ThermalState = .nominal
        var memory: MemoryReading?
    }

    /// Exactly what the menu bar readout draws, rounded the way it's displayed, so two
    /// readings that would look identical compare equal and don't trigger a redraw.
    struct MenuBarState: Equatable {
        /// The mini bars are 13 pt tall: 26 pixels on a Retina display.
        static let barSteps = 26
        var tierLevels: [Int]
        var load: Int
        var temp: Int?

        init(_ data: PanelData) {
            tierLevels = data.clusters.map { Int(($0.average * Double(Self.barSteps)).rounded()) }
            load = Int((data.totalLoad * 100).rounded())
            temp = data.sensors.cpu.map { Int($0.average.rounded()) }
        }

        var tierFractions: [Double] { tierLevels.map { Double($0) / Double(Self.barSteps) } }
    }

    static let historySeconds: TimeInterval = 60
    static let openInterval: TimeInterval = 1
    static let closedInterval: TimeInterval = 3

    let chipName: String
    let coreCount: Int
    /// What the panel shows. Only updated while it's open (and the moment it opens).
    private(set) var panel: PanelData
    /// What the menu bar shows. Only updated when the drawing would change.
    private(set) var menuBar: MenuBarState

    /// Counts dropdown opens, so the panel can reset to the stats each time.
    private(set) var panelOpens = 0
    /// Lets the updater know when the dropdown opens and closes.
    @ObservationIgnored var onPanelVisibilityChange: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private(set) var panelVisible = false
    @ObservationIgnored private(set) var interval: TimeInterval = 0
    @ObservationIgnored private var latest: PanelData // always current, whether or not the panel is open
    @ObservationIgnored private let sampler = Sampler()
    @ObservationIgnored private let autoTick: Bool
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let log = Logger(subsystem: "dev.local.Cores", category: "monitor")

    init(startTimer: Bool = true) {
        autoTick = startTimer
        chipName = sampler.cpu.chipName
        coreCount = sampler.cpu.clusters.reduce(0) { $0 + $1.cpus.count }
        let empty = PanelData(clusters: sampler.cpu.clusters.map {
            ClusterLoad(id: $0.id, name: $0.name, firstCPU: $0.cpus.lowerBound,
                        cores: Array(repeating: 0, count: $0.cpus.count))
        })
        latest = empty
        panel = empty
        menuBar = MenuBarState(empty)
        tickNow()      // full read up front so the panel's first open isn't missing anything
        panel = latest // and give the panel its full layout before it's ever shown, so it never changes height
        scheduleTimer()
        if startTimer { log.notice("Started, sampling every \(Int(Self.closedInterval))s until the panel opens") }
    }

    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        // .notice rather than .info: macOS only keeps info messages in memory, so they never reach `log show`.
        log.notice("Panel \(visible ? "opened" : "closed", privacy: .public), sampling every \(Int(visible ? Self.openInterval : Self.closedInterval))s")
        onPanelVisibilityChange?(visible)
        if visible {
            panelOpens += 1
            panel = latest // catch the panel up on everything collected while it was closed
            tick()         // and refresh straight away rather than showing a reading up to 3 s old
        }
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard autoTick else { return }
        interval = panelVisible ? Self.openInterval : Self.closedInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.1 // lets macOS batch wake-ups with other work
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Reads the hardware on a background queue, then updates on the main thread.
    /// With the panel closed the read runs at background priority, which keeps it on the
    /// low-power cores at a low clock speed. Load is measured between reads, so a read
    /// that starts a little late still reports the right average.
    func tick() {
        let sampler = sampler
        let detail = panelVisible
        sampler.queue.async(qos: detail ? .utility : .background, flags: .enforceQoS) { [weak self] in
            let reading = sampler.read(detail: detail)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(reading) }
            }
        }
    }

    /// Synchronous full read, for startup and the command-line tools.
    func tickNow() {
        apply(sampler.read(detail: true))
    }

    private func apply(_ reading: Sampler.Reading) {
        var data = latest
        if let loads = reading.loads {
            for index in data.clusters.indices {
                let range = sampler.cpu.clusters[index].cpus.clamped(to: 0..<loads.count)
                data.clusters[index].cores = Array(loads[range])
            }
            data.totalLoad = loads.reduce(0, +) / Double(max(loads.count, 1))
            Self.append(data.totalLoad * 100, at: reading.time, to: &data.loadHistory)
        }

        // Keep the last fan and HID readings when this sample skipped them.
        data.sensors.cpu = reading.cpu
        data.sensors.gpu = reading.gpu
        if let fans = reading.fans { data.sensors.fans = fans }
        if let hid = reading.hid {
            data.sensors.soc = hid.soc
            data.sensors.ssd = hid.ssd
            data.sensors.battery = hid.battery
        }
        if data.sensors.cpu == nil { data.sensors.cpu = data.sensors.soc } // no SMC: fall back to the SoC die sensors
        if let memory = reading.memory { data.memory = memory }

        if let cpu = data.sensors.cpu { Self.append(cpu.average, at: reading.time, to: &data.cpuTempHistory) }
        if let gpu = data.sensors.gpu { Self.append(gpu.average, at: reading.time, to: &data.gpuTempHistory) }
        data.thermalState = ProcessInfo.processInfo.thermalState
        latest = data

        if panelVisible || !autoTick { panel = data } // the command-line tools always want it
        let menuBar = MenuBarState(data)
        if menuBar != self.menuBar { self.menuBar = menuBar }
    }

    private static func append(_ value: Double, at time: Date, to history: inout [Sample]) {
        history.append(Sample(time: time, value: value))
        let cutoff = time.addingTimeInterval(-historySeconds - 1)
        if let firstKept = history.firstIndex(where: { $0.time >= cutoff }), firstKept > 0 {
            history.removeFirst(firstKept)
        }
    }
}

/// Owns the hardware readers. Only touched from `queue` (or synchronously before the timer starts).
private final class Sampler: @unchecked Sendable {
    struct Reading: Sendable {
        var time: Date
        var loads: [Double]?
        var cpu: TempReading?
        var gpu: TempReading?
        var fans: [FanReading]?
        var hid: (soc: TempReading?, ssd: TempReading?, battery: TempReading?)?
        var memory: MemoryReading?
    }

    let queue = DispatchQueue(label: "Cores.sampler") // priority is set per read, see SystemMonitor.tick()
    let cpu = CPUSampler()
    private let sensors = SensorSampler()
    private let memory = MemorySampler()
    private var lastHIDRead = Date.distantPast

    /// `detail` adds the readings only the open panel shows.
    func read(detail: Bool) -> Reading {
        let now = Date()
        let temps = sensors.sampleTemps()
        var reading = Reading(time: now, loads: cpu.sample(), cpu: temps.cpu, gpu: temps.gpu)
        if detail {
            reading.fans = sensors.sampleFans()
            reading.memory = memory.sample()
        }
        // SSD and battery change slowly: every 5 s while open.
        // Without SMC CPU sensors they stand in for CPU temperature, so then they're read every time.
        if sensors.needsHIDEveryTick || (detail && now.timeIntervalSince(lastHIDRead) >= 5) {
            reading.hid = sensors.sampleHID()
            lastHIDRead = now
        }
        return reading
    }
}
