import AppKit
import SwiftUI

/// Command-line helpers: `--dump` prints live readings, `--snapshot <dir>` renders the panel
/// to PNGs, `--render-icon <file>` draws the app icon.
@MainActor
enum Tools {
    static func dump() {
        let monitor = SystemMonitor(startTimer: false)
        Thread.sleep(forTimeInterval: 1)
        let clock = ContinuousClock()
        let elapsed = clock.measure { monitor.tickNow() }

        print("\(monitor.chipName) · \(monitor.coreCount) cores · sample took \(elapsed)")
        for cluster in monitor.panel.clusters {
            let cores = cluster.cores.map { String(format: "%3.0f", $0 * 100) }.joined(separator: " ")
            print("  \(cluster.name) (CPU \(cluster.firstCPU + 1)–\(cluster.firstCPU + cluster.cores.count)): avg \(Int(cluster.average * 100))%  [\(cores)]")
        }
        print("  Total load: \(Int(monitor.panel.totalLoad * 100))%")
        let s = monitor.panel.sensors
        for (name, reading) in [("CPU", s.cpu), ("GPU", s.gpu), ("SSD", s.ssd), ("Battery", s.battery)] {
            print("  \(name): " + (reading.map { String(format: "%.1f° avg, %.1f° peak", $0.average, $0.peak) } ?? "n/a"))
        }
        for fan in s.fans {
            print("  Fan \(fan.id + 1): \(Int(fan.rpm)) rpm" + (fan.maxRPM.map { " (max \(Int($0)))" } ?? ""))
        }
        let panel = monitor.panel
        if let memory = panel.memory {
            print("  Memory: \(Format.gigabytes(memory.used)) of \(Format.wholeGigabytes(memory.total)) used (app \(Format.gigabytes(memory.app)), wired \(Format.gigabytes(memory.wired)), compressed \(Format.gigabytes(memory.compressed))), pressure \(memory.pressure.map { "\($0)" } ?? "?")")
        }
        if let gpu = panel.gpu {
            print("  GPU: \(gpu.utilization.map { Format.percent($0) + "%" } ?? "?") busy, \(Format.gigabytes(gpu.memoryInUse)) in use, \(Format.gigabytes(gpu.memoryAllocated)) allocated, max \(monitor.gpuMemoryLimit.map(Format.gigabytes) ?? "?")")
        }
        if let disk = panel.disk {
            print("  Disk: \(disk.free.map { Format.diskSize($0).joined(separator: " ") } ?? "?") free of \(disk.total.map { Format.diskSize($0).joined(separator: " ") } ?? "?"), reading \(Format.rate(disk.readRate)), writing \(Format.rate(disk.writeRate))")
        }
        if let battery = panel.battery {
            print("  Battery charge: \(battery.charge)%, \(Format.batteryStatus(battery))" + (battery.cycles.map { ", \($0) cycles" } ?? "")
                  + (battery.power.map { String(format: ", %.1f W", $0) } ?? ""))
        }
        print("  Thermal state: \(ProcessInfo.processInfo.thermalState.rawValue)")

        let sensors = SensorSampler()
        let cpu = CPUSampler()
        let battery = BatterySampler()
        let gpu = GPUSampler()
        let memory = MemorySampler()
        let disk = DiskSampler()
        _ = cpu.sample()
        _ = disk.sample()
        print("  Timing: CPU \(clock.measure { _ = cpu.sample() }), CPU+GPU temps \(clock.measure { _ = sensors.sampleTemps() }), fans \(clock.measure { _ = sensors.sampleFans() }), HID \(clock.measure { _ = sensors.sampleHID() }), battery \(clock.measure { _ = battery.sample() })")
        print("  Timing: GPU \(clock.measure { _ = gpu.sample() }), memory \(clock.measure { _ = memory.sample() }), disk \(clock.measure { _ = disk.sample() })")
    }

    // MARK: - Self-test

    /// Shows the panel in an ordinary window, opens and closes it twice, and prints whether the
    /// monitor noticed (sampling interval), whether the window fits its content each time, and the
    /// app's CPU use over 10 s with the panel open and 10 s closed (after it has been opened once,
    /// which is when SwiftUI's hidden-window work used to kick in).
    /// SwiftUI's menu bar item ignores synthetic clicks, so this can't open the real dropdown.
    static func selfTest(outputDirectory: String) {
        let url = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)

