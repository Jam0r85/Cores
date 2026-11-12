import Foundation
import IOKit.ps
import notify
import Observation
import os

/// Samples the hardware and keeps a minute of history for each card's chart.
///
/// While the panel is open it samples every second and reads everything. While it's closed
/// only the menu bar readout is visible, so it samples every 3 seconds at background priority,
/// skips the slow readings only the panel shows (SSD and battery temperatures), and doesn't touch
/// the panel's views at all. The quick ones (memory, GPU, disk, fans) are still read so the charts
/// already cover the last minute when the panel opens. The menu bar is only redrawn when what it
/// shows actually changes. The battery isn't polled while closed: macOS says when it changes.
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
        var sensors = SensorSnapshot()
        var gpu: GPUReading?
        var memory: MemoryReading?
        var disk: DiskReading?
        var battery: BatteryReading?

        // The last minute of each card's main reading.
        var loadHistory: [Sample] = []    // percent
        var gpuHistory: [Sample] = []     // percent
        var memoryHistory: [Sample] = []  // percent of physical memory in use
        var diskHistory: [Sample] = []    // bytes per second, read + written
        var batteryHistory: [Sample] = [] // percent charge
        var fanHistory: [Sample] = []     // average rpm
    }

    /// Which readings the menu bar shows, chosen in Settings and saved between launches.
    /// At least one is always on, so the menu bar item can't disappear.
    struct MenuBarItems: Equatable {
        var usage = true       // the core bars and total load
        var temperature = true // CPU temperature
        var battery = false    // charge and whether it's charging; laptops only

        var count: Int { [usage, temperature, battery].filter { $0 }.count }
        var isValid: Bool { count > 0 }

        private static let usageKey = "menuBarShowsUsage"
        private static let temperatureKey = "menuBarShowsTemperature"
        private static let batteryKey = "menuBarShowsBattery"

        /// Battery is left off on a Mac without one (say, settings carried over from a laptop).
        static func load(hasBattery: Bool) -> MenuBarItems {
            let defaults = UserDefaults.standard
            defaults.register(defaults: [usageKey: true, temperatureKey: true, batteryKey: false])
            let items = MenuBarItems(usage: defaults.bool(forKey: usageKey),
                                     temperature: defaults.bool(forKey: temperatureKey),
                                     battery: hasBattery && defaults.bool(forKey: batteryKey))
            return items.isValid ? items : MenuBarItems()
        }

        func save() {
            UserDefaults.standard.set(usage, forKey: Self.usageKey)
            UserDefaults.standard.set(temperature, forKey: Self.temperatureKey)
            UserDefaults.standard.set(battery, forKey: Self.batteryKey)
        }
    }

    /// Exactly what the menu bar readout draws, rounded the way it's displayed, so two
    /// readings that would look identical compare equal and don't trigger a redraw.
    /// Readings the menu bar isn't showing are left out for the same reason (the core bars only
    /// show alongside both numbers).
    struct MenuBarState: Equatable {
        /// The mini bars are 13 pt tall: 26 pixels on a Retina display.
        static let barSteps = 26
        var items: MenuBarItems
        var tierLevels: [Int]
        var load: Int
        var temp: Int?
        var batteryCharge: Int?
        var batteryState: BatteryReading.State?

        init(_ data: PanelData, items: MenuBarItems) {
            self.items = items
            tierLevels = items.usage && items.temperature ? data.clusters.map { Int(($0.average * Double(Self.barSteps)).rounded()) } : []
            load = items.usage ? Int((data.totalLoad * 100).rounded()) : 0
            temp = items.temperature ? data.sensors.cpu.map { Int($0.average.rounded()) } : nil
            batteryCharge = items.battery ? data.battery?.charge : nil
            batteryState = items.battery ? data.battery?.state : nil
        }

        var tierFractions: [Double] { tierLevels.map { Double($0) / Double(Self.barSteps) } }
    }

    static let historySeconds: TimeInterval = 60
    static let openInterval: TimeInterval = 1
    static let closedInterval: TimeInterval = 3

    let chipName: String
    let coreCount: Int
    let gpuCoreCount: Int?
    let gpuMemoryLimit: UInt64?
    let hasBattery: Bool
    /// What the panel shows. Only updated while it's open (and the moment it opens).
    private(set) var panel: PanelData
    /// What the menu bar shows. Only updated when the drawing would change.
    private(set) var menuBar: MenuBarState
    /// Which readings the menu bar shows. Change it with `setMenuBarItems(_:)`.
    private(set) var menuBarItems: MenuBarItems

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
        gpuCoreCount = sampler.gpu.coreCount
        gpuMemoryLimit = sampler.gpu.memoryLimit
        hasBattery = sampler.battery.hasBattery
        let empty = PanelData(clusters: sampler.cpu.clusters.map {
            ClusterLoad(id: $0.id, name: $0.name, firstCPU: $0.cpus.lowerBound,
                        cores: Array(repeating: 0, count: $0.cpus.count))
        })
        latest = empty
        panel = empty
        let items = MenuBarItems.load(hasBattery: hasBattery)
        menuBarItems = items
        menuBar = MenuBarState(empty, items: items)
        tickNow()      // full read up front so the panel's first open isn't missing anything
        panel = latest // and give the panel its full layout before it's ever shown, so it never changes height
        scheduleTimer()
        if startTimer && hasBattery { watchBattery() }
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

    /// Saves the choice and redraws the menu bar straight away. Turning everything off is ignored.
    func setMenuBarItems(_ items: MenuBarItems) {
        guard items.isValid, items != menuBarItems else { return }
        menuBarItems = items
        items.save()
        updateMenuBar()
    }

    private func updateMenuBar() {
        let menuBar = MenuBarState(latest, items: menuBarItems)
        if menuBar != self.menuBar { self.menuBar = menuBar }
    }

    /// macOS posts a notification whenever the battery's charge, time remaining or power source
    /// changes, so plugging in shows up straight away without polling the battery.
    private func watchBattery() {
        var token: Int32 = 0
        notify_register_dispatch(kIOPSNotifyPowerSource, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readBattery() }
        }
    }

    private func readBattery() {
        let sampler = sampler
        sampler.queue.async(qos: .utility) { [weak self] in
            let battery = sampler.battery.sample()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyBattery(battery) }
            }
        }
    }

    private func applyBattery(_ battery: BatteryReading?) {
        guard let battery else { return }
        latest.battery = battery
        if panelVisible { panel.battery = battery }
        updateMenuBar()
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
        data.gpu = reading.gpuStats
        data.memory = reading.memory
        data.disk = reading.disk
        if let battery = reading.battery { data.battery = battery }

        let time = reading.time
        if let utilization = data.gpu?.utilization { Self.append(utilization * 100, at: time, to: &data.gpuHistory) }
        if let memory = data.memory, memory.total > 0 {
            Self.append(Double(memory.used) / Double(memory.total) * 100, at: time, to: &data.memoryHistory)
        }
        if let read = data.disk?.readRate, let write = data.disk?.writeRate { Self.append(read + write, at: time, to: &data.diskHistory) }
        if let battery = data.battery { Self.append(Double(battery.charge), at: time, to: &data.batteryHistory) }
        if !data.sensors.fans.isEmpty {
            Self.append(data.sensors.fans.map(\.rpm).reduce(0, +) / Double(data.sensors.fans.count), at: time, to: &data.fanHistory)
        }
        latest = data

        if panelVisible || !autoTick { panel = data } // the command-line tools always want it
        updateMenuBar()
    }

    private static func append(_ value: Double, at time: Date, to history: inout [Sample]) {
        history.append(Sample(time: time, value: value))
        // The last minute plus the one reading before it, so the chart always knows the reading
        // in effect at its left edge, however far apart the samples are.
        let cutoff = time.addingTimeInterval(-historySeconds)
        if let firstInWindow = history.firstIndex(where: { $0.time >= cutoff }), firstInWindow > 1 {
            history.removeFirst(firstInWindow - 1)
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
        var gpuStats: GPUReading?
        var memory: MemoryReading?
        var disk: DiskReading?
        var battery: BatteryReading?
    }

    let queue = DispatchQueue(label: "Cores.sampler") // priority is set per read, see SystemMonitor.tick()
    let cpu = CPUSampler()
    let battery = BatterySampler()
    let gpu = GPUSampler()
    private let sensors = SensorSampler()
    private let memory = MemorySampler()
    private let disk = DiskSampler()
    private var lastHIDRead = Date.distantPast
    private var lastBatteryRead = Date.distantPast

    /// `detail` adds the slower readings only the open panel shows.
    func read(detail: Bool) -> Reading {
        let now = Date()
        let temps = sensors.sampleTemps()
        var reading = Reading(time: now, loads: cpu.sample(), cpu: temps.cpu, gpu: temps.gpu)
        // Under a millisecond together, and they keep the panel's charts full while it's closed.
        reading.fans = sensors.sampleFans()
        reading.gpuStats = gpu.sample()
        reading.memory = memory.sample()
        reading.disk = disk.sample()
        // SSD and battery change slowly: every 5 s while open.
        // Without SMC CPU sensors they stand in for CPU temperature, so then they're read every time.
        if sensors.needsHIDEveryTick || (detail && now.timeIntervalSince(lastHIDRead) >= 5) {
            reading.hid = sensors.sampleHID()
            lastHIDRead = now
        }
        // While closed the battery is read only when macOS says it changed (SystemMonitor.watchBattery);
        // while open it's also read every 5 s as a fallback.
        if detail && battery.hasBattery && now.timeIntervalSince(lastBatteryRead) >= 5 {
            reading.battery = battery.sample()
            lastBatteryRead = now
        }
        return reading
    }
}