        let monitor = SystemMonitor()
        let host = NSHostingController(rootView: PanelView(monitor: monitor, updater: Updater(startChecking: false)))
        host.sizingOptions = .preferredContentSize
        let window = NSPanel(contentViewController: host)
        window.styleMask = [.borderless, .nonactivatingPanel]
        window.backgroundColor = .windowBackgroundColor
        window.level = .floating
        window.isReleasedWhenClosed = false
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: screen.maxX - PanelView.width - 16, y: screen.maxY - 8))
        }

        let steps: [(TimeInterval, @MainActor @Sendable () -> Void)] = [
            (1, { report("Never opened", monitor, window); window.orderFrontRegardless() }),
            (3, { report("Opened", monitor, window); capture(window, to: url.appendingPathComponent("open-1.png")); markCPU() }),
            (13, { printCPU("CPU while open"); window.orderOut(nil) }),
            (14, { report("Closed", monitor, window); markCPU() }),
            (24, { printCPU("CPU while closed"); window.orderFrontRegardless() }),
            (26, { report("Reopened", monitor, window); capture(window, to: url.appendingPathComponent("open-2.png")); window.orderOut(nil) }),
            (27, { report("Closed again", monitor, window); NSApplication.shared.terminate(nil) }),
        ]
        for (delay, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { step() } }
        }
        NSApplication.shared.run()
    }

    private static var cpuMark: (cpu: Double, wall: Date) = (0, Date())

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        return seconds + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func markCPU() {
        cpuMark = (cpuSeconds(), Date())
    }

    private static func printCPU(_ label: String) {
        let cpu = cpuSeconds() - cpuMark.cpu
        let wall = Date().timeIntervalSince(cpuMark.wall)
        print(String(format: "%@: %.2f%% of one core (%.2f s CPU over %.0f s)", label, cpu / wall * 100, cpu, wall))
        fflush(stdout)
    }

    private static func report(_ label: String, _ monitor: SystemMonitor, _ window: NSWindow) {
        let content = window.contentView?.fittingSize ?? .zero
        print("\(label): panel visible \(monitor.panelVisible), sampling every \(Int(monitor.interval))s, "
              + "window \(Int(window.frame.width))×\(Int(window.frame.height)), content \(Int(content.width))×\(Int(content.height))")
        fflush(stdout)
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func snapshot(to directory: String) {
        let monitor = SystemMonitor(startTimer: false)
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.5)
            monitor.tickNow()
        }
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let updater = Updater(startChecking: false)
        for scheme in [ColorScheme.light, .dark] {
            let background = scheme == .dark ? Color(white: 0.16) : Color(white: 0.96)
            let name = scheme == .dark ? "dark" : "light"
            for settings in [false, true] {
                let panel = PanelView(monitor: monitor, updater: updater, tracksVisibility: false, startInSettings: settings)
                    .background(background)
                    .environment(\.colorScheme, scheme)
                write(panel, scale: 2, to: url.appendingPathComponent("\(settings ? "settings" : "panel")-\(name).png"))
            }
        }
        var variants: [(String, SystemMonitor.MenuBarItems)] = [
            ("menubar", .init()),
            ("menubar-usage", .init(usage: true, temperature: false)),
            ("menubar-temp", .init(usage: false, temperature: true)),
        ]
        if monitor.hasBattery {
            variants += [("menubar-battery", .init(usage: false, temperature: false, battery: true)),
                         ("menubar-all", .init(usage: true, temperature: true, battery: true))]
        }
        for (name, items) in variants {
            let state = SystemMonitor.MenuBarState(monitor.panel, items: items)
            // And at the widest it gets, to check nothing is cut off.
            var widest = state
            widest.tierLevels = state.tierLevels.map { _ in SystemMonitor.MenuBarState.barSteps }
            widest.load = 100
            widest.temp = items.temperature ? 100 : nil
            widest.batteryCharge = items.battery ? 100 : nil
            for (suffix, readout) in [("", state), ("-widest", widest)] {
                write(MenuBarReadout(readout).padding(4).background(Color.white), scale: 4,
                      to: url.appendingPathComponent("\(name)\(suffix).png"))
            }
        }
        // Every battery icon, whatever this Mac is doing right now.
        let icons: [(Int, BatteryReading.State)] = [(100, .charged), (80, .notCharging), (45, .charging), (12, .charging), (8, .onBattery)]
        let iconRow = HStack(spacing: 10) {
            ForEach(Array(icons.enumerated()), id: \.offset) { _, icon in MenuBarBatteryIcon(charge: icon.0, state: icon.1) }
        }
        write(iconRow.foregroundStyle(.black).padding(4).background(Color.white), scale: 4,
              to: url.appendingPathComponent("menubar-battery-icons.png"))
        print("Wrote snapshots to \(url.path)")
    }

    static func renderIcon(to path: String) {
        write(AppIconView(), scale: 1, to: URL(fileURLWithPath: path))
    }

    private static func write(_ view: some View, scale: CGFloat, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            print("Couldn't render \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }
}

/// App icon: a dark tile with a few glowing core bars.
struct AppIconView: View {
    private let heights: [Double] = [0.42, 0.78, 0.56, 0.94, 0.34]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.22),
                                              Color(red: 0.06, green: 0.06, blue: 0.09)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 4)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)

            HStack(alignment: .bottom, spacing: 36) {
                ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.9, blue: 0.98),
                                                      Color(red: 0.24, green: 0.44, blue: 1.0)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 86, height: 480 * height)
                        .shadow(color: Color(red: 0.3, green: 0.6, blue: 1).opacity(0.45), radius: 22)
                }
            }
            .frame(height: 480, alignment: .bottom)
        }
        .frame(width: 1024, height: 1024)
    }
}
